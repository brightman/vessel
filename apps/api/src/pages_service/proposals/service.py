"""Persistence and acceptance boundary for Page edit proposals."""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from pages_service.document.codec import DocumentValidationError, markdown_from_document, normalize_document
from pages_service.models import Page, PageAgentEvent, PageProposal, PageVersion
from pages_service.proposals.operations import OperationError, apply_operation_batch


class ProposalError(ValueError):
    def __init__(self, code: str, message: str | None = None) -> None:
        self.code = code
        super().__init__(message or code)


class ProposalService:
    def __init__(self, session: Session) -> None:
        self.session = session

    def begin(
        self,
        *,
        page_id: str,
        owner_user_id: str,
        run_id: str,
        base_revision: int,
        allow_full_rewrite: bool = False,
    ) -> PageProposal:
        if not isinstance(run_id, str) or not run_id.strip() or len(run_id) > 128:
            raise ProposalError("INVALID_RUN_ID")
        page = self._page(page_id, owner_user_id)
        if page.revision != base_revision:
            raise ProposalError("PAGE_REVISION_CONFLICT")
        existing = self.session.scalar(
            select(PageProposal).where(
                PageProposal.page_id == page_id,
                PageProposal.run_id == run_id,
            )
        )
        if existing is not None:
            if existing.base_revision != base_revision:
                raise ProposalError("PROPOSAL_RUN_CONFLICT")
            return existing

        now = datetime.now(UTC)
        proposal = PageProposal(
            proposal_id=str(uuid4()),
            page_id=page.page_id,
            owner_user_id=owner_user_id,
            base_revision=base_revision,
            run_id=run_id,
            allow_full_rewrite=allow_full_rewrite is True,
            status="streaming",
            operations=[],
            applied_operations=[],
            preview_title=page.title,
            preview_document=page.document_json,
            preview_markdown=page.markdown,
            created_at=now,
            updated_at=now,
        )
        self.session.add(proposal)
        self.session.flush()
        self._emit(proposal, "page.proposal.started", {"base_revision": proposal.base_revision})
        return proposal

    def append_operations(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        operations: list[dict],
    ) -> PageProposal:
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status != "streaming":
            raise ProposalError("PROPOSAL_NOT_STREAMING")
        page = self._page(proposal.page_id, owner_user_id)
        if page.revision != proposal.base_revision:
            proposal.status = "superseded"
            proposal.updated_at = datetime.now(UTC)
            self._emit(proposal, "page.proposal.superseded", {"current_revision": page.revision})
            self.session.flush()
            raise ProposalError("PAGE_REVISION_CONFLICT")

        try:
            document, title, applied_operations, _ = apply_operation_batch(
                proposal.preview_document,
                proposal.preview_title,
                operations,
                applied_operations=proposal.applied_operations,
                allow_replace_document=proposal.allow_full_rewrite,
            )
            markdown = markdown_from_document(document)
        except (OperationError, DocumentValidationError, TypeError, ValueError) as error:
            raise ProposalError("INVALID_OPERATION", str(error)) from error

        known_ids = {item.get("operation_id") for item in proposal.operations}
        additions = []
        for operation in operations:
            operation_id = operation["operation_id"]
            if operation_id not in known_ids:
                additions.append(operation)
                known_ids.add(operation_id)
        proposal.operations = [*proposal.operations, *additions]
        proposal.applied_operations = applied_operations
        proposal.preview_document = document
        proposal.preview_title = title
        proposal.preview_markdown = markdown
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        if additions:
            self._emit(
                proposal,
                "page.proposal.operations",
                {"operation_ids": [item["operation_id"] for item in additions]},
            )
        return proposal

    def finish(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        summary: str,
    ) -> PageProposal:
        if not isinstance(summary, str) or not summary.strip() or len(summary) > 4_000:
            raise ProposalError("INVALID_PROPOSAL_SUMMARY")
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "ready":
            if proposal.summary != summary.strip():
                raise ProposalError("PROPOSAL_ALREADY_FINISHED")
            return proposal
        if proposal.status != "streaming":
            raise ProposalError("PROPOSAL_NOT_STREAMING")
        page = self._page(proposal.page_id, owner_user_id)
        if page.revision != proposal.base_revision:
            proposal.status = "superseded"
            proposal.updated_at = datetime.now(UTC)
            self._emit(proposal, "page.proposal.superseded", {"current_revision": page.revision})
            self.session.flush()
            raise ProposalError("PAGE_REVISION_CONFLICT")
        try:
            document = normalize_document(proposal.preview_document)
            markdown = markdown_from_document(document)
        except (DocumentValidationError, TypeError, ValueError) as error:
            raise ProposalError("INVALID_PROPOSAL_DOCUMENT") from error
        proposal.preview_document = document
        proposal.preview_markdown = markdown
        proposal.summary = summary.strip()
        proposal.status = "ready"
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        self._emit(proposal, "page.proposal.ready", {"operation_count": len(proposal.operations)})
        return proposal

    def accept(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        idempotency_key: str,
    ) -> Page:
        if not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128:
            raise ProposalError("INVALID_IDEMPOTENCY_KEY")
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "accepted":
            if proposal.acceptance_idempotency_key != idempotency_key:
                raise ProposalError("PROPOSAL_ALREADY_ACCEPTED")
            return self._page(proposal.page_id, owner_user_id)
        if proposal.status != "ready":
            raise ProposalError("PROPOSAL_NOT_READY")

        now = datetime.now(UTC)
        next_revision = proposal.base_revision + 1
        result = self.session.execute(
            update(Page)
            .where(
                Page.page_id == proposal.page_id,
                Page.owner_user_id == owner_user_id,
                Page.status == "active",
                Page.revision == proposal.base_revision,
            )
            .values(
                title=proposal.preview_title,
                document_json=proposal.preview_document,
                markdown=proposal.preview_markdown,
                revision=next_revision,
                updated_at=now,
            )
        )
        if result.rowcount != 1:
            proposal.status = "superseded"
            proposal.updated_at = now
            self._emit(proposal, "page.proposal.superseded", {"current_revision": next_revision})
            self.session.flush()
            raise ProposalError("PAGE_REVISION_CONFLICT")

        self.session.add(
            PageVersion(
                version_id=str(uuid4()),
                page_id=proposal.page_id,
                revision=next_revision,
                title=proposal.preview_title,
                document_json=proposal.preview_document,
                markdown=proposal.preview_markdown,
                source="agent",
                actor_user_id=owner_user_id,
                run_id=proposal.run_id,
                created_at=now,
            )
        )
        proposal.status = "accepted"
        proposal.accepted_revision = next_revision
        proposal.acceptance_idempotency_key = idempotency_key
        proposal.updated_at = now
        self.session.flush()
        self._emit(proposal, "page.revision.committed", {"revision": next_revision, "source": "agent"})
        return self._page(proposal.page_id, owner_user_id)

    def reject(self, *, proposal_id: str, owner_user_id: str) -> PageProposal:
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "rejected":
            return proposal
        if proposal.status not in {"streaming", "ready"}:
            raise ProposalError("PROPOSAL_CANNOT_BE_REJECTED")
        proposal.status = "rejected"
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        self._emit(proposal, "page.proposal.rejected", {"status": proposal.status})
        return proposal

    def terminate_run(self, *, page_id: str, run_id: str, status: str) -> int:
        """Close an unfinished proposal when its owning Agent Run reaches a terminal state."""
        proposal = self.session.scalar(
            select(PageProposal).where(
                PageProposal.page_id == page_id,
                PageProposal.run_id == run_id,
                PageProposal.status == "streaming",
            )
        )
        if proposal is None:
            return 0
        proposal.status = "cancelled" if status == "cancelled" else "failed"
        proposal.failure_code = "AGENT_RUN_CANCELLED" if status == "cancelled" else "AGENT_RUN_TERMINATED"
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        self._emit(proposal, "page.proposal.run_terminated", {
            "status": proposal.status,
            "run_status": status,
        })
        return 1

    def _page(self, page_id: str, owner_user_id: str) -> Page:
        page = self.session.scalar(
            select(Page).where(
                Page.page_id == page_id,
                Page.owner_user_id == owner_user_id,
                Page.status == "active",
            )
        )
        if page is None:
            raise ProposalError("PAGE_NOT_FOUND")
        return page

    def _proposal(self, proposal_id: str, owner_user_id: str) -> PageProposal:
        proposal = self.session.scalar(
            select(PageProposal).where(
                PageProposal.proposal_id == proposal_id,
                PageProposal.owner_user_id == owner_user_id,
            )
        )
        if proposal is None:
            raise ProposalError("PROPOSAL_NOT_FOUND")
        return proposal

    def _emit(self, proposal: PageProposal, event_type: str, payload: dict) -> None:
        """Persist only small, allowlisted lifecycle metadata, never edit contents or credentials."""
        self.session.add(PageAgentEvent(
            event_id=str(uuid4()),
            correlation_id=proposal.proposal_id,
            page_id=proposal.page_id,
            proposal_id=proposal.proposal_id,
            run_id=proposal.run_id,
            event_type=event_type,
            payload=payload,
            created_at=datetime.now(UTC),
        ))
