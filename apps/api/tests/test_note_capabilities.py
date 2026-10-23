from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from vessel_service.auth.tokens import KeyRing
from vessel_service.models import Base, Note, Space, User
from vessel_service.mcp.capabilities import CapabilityError, NoteCapabilityService


@pytest.fixture
def capability_context(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'capabilities.sqlite3'}")
    Base.metadata.create_all(engine)
    with Session(engine, expire_on_commit=False) as session:
        session.add_all([
            User(user_id="user_a", email="a@example.test", name="A", roles=["user"], status="active"),
            User(user_id="user_b", email="b@example.test", name="B", roles=["user"], status="active"),
        ])
        session.add_all([
            Space(space_id="space_a", kind="personal", name="A Personal", owner_user_id="user_a", created_by_user_id="user_a", status="active"),
            Space(space_id="space_b", kind="personal", name="B Personal", owner_user_id="user_b", created_by_user_id="user_b", status="active"),
        ])
        session.add_all([
            Note(note_id="note_a", space_id="space_a", owner_user_id="user_a", title="A", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"),
            Note(note_id="note_b", space_id="space_b", owner_user_id="user_b", title="B", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"),
        ])
        session.commit()
        yield session, KeyRing.for_test("capability-test")


def test_capability_is_bound_to_user_note_run_audience_and_allowed_scopes(capability_context):
    session, keyring = capability_context
    service = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a",
        note_id="note_a",
        run_id="run_a",
        scopes=["note:read", "note:propose"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )

    claims = service.verify(grant.token, required_scope="note:propose", note_id="note_a", run_id="run_a")

    assert claims["sub"] == "user_a"
    assert claims["aud"] == "baizhi-notes-mcp"
    assert claims["note_id"] == "note_a"
    assert claims["run_id"] == "run_a"
    assert set(claims["scope"].split()) == {"note:read", "note:propose"}


def test_capability_rejects_note_run_or_scope_mismatch(capability_context):
    session, keyring = capability_context
    service = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:read"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )

    for kwargs in (
        {"note_id": "note_b", "run_id": "run_a", "required_scope": "note:read"},
        {"note_id": "note_a", "run_id": "run_b", "required_scope": "note:read"},
        {"note_id": "note_a", "run_id": "run_a", "required_scope": "note:propose"},
    ):
        with pytest.raises(CapabilityError):
            service.verify(grant.token, **kwargs)


def test_revoked_capability_is_rejected(capability_context):
    session, keyring = capability_context
    service = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:read"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )
    service.revoke_run(note_id="note_a", run_id="run_a")

    with pytest.raises(CapabilityError, match="revoked"):
        service.verify(grant.token, required_scope="note:read", note_id="note_a", run_id="run_a")


def test_capability_cannot_outlive_run_or_grant_unknown_scopes(capability_context):
    session, keyring = capability_context
    service = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)
    with pytest.raises(CapabilityError, match="run lifetime"):
        service.issue(
            owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:read"],
            run_expires_at=datetime.now(UTC) - timedelta(seconds=1),
        )
    with pytest.raises(CapabilityError, match="scope"):
        service.issue(
            owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:delete"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )


def test_capability_cannot_be_issued_for_another_users_page(capability_context):
    session, keyring = capability_context
    service = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)

    with pytest.raises(CapabilityError, match="Note not found"):
        service.issue(
            owner_user_id="user_a", note_id="note_b", run_id="run_a", scopes=["note:read"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )
