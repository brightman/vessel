from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from pages_service.auth.tokens import KeyRing
from pages_service.models import Base, Page, User
from pages_service.mcp.capabilities import CapabilityError, PageCapabilityService


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
            Page(page_id="page_a", owner_user_id="user_a", title="A", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"),
            Page(page_id="page_b", owner_user_id="user_b", title="B", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"),
        ])
        session.commit()
        yield session, KeyRing.for_test("capability-test")


def test_capability_is_bound_to_user_page_run_audience_and_allowed_scopes(capability_context):
    session, keyring = capability_context
    service = PageCapabilityService(session, keyring, issuer="https://pages.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a",
        page_id="page_a",
        run_id="run_a",
        scopes=["page:read", "page:propose"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )

    claims = service.verify(grant.token, required_scope="page:propose", page_id="page_a", run_id="run_a")

    assert claims["sub"] == "user_a"
    assert claims["aud"] == "baizhi-pages-mcp"
    assert claims["page_id"] == "page_a"
    assert claims["run_id"] == "run_a"
    assert set(claims["scope"].split()) == {"page:read", "page:propose"}


def test_capability_rejects_page_run_or_scope_mismatch(capability_context):
    session, keyring = capability_context
    service = PageCapabilityService(session, keyring, issuer="https://pages.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a", page_id="page_a", run_id="run_a", scopes=["page:read"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )

    for kwargs in (
        {"page_id": "page_b", "run_id": "run_a", "required_scope": "page:read"},
        {"page_id": "page_a", "run_id": "run_b", "required_scope": "page:read"},
        {"page_id": "page_a", "run_id": "run_a", "required_scope": "page:propose"},
    ):
        with pytest.raises(CapabilityError):
            service.verify(grant.token, **kwargs)


def test_revoked_capability_is_rejected(capability_context):
    session, keyring = capability_context
    service = PageCapabilityService(session, keyring, issuer="https://pages.test", max_lifetime_seconds=300)
    grant = service.issue(
        owner_user_id="user_a", page_id="page_a", run_id="run_a", scopes=["page:read"],
        run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
    )
    service.revoke_run(page_id="page_a", run_id="run_a")

    with pytest.raises(CapabilityError, match="revoked"):
        service.verify(grant.token, required_scope="page:read", page_id="page_a", run_id="run_a")


def test_capability_cannot_outlive_run_or_grant_unknown_scopes(capability_context):
    session, keyring = capability_context
    service = PageCapabilityService(session, keyring, issuer="https://pages.test", max_lifetime_seconds=300)
    with pytest.raises(CapabilityError, match="run lifetime"):
        service.issue(
            owner_user_id="user_a", page_id="page_a", run_id="run_a", scopes=["page:read"],
            run_expires_at=datetime.now(UTC) - timedelta(seconds=1),
        )
    with pytest.raises(CapabilityError, match="scope"):
        service.issue(
            owner_user_id="user_a", page_id="page_a", run_id="run_a", scopes=["page:delete"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )


def test_capability_cannot_be_issued_for_another_users_page(capability_context):
    session, keyring = capability_context
    service = PageCapabilityService(session, keyring, issuer="https://pages.test", max_lifetime_seconds=300)

    with pytest.raises(CapabilityError, match="Page not found"):
        service.issue(
            owner_user_id="user_a", page_id="page_b", run_id="run_a", scopes=["page:read"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )
