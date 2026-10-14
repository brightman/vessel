from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.auth.tokens import KeyRing
from vessel_service.database import create_database_engine
from vessel_service.main import create_app
from vessel_service.models import Base, Page, PageCapability, PageProposal, User
from vessel_service.agent_platform import _ensure_agent_thread
from vessel_service.proposals.service import ProposalService
from vessel_service.settings import Settings


def _make_app(tmp_path: Path, *, platform_url: str | None = "https://agent.test"):
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path / 'pages-agent.sqlite3'}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    keyring = KeyRing.for_test("pages-agent-test")
    app = create_app(
        settings=Settings(
            environment="test",
            issuer_url="https://pages.test",
            allow_registration=True,
            refresh_cookie_secure=False,
            agent_platform_url=platform_url,
        ),
        engine=engine,
        session_factory=sessions,
        keyring=keyring,
        testing_legacy_pages_agent=True,
    )
    return app, engine, keyring


def _request(app, method: str, path: str, **kwargs: Any) -> httpx.Response:
    async def send() -> httpx.Response:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://pages.test"
        ) as client:
            return await client.request(method, path, **kwargs)

    return asyncio.run(send())


def _registered_page(app, *, email: str = "owner@example.test") -> tuple[str, str]:
    auth = _request(
        app,
        "POST",
        "/v1/auth/register",
        json={"name": "Page owner", "email": email, "password": "page-test-password"},
    )
    assert auth.status_code == 201
    token = auth.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    page = _request(
        app,
        "POST",
        "/v1/pages",
        headers=headers,
        json={"title": "Draft", "document": {"type": "doc", "schema_version": 1, "content": []}},
    )
    assert page.status_code == 201
    return token, page.json()["page"]["page_id"]


class _UpstreamResponse:
    status_code = 202

    def __init__(self, payload: dict[str, str]):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, str]:
        return self._payload


def test_start_agent_run_issues_separate_scoped_assertion_and_page_capability(tmp_path, monkeypatch):
    app, engine, keyring = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    captured: dict[str, Any] = {}

    def fake_post(url, *, headers, json, timeout):
        captured.update(url=url, headers=headers, body=json, timeout=timeout)
        return _UpstreamResponse({"run_id": json["run_id"], "thread_id": json["thread_id"], "status": "queued"})

    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", fake_post)
    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "Please clarify this page", "mode": "edit", "selection": {"selected": True, "text": "Only this selection"}},
    )

    assert response.status_code == 202
    result = response.json()
    assert result["page_id"] == page_id
    assert result["run_id"].startswith("run_pages_")
    assert result["thread_id"].startswith("thread_pages_")
    assert captured["url"] == "https://agent.test/v1/integrations/pages/runs"
    assert captured["body"] == {
        "page_id": page_id,
        "run_id": result["run_id"],
        "thread_id": result["thread_id"],
        "message": "Please clarify this page",
        "mode": "edit",
    }

    assertion = captured["headers"]["Authorization"].removeprefix("Bearer ")
    claims = keyring.verify(
        assertion, issuer="https://pages.test", audience="baizhi-agent-platform", required_scope="agent:run"
    )
    assert claims is not None
    assert isinstance(claims["sub"], str) and claims["sub"]
    assert set(claims).isdisjoint({"email", "roles", "is_admin"})
    capability = captured["headers"]["X-Pages-Run-Capability"]
    capability_claims = keyring.verify(
        capability, issuer="https://pages.test", audience="baizhi-pages-mcp", required_scope="page:propose"
    )
    assert capability_claims is not None
    assert capability_claims["page_id"] == page_id
    assert capability_claims["run_id"] == result["run_id"]
    assert capability_claims["sub"] == claims["sub"]
    assert capability not in response.text
    with Session(engine) as session:
        page = session.get(Page, page_id)
        assert page is not None and page.agent_thread_id == result["thread_id"]
        grant = session.scalar(select(PageCapability).where(PageCapability.run_id == result["run_id"]))
        assert grant is not None and grant.selection_json == {"selected": True, "text": "Only this selection"}
        assert grant.revoked_at is None


