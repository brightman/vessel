from datetime import UTC, datetime

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from pages_service.models import Base, Page, PageVersion, User
from pages_service.proposals.service import ProposalError, ProposalService


@pytest.fixture
def session(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'proposal.sqlite3'}")
    Base.metadata.create_all(engine)
    with Session(engine, expire_on_commit=False) as db:
        db.add(User(user_id="user_a", email="a@example.test", name="A", roles=["user"], status="active"))
        db.add(Page(
            page_id="page_a",
            owner_user_id="user_a",
            title="Draft",
            document_json={"type": "doc", "schema_version": 1, "content": [{"type": "paragraph", "attrs": {"block_id": "block_a"}, "content": [{"type": "text", "text": "Original"}]}]},
            markdown="Original\n",
            revision=1,
            status="active",
            created_at=datetime.now(UTC),
            updated_at=datetime.now(UTC),
        ))
        db.commit()
        yield db


def test_proposal_preview_is_persisted_without_changing_authoritative_page(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    proposal = service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[
        {"operation_id": "op_title", "type": "set_title", "title": "Updated"},
        {"operation_id": "op_text", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Proposed"},
    ])
    proposal = service.finish(proposal_id=proposal.proposal_id, owner_user_id="user_a", summary="Update the draft")

    page = session.get(Page, "page_a")
    assert proposal.status == "ready"
    assert proposal.preview_title == "Updated"
    assert "Proposed" in proposal.preview_markdown
    assert page.title == "Draft"
    assert page.revision == 1
    assert "Original" in page.markdown
    assert session.scalars(select(PageVersion)).all() == []


def test_accept_commits_one_revision_and_retries_idempotently(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[
        {"operation_id": "op_text", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Accepted"},
    ])
    service.finish(proposal_id=proposal.proposal_id, owner_user_id="user_a", summary="Accept this")

    accepted = service.accept(proposal_id=proposal.proposal_id, owner_user_id="user_a", idempotency_key="accept_once")
    retried = service.accept(proposal_id=proposal.proposal_id, owner_user_id="user_a", idempotency_key="accept_once")

    assert accepted.revision == retried.revision == 2
    assert accepted.markdown == retried.markdown
    assert accepted.title == "Draft"
    assert "Accepted" in accepted.markdown
    versions = session.scalars(select(PageVersion).where(PageVersion.page_id == "page_a")).all()
    assert [(item.revision, item.source) for item in versions] == [(2, "agent")]


def test_accept_rejects_stale_proposal_without_overwriting_newer_page(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[
        {"operation_id": "op_text", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Proposal"},
    ])
    service.finish(proposal_id=proposal.proposal_id, owner_user_id="user_a", summary="Stale edit")
    page = session.get(Page, "page_a")
    page.title = "Manual edit"
    page.revision = 2
    session.commit()

    with pytest.raises(ProposalError, match="PAGE_REVISION_CONFLICT"):
        service.accept(proposal_id=proposal.proposal_id, owner_user_id="user_a", idempotency_key="accept_stale")

    session.refresh(page)
    assert page.title == "Manual edit"
    assert page.revision == 2
    assert session.scalars(select(PageVersion)).all() == []


def test_reject_discards_preview_without_committing_page(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[
        {"operation_id": "op_title", "type": "set_title", "title": "Never committed"},
    ])
    rejected = service.reject(proposal_id=proposal.proposal_id, owner_user_id="user_a")

    assert rejected.status == "rejected"
    assert session.get(Page, "page_a").title == "Draft"
    assert session.scalars(select(PageVersion)).all() == []


def test_terminate_run_closes_streaming_proposal_without_changing_page(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_cancelled", base_revision=1)
    service.append_operations(
        proposal_id=proposal.proposal_id,
        owner_user_id="user_a",
        operations=[{"operation_id": "op_text", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Unaccepted"}],
    )

    service.terminate_run(page_id="page_a", run_id="run_cancelled", status="cancelled")

    session.refresh(proposal)
    assert proposal.status == "cancelled"
    assert proposal.failure_code == "AGENT_RUN_CANCELLED"
    assert session.get(Page, "page_a").markdown == "Original\n"
    assert session.scalars(select(PageVersion)).all() == []


def test_invalid_batch_does_not_partially_change_persisted_preview(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)

    with pytest.raises(ProposalError, match="target block was not found"):
        service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[
            {"operation_id": "op_title", "type": "set_title", "title": "Should roll back"},
            {"operation_id": "op_bad", "type": "delete_blocks", "block_ids": ["missing"]},
        ])

    session.refresh(proposal)
    assert proposal.preview_title == "Draft"
    assert proposal.operations == []


def test_replaying_operation_in_a_later_batch_does_not_duplicate_operation_history(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    operation = {"operation_id": "title_once", "type": "set_title", "title": "Updated"}
    service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[operation])
    replay = service.append_operations(proposal_id=proposal.proposal_id, owner_user_id="user_a", operations=[operation])

    assert replay.preview_title == "Updated"
    assert [item["operation_id"] for item in replay.operations] == ["title_once"]


def test_duplicate_operation_id_in_one_batch_is_recorded_once(session):
    service = ProposalService(session)
    proposal = service.begin(page_id="page_a", owner_user_id="user_a", run_id="run_a", base_revision=1)
    operation = {"operation_id": "title_once", "type": "set_title", "title": "Updated"}
    proposal = service.append_operations(
        proposal_id=proposal.proposal_id,
        owner_user_id="user_a",
        operations=[operation, operation],
    )

    assert [item["operation_id"] for item in proposal.operations] == ["title_once"]


def test_full_document_replacement_requires_trusted_proposal_scope(session):
    denied = ProposalService(session).begin(page_id="page_a", owner_user_id="user_a", run_id="run_denied", base_revision=1)
    full_rewrite = {
        "operation_id": "rewrite",
        "type": "replace_document",
        "document": {"type": "doc", "schema_version": 1, "content": [{"type": "paragraph", "attrs": {"block_id": "block_b"}, "content": [{"type": "text", "text": "New document"}]}]},
    }
    with pytest.raises(ProposalError, match="explicit full rewrite"):
        ProposalService(session).append_operations(proposal_id=denied.proposal_id, owner_user_id="user_a", operations=[full_rewrite])

    allowed = ProposalService(session).begin(page_id="page_a", owner_user_id="user_a", run_id="run_allowed", base_revision=1, allow_full_rewrite=True)
    changed = ProposalService(session).append_operations(proposal_id=allowed.proposal_id, owner_user_id="user_a", operations=[full_rewrite])
    assert changed.preview_document["content"][0]["attrs"]["block_id"] == "block_b"
