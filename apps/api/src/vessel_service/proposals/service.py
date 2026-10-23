"""Persistence and acceptance boundary for Note edit proposals."""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session
from fastapi import HTTPException

from vessel_service.document.codec import DocumentValidationError, markdown_from_document, normalize_document
from vessel_service.models import Note, NoteAgentEvent, NoteProposal, NoteVersion, User
from vessel_service.spaces.permissions import space_access
from vessel_service.proposals.operations import OperationError, apply_operation_batch


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
        note_id: str,
        owner_user_id: str,
        run_id: str,
        base_revision: int,
        allow_full_rewrite: bool = False,
    ) -> NoteProposal:
        if not isinstance(run_id, str) or not run_id.strip() or len(run_id) > 128:
            raise ProposalError("INVALID_RUN_ID")
        note = self._note(note_id, owner_user_id, write=True)
        if note.revision != base_revision:
            raise ProposalError("NOTE_REVISION_CONFLICT")
        existing = self.session.scalar(
            select(NoteProposal).where(
                NoteProposal.note_id == note_id,
                NoteProposal.run_id == run_id,
            )
        )
        if existing is not None:
            if existing.base_revision != base_revision:
                raise ProposalError("PROPOSAL_RUN_CONFLICT")
            return existing

        now = datetime.now(UTC)
        proposal = NoteProposal(
            proposal_id=str(uuid4()),
            note_id=note.note_id,
            owner_user_id=owner_user_id,
            base_revision=base_revision,
            run_id=run_id,
            allow_full_rewrite=allow_full_rewrite is True,
            status="streaming",
            operations=[],
            applied_operations=[],
            preview_title=note.title,
            preview_document=note.document_json,
            preview_markdown=note.markdown,
            created_at=now,
            updated_at=now,
        )
        self.session.add(proposal)
        self.session.flush()
        self._emit(proposal, "note.proposal.started", {"base_revision": proposal.base_revision})
        return proposal

    def append_operations(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        operations: list[dict],
    ) -> NoteProposal:
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status != "streaming":
            raise ProposalError("PROPOSAL_NOT_STREAMING")
        note = self._note(proposal.note_id, owner_user_id, write=True)
        if note.revision != proposal.base_revision:
            proposal.status = "superseded"
            proposal.updated_at = datetime.now(UTC)
            self._emit(proposal, "note.proposal.superseded", {"current_revision": note.revision})
            self.session.flush()
            raise ProposalError("NOTE_REVISION_CONFLICT")

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
                "note.proposal.operations",
                {"operation_ids": [item["operation_id"] for item in additions]},
            )
        return proposal

    def finish(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        summary: str,
    ) -> NoteProposal:
        if not isinstance(summary, str) or not summary.strip() or len(summary) > 4_000:
            raise ProposalError("INVALID_PROPOSAL_SUMMARY")
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "ready":
            if proposal.summary != summary.strip():
                raise ProposalError("PROPOSAL_ALREADY_FINISHED")
            return proposal
        if proposal.status != "streaming":
            raise ProposalError("PROPOSAL_NOT_STREAMING")
        note = self._note(proposal.note_id, owner_user_id, write=True)
        if note.revision != proposal.base_revision:
            proposal.status = "superseded"
            proposal.updated_at = datetime.now(UTC)
            self._emit(proposal, "note.proposal.superseded", {"current_revision": note.revision})
            self.session.flush()
            raise ProposalError("NOTE_REVISION_CONFLICT")
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
        self._emit(proposal, "note.proposal.ready", {"operation_count": len(proposal.operations)})
        return proposal

    def accept(
        self,
        *,
        proposal_id: str,
        owner_user_id: str,
        idempotency_key: str,
    ) -> Note:
        if not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128:
            raise ProposalError("INVALID_IDEMPOTENCY_KEY")
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "accepted":
            if proposal.acceptance_idempotency_key != idempotency_key:
                raise ProposalError("PROPOSAL_ALREADY_ACCEPTED")
            return self._note(proposal.note_id, owner_user_id, write=True)
        if proposal.status != "ready":
            raise ProposalError("PROPOSAL_NOT_READY")

        note = self._note(proposal.note_id, owner_user_id, write=True)

        now = datetime.now(UTC)
        next_revision = proposal.base_revision + 1
        result = self.session.execute(
            update(Note)
            .where(
                Note.note_id == proposal.note_id,
                Note.space_id == note.space_id,
                Note.status == "active",
                Note.revision == proposal.base_revision,
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
            self._emit(proposal, "note.proposal.superseded", {"current_revision": next_revision})
            self.session.flush()
            raise ProposalError("NOTE_REVISION_CONFLICT")

        self.session.add(
            NoteVersion(
                version_id=str(uuid4()),
                note_id=proposal.note_id,
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
        self._emit(proposal, "note.revision.committed", {"revision": next_revision, "source": "agent"})
        return self._note(proposal.note_id, owner_user_id, write=True)

    def reject(self, *, proposal_id: str, owner_user_id: str) -> NoteProposal:
        proposal = self._proposal(proposal_id, owner_user_id)
        if proposal.status == "rejected":
            return proposal
        if proposal.status not in {"streaming", "ready"}:
            raise ProposalError("PROPOSAL_CANNOT_BE_REJECTED")
        proposal.status = "rejected"
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        self._emit(proposal, "note.proposal.rejected", {"status": proposal.status})
        return proposal

    def terminate_run(self, *, note_id: str, run_id: str, status: str) -> int:
        """Close an unfinished proposal when its owning Agent Run reaches a terminal state."""
        proposal = self.session.scalar(
            select(NoteProposal).where(
                NoteProposal.note_id == note_id,
                NoteProposal.run_id == run_id,
                NoteProposal.status == "streaming",
            )
        )
        if proposal is None:
            return 0
        proposal.status = "cancelled" if status == "cancelled" else "failed"
        proposal.failure_code = "AGENT_RUN_CANCELLED" if status == "cancelled" else "AGENT_RUN_TERMINATED"
        proposal.updated_at = datetime.now(UTC)
        self.session.flush()
        self._emit(proposal, "note.proposal.run_terminated", {
            "status": proposal.status,
            "run_status": status,
        })
        return 1

    def _note(self, note_id: str, owner_user_id: str, *, write: bool = False) -> Note:
        note = self.session.scalar(
            select(Note).where(
                Note.note_id == note_id,
                Note.status == "active",
            )
        )
        user = self.session.get(User, owner_user_id)
        if note is None or user is None or user.status != "active":
            raise ProposalError("NOTE_NOT_FOUND")
        try:
            space_access(self.session, user, note.space_id, capability="can_write" if write else "can_read", lock=write)
        except HTTPException as error:
            raise ProposalError("NOTE_NOT_FOUND" if error.status_code == 404 else "SPACE_PERMISSION_DENIED") from error
        return note

    def _proposal(self, proposal_id: str, owner_user_id: str) -> NoteProposal:
        proposal = self.session.scalar(
            select(NoteProposal).where(
                NoteProposal.proposal_id == proposal_id,
                NoteProposal.owner_user_id == owner_user_id,
            )
        )
        if proposal is None:
            raise ProposalError("PROPOSAL_NOT_FOUND")
        return proposal

    def _emit(self, proposal: NoteProposal, event_type: str, payload: dict) -> None:
        """Persist only small, allowlisted lifecycle metadata, never edit contents or credentials."""
        self.session.add(NoteAgentEvent(
            event_id=str(uuid4()),
            correlation_id=proposal.proposal_id,
            note_id=proposal.note_id,
            proposal_id=proposal.proposal_id,
            run_id=proposal.run_id,
            event_type=event_type,
            payload=payload,
            created_at=datetime.now(UTC),
        ))