def test_start_agent_ask_run_issues_read_only_capability_and_forwards_mode(tmp_path, monkeypatch):
    app, _, keyring = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    captured: dict[str, Any] = {}

    def fake_post(url, *, headers, json, timeout):
        captured.update(url=url, headers=headers, body=json, timeout=timeout)
        return _UpstreamResponse({"run_id": json["run_id"], "thread_id": json["thread_id"], "status": "queued"})

    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", fake_post)
    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "What is this Page about?"},
    )

    assert response.status_code == 202
    result = response.json()
    assert captured["body"] == {
        "page_id": page_id,
        "run_id": result["run_id"],
        "thread_id": result["thread_id"],
        "message": "What is this Page about?",
        "mode": "ask",
    }
    capability_claims = keyring.verify(
        captured["headers"]["X-Pages-Run-Capability"],
        issuer="https://pages.test",
        audience="baizhi-pages-mcp",
        required_scope="page:read",
    )
    assert capability_claims is not None
    assert capability_claims["scope"] == "page:read"


def test_start_agent_run_does_not_allow_callers_to_choose_agent_or_mcp(tmp_path, monkeypatch):
    app, _, _ = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", lambda *a, **kw: pytest.fail("must not call Platform"))

    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "Hello", "agent_id": "attacker", "runtime_mcps": [{"http_url": "https://attacker.test"}]},
    )

    assert response.status_code == 422


def test_start_agent_run_failure_revokes_its_page_capability(tmp_path, monkeypatch):
    app, engine, _ = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    monkeypatch.setattr(
        "vessel_service.agent_platform.httpx.post",
        lambda *a, **kw: httpx.Response(503, request=httpx.Request("POST", "https://agent.test")),
    )

    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "Hello"},
    )

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "AGENT_PLATFORM_RUN_START_FAILED"
    with Session(engine) as session:
        grant = session.scalar(select(PageCapability).where(PageCapability.page_id == page_id))
        assert grant is not None and grant.revoked_at is not None


def test_agent_run_event_proxy_forwards_sse_frames_and_revokes_terminal_capability(tmp_path, monkeypatch):
    app, engine, _ = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    monkeypatch.setattr(
        "vessel_service.agent_platform.httpx.post",
        lambda _url, *, json, **_kwargs: _UpstreamResponse({
            "run_id": json["run_id"], "thread_id": json["thread_id"], "status": "queued",
        }),
    )
    started = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "Update this Page"},
    )
    assert started.status_code == 202
    run_id = started.json()["run_id"]
    with Session(engine) as session:
        owner = session.scalar(select(User).where(User.email == "owner@example.test"))
        assert owner is not None
        proposal = ProposalService(session).begin(page_id=page_id, owner_user_id=owner.user_id, run_id=run_id, base_revision=1)
        proposal_id = proposal.proposal_id
        session.commit()
    sse_body = (
        b"id: evt-text\nevent: TEXT_MESSAGE_CONTENT\n"
        b'data: {"event_id":"evt-text","payload":{"delta":"Proposal ready."}}\n\n'
        b'event: done\ndata: {"status":"completed"}\n\n'
    )

    class FakeUpstreamClient:
        def __init__(self, *, timeout):
            assert timeout is None

        def build_request(self, method, url, *, headers):
            return httpx.Request(method, url, headers=headers)

        async def send(self, request, *, stream):
            assert stream is True
            return httpx.Response(200, content=sse_body, request=request)

        async def aclose(self):
            return None

    async def fetch_events():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://pages.test"
        ) as api_client:
            with monkeypatch.context() as patch:
                patch.setattr("vessel_service.agent_platform.httpx.AsyncClient", FakeUpstreamClient)
                return await api_client.get(
                    f"/v1/pages/{page_id}/agent/runs/{run_id}/events",
                    headers={"Authorization": f"Bearer {token}"},
                )

    response = asyncio.run(fetch_events())

    assert response.status_code == 200
    assert "event: TEXT_MESSAGE_CONTENT\n" in response.text
    assert 'data: {"event_id":"evt-text","payload":{"delta":"Proposal ready."}}\n' in response.text
    assert 'event: done\ndata: {"status":"completed"}\n\n' in response.text
    with Session(engine) as session:
        grant = session.scalar(select(PageCapability).where(PageCapability.run_id == run_id))
        assert grant is not None and grant.revoked_at is not None
        proposal = session.get(PageProposal, proposal_id)
        assert proposal is not None and proposal.status == "failed"
        assert proposal.failure_code == "AGENT_RUN_TERMINATED"
        page = session.get(Page, page_id)
        assert page is not None and page.revision == 1


def test_cancelling_agent_run_closes_open_page_proposal(tmp_path, monkeypatch):
    app, engine, _ = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    calls: list[str] = []

    def fake_post(url, *, json=None, **_kwargs):
        calls.append(url)
        if url.endswith("/cancel"):
            return _UpstreamResponse({"status": "cancelled"})
        return _UpstreamResponse({"run_id": json["run_id"], "thread_id": json["thread_id"], "status": "queued"})

    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", fake_post)
    headers = {"Authorization": f"Bearer {token}"}
    started = _request(app, "POST", f"/v1/pages/{page_id}/agent/runs", headers=headers, json={"message": "Edit this Page", "mode": "edit"})
    assert started.status_code == 202
    run_id = started.json()["run_id"]
    with Session(engine) as session:
        owner = session.scalar(select(User).where(User.email == "owner@example.test"))
        assert owner is not None
        proposal = ProposalService(session).begin(page_id=page_id, owner_user_id=owner.user_id, run_id=run_id, base_revision=1)
        proposal_id = proposal.proposal_id
        session.commit()

    cancelled = _request(app, "POST", f"/v1/pages/{page_id}/agent/runs/{run_id}/cancel", headers=headers)
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "cancelled"
    active = _request(app, "GET", f"/v1/pages/{page_id}/proposals", headers=headers)
    assert active.status_code == 200
    assert active.json()["proposals"] == []
    assert any(url.endswith("/cancel") for url in calls)
    with Session(engine) as session:
        proposal = session.get(PageProposal, proposal_id)
        assert proposal is not None and proposal.status == "cancelled"
        page = session.get(Page, page_id)
        assert page is not None and page.revision == 1


def test_agent_run_is_page_owner_scoped(tmp_path, monkeypatch):
    app, _, _ = _make_app(tmp_path)
    owner_token, page_id = _registered_page(app)
    other_auth = _request(
        app,
        "POST",
        "/v1/auth/register",
        json={"name": "Other", "email": "other@example.test", "password": "page-test-password"},
    )
    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", lambda *a, **kw: pytest.fail("must not call Platform"))

    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {other_auth.json()['access_token']}"},
        json={"message": "Read someone else's page"},
    )

    assert response.status_code == 404


def test_agent_platform_status_discloses_only_whether_configured(tmp_path):
    app, _, _ = _make_app(tmp_path, platform_url="https://agent.internal")
    response = _request(app, "GET", "/v1/pages/page_a/agent/status")
    assert response.status_code == 200
    assert response.json() == {"configured": True}


def test_start_agent_run_fails_closed_without_platform_url(tmp_path):
    app, _, _ = _make_app(tmp_path, platform_url=None)
    token, page_id = _registered_page(app)
    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "Hello"},
    )
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "AGENT_PLATFORM_NOT_CONFIGURED"


def test_start_agent_run_rejects_whitespace_only_message(tmp_path, monkeypatch):
    app, _, _ = _make_app(tmp_path)
    token, page_id = _registered_page(app)
    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", lambda *a, **kw: pytest.fail("must not call Platform"))

    response = _request(
        app,
        "POST",
        f"/v1/pages/{page_id}/agent/runs",
        headers={"Authorization": f"Bearer {token}"},
        json={"message": "  \n\t  "},
    )

    assert response.status_code == 422


def test_concurrent_run_starts_keep_the_first_persisted_agent_thread(tmp_path):
    app, engine, _ = _make_app(tmp_path)
    _token, page_id = _registered_page(app)
    session_a = Session(engine)
    session_b = Session(engine)
    try:
        page_a = session_a.get(Page, page_id)
        page_b = session_b.get(Page, page_id)
        assert page_a is not None and page_b is not None
        assert page_a.agent_thread_id is None and page_b.agent_thread_id is None

        first = _ensure_agent_thread(session_a, page_a)
        second = _ensure_agent_thread(session_b, page_b)

        assert first == second
        with Session(engine) as verification_session:
            persisted = verification_session.get(Page, page_id)
        assert persisted is not None and persisted.agent_thread_id == first
    finally:
        session_a.close()
        session_b.close()
