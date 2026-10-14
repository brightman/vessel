import asyncio
import json
from pathlib import Path
from typing import Any

import httpx
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.database import create_database_engine
from vessel_service.main import create_app
from vessel_service.models import Base
from vessel_service.proposals.service import ProposalService
from vessel_service.settings import Settings
from vessel_service.auth.tokens import KeyRing


def test_owner_reviews_and_accepts_proposal_once_while_other_user_cannot_read_it(tmp_path: Path) -> None:
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path / 'proposal-api.sqlite3'}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    app = create_app(
        settings=Settings(environment="test", issuer_url="https://pages.test", allow_registration=True, refresh_cookie_secure=False),
        engine=engine,
        session_factory=sessions,
        keyring=KeyRing.for_test("proposal-api-test"),
    )

    def request(method: str, path: str, **kwargs: Any) -> httpx.Response:
        async def send() -> httpx.Response:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app),
                base_url="https://pages.test",
            ) as client:
                return await client.request(method, path, **kwargs)
        return asyncio.run(send())

    owner_response = request("POST", "/v1/auth/register", json={"name": "Owner", "email": "owner@example.test", "password": "pages-demo-2026"})
    outsider_response = request("POST", "/v1/auth/register", json={"name": "Other", "email": "other@example.test", "password": "pages-demo-2026"})
    assert owner_response.status_code == outsider_response.status_code == 201
    owner = owner_response.json()
    outsider = outsider_response.json()
    owner_headers = {"Authorization": f"Bearer {owner['access_token']}"}
    outsider_headers = {"Authorization": f"Bearer {outsider['access_token']}"}
    created = request(
        "POST",
        "/v1/pages",
        headers=owner_headers,
        json={
            "title": "Draft",
            "document": {
                "type": "doc",
                "schema_version": 1,
                "content": [{"type": "paragraph", "attrs": {"block_id": "block_a"}, "content": [{"type": "text", "text": "Original"}]}],
            },
        },
    ).json()["page"]

    with Session(engine, expire_on_commit=False) as session:
        service = ProposalService(session)
        proposal = service.begin(
            page_id=created["page_id"],
            owner_user_id=owner["user"]["user_id"],
            run_id="run_proposal_api",
            base_revision=created["revision"],
        )
        service.append_operations(
            proposal_id=proposal.proposal_id,
            owner_user_id=owner["user"]["user_id"],
            operations=[
                {"operation_id": "set-title", "type": "set_title", "title": "Reviewed"},
                {"operation_id": "replace-text", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Accepted"},
            ],
        )
        service.finish(proposal_id=proposal.proposal_id, owner_user_id=owner["user"]["user_id"], summary="Update the draft")
        session.commit()

    events_path = f"/v1/pages/{created['page_id']}/agent/events?wait_seconds=0"
    event_stream = request("GET", events_path, headers=owner_headers)
    assert event_stream.status_code == 200
    assert event_stream.headers["content-type"].startswith("text/event-stream")
    event_records = []
    current = {}
    for line in event_stream.text.splitlines():
        if line.startswith("id: "):
            current["id"] = line[4:]
        elif line.startswith("event: "):
            current["event"] = line[7:]
        elif line.startswith("data: "):
            current["data"] = json.loads(line[6:])
        elif not line and current:
            event_records.append(current)
            current = {}
    assert [record["event"] for record in event_records] == [
        "page.proposal.started", "page.proposal.operations", "page.proposal.ready"
    ]
    assert all(record["data"]["page_id"] == created["page_id"] for record in event_records)
    assert all(record["data"]["run_id"] == "run_proposal_api" for record in event_records)
    assert len({record["data"]["correlation_id"] for record in event_records}) == 1
    assert event_records[1]["data"]["payload"] == {"operation_ids": ["set-title", "replace-text"]}
    assert "Accepted" not in event_stream.text
    invalid_cursor = request(
        "GET", events_path,
        headers={**owner_headers, "Last-Event-ID": "not-an-event"},
    )
    assert invalid_cursor.status_code == 400
    assert invalid_cursor.json()["detail"]["code"] == "INVALID_EVENT_CURSOR"

    replayed = request(
        "GET", events_path,
        headers={**owner_headers, "Last-Event-ID": event_records[0]["id"]},
    )
    assert [line[7:] for line in replayed.text.splitlines() if line.startswith("event: ")] == [
        "page.proposal.operations", "page.proposal.ready"
    ]
    assert request("GET", events_path, headers=outsider_headers).status_code == 404

    base = f"/v1/pages/{created['page_id']}/proposals/{proposal.proposal_id}"
    active = request("GET", f"/v1/pages/{created['page_id']}/proposals", headers=owner_headers)
    assert active.status_code == 200
    assert [item["proposal_id"] for item in active.json()["proposals"]] == [proposal.proposal_id]
    preview = request("GET", base, headers=owner_headers)
    assert preview.status_code == 200
    assert preview.json()["preview"]["title"] == "Reviewed"
    denied = request("GET", base, headers=outsider_headers)
    assert denied.status_code == 404
    denied_accept = request("POST", f"{base}/accept", headers=outsider_headers, json={"idempotency_key": "steal"})
    assert denied_accept.status_code == 404

    accepted = request("POST", f"{base}/accept", headers=owner_headers, json={"idempotency_key": "accept_once"})
    retried = request("POST", f"{base}/accept", headers=owner_headers, json={"idempotency_key": "accept_once"})
    assert accepted.status_code == retried.status_code == 200
    assert accepted.json()["page"]["revision"] == retried.json()["page"]["revision"] == 2
    assert accepted.json()["page"]["title"] == "Reviewed"
    committed = request(
        "GET", events_path,
        headers={**owner_headers, "Last-Event-ID": event_records[-1]["id"]},
    )
    committed_body = committed.text
    assert [line[7:] for line in committed_body.splitlines() if line.startswith("event: ")] == [
        "page.revision.committed"
    ]
    committed_event_id = next(line[4:] for line in committed_body.splitlines() if line.startswith("id: "))
    conflicting_retry = request("POST", f"{base}/accept", headers=owner_headers, json={"idempotency_key": "different_key"})
    assert conflicting_retry.status_code == 409

    versions = request("GET", f"/v1/pages/{created['page_id']}/versions", headers=owner_headers)
    assert [(item["revision"], item["source"]) for item in versions.json()["versions"]] == [
        (2, "agent"), (1, "human")
    ]

    with Session(engine, expire_on_commit=False) as session:
        service = ProposalService(session)
        rejected_proposal = service.begin(
            page_id=created["page_id"],
            owner_user_id=owner["user"]["user_id"],
            run_id="run_rejected",
            base_revision=2,
        )
        service.append_operations(
            proposal_id=rejected_proposal.proposal_id,
            owner_user_id=owner["user"]["user_id"],
            operations=[{"operation_id": "reject-title", "type": "set_title", "title": "Discarded"}],
        )
        service.finish(proposal_id=rejected_proposal.proposal_id, owner_user_id=owner["user"]["user_id"], summary="Do not apply")
        session.commit()
    rejected = request("POST", f"/v1/pages/{created['page_id']}/proposals/{rejected_proposal.proposal_id}/reject", headers=owner_headers)
    assert rejected.status_code == 200
    assert rejected.json()["proposal"]["status"] == "rejected"
    rejected_events = request(
        "GET", events_path,
        headers={**owner_headers, "Last-Event-ID": committed_event_id},
    )
    assert [line[7:] for line in rejected_events.text.splitlines() if line.startswith("event: ")] == [
        "page.proposal.started", "page.proposal.operations", "page.proposal.ready", "page.proposal.rejected"
    ]
    current = request("GET", f"/v1/pages/{created['page_id']}", headers=owner_headers).json()["page"]
    assert current["title"] == "Reviewed"
    assert current["revision"] == 2
