import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.auth.tokens import KeyRing
from vessel_service.database import create_database_engine
from vessel_service.main import create_app
from vessel_service.mcp.capabilities import NoteCapabilityService
from vessel_service.mcp.server import TOOLS
from vessel_service.models import Base, Note, Space, User
from vessel_service.proposals.service import ProposalService
from vessel_service.settings import Settings


def test_append_note_operations_schema_teaches_the_supported_operation_contract() -> None:
    tool = next(item for item in TOOLS if item["name"] == "append_note_operations")
    schema = tool["inputSchema"]
    operation = schema["properties"]["operations"]["items"]

    assert operation.get("required") == ["operation_id", "type"]
    properties = operation.get("properties", {})
    assert properties.get("type", {}).get("enum") == [
        "set_title",
        "replace_block",
        "replace_range",
        "insert_blocks_after",
        "delete_blocks",
        "move_block",
        "replace_document",
    ]
    assert operation.get("additionalProperties") is False
    assert "stable block_id" in properties.get("block_id", {}).get("description", "")
    assert "preserve" in properties.get("block", {}).get("description", "")


def test_private_mcp_reads_and_builds_note_proposal_without_commit_tool(tmp_path: Path) -> None:
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path / 'mcp.sqlite3'}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    keyring = KeyRing.for_test("mcp-test")
    app = create_app(
        settings=Settings(environment="test", issuer_url="https://notes.test"),
        engine=engine,
        session_factory=sessions,
        keyring=keyring,
        testing_legacy_notes_agent=True,
    )
    document = {
        "type": "doc",
        "schema_version": 1,
        "content": [{"type": "paragraph", "attrs": {"block_id": "block_a"}, "content": [{"type": "text", "text": "Original"}]}],
    }
    with Session(engine, expire_on_commit=False) as session:
        session.add(User(user_id="user_a", email="mcp@example.test", name="MCP", roles=["user"], status="active"))
        session.add(Space(space_id="space_a", kind="personal", name="MCP Personal", owner_user_id="user_a", created_by_user_id="user_a", status="active"))
        session.add(Note(
            note_id="note_a", space_id="space_a", owner_user_id="user_a", title="Draft", document_json=document,
            markdown="Original\n", revision=1, status="active",
            created_at=datetime.now(UTC), updated_at=datetime.now(UTC),
        ))
        session.commit()
        capabilities = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300)
        grant = capabilities.issue(
            owner_user_id="user_a", note_id="note_a", run_id="run_a",
            scopes=["note:read", "note:propose"],
            selection={"selected": True, "text": "Original", "block_id": "block_a"},
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )
        session.commit()
    token = grant.token

    def request(method: str, path: str, **kwargs: Any) -> httpx.Response:
        async def send() -> httpx.Response:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://notes.test") as client:
                return await client.request(method, path, **kwargs)
        return asyncio.run(send())

    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    def rpc(method: str, request_id: int, params: dict[str, Any] | None = None) -> dict[str, Any]:
        response = request("POST", "/mcp", headers=headers, json={"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        assert response.status_code == 200
        return response.json()["result"]

    initialized = rpc("initialize", 1, {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
    tools = rpc("tools/list", 2)["tools"]
    note_result = rpc("tools/call", 3, {"name": "read_current_note", "arguments": {}})
    selection_result = rpc("tools/call", 4, {"name": "read_current_selection", "arguments": {}})
    begin = rpc("tools/call", 5, {"name": "begin_note_edit", "arguments": {"base_revision": 1}})
    begin_body = json.loads(begin["content"][0]["text"])
    append = rpc("tools/call", 6, {"name": "append_note_operations", "arguments": {
        "proposal_id": begin_body["proposal_id"],
        "operations": [
            {"operation_id": "rename", "type": "set_title", "title": "Proposed"},
            {"operation_id": "replace", "type": "replace_range", "block_id": "block_a", "expected_text": "Original", "replacement": "Proposed text"},
        ],
    }})
    finish = rpc("tools/call", 7, {"name": "finish_note_edit", "arguments": {"proposal_id": begin_body["proposal_id"], "summary": "Clarify the note"}})

    assert initialized["protocolVersion"] == "2025-06-18"
    assert initialized["serverInfo"]["name"] == "vessel-notes"
    assert {item["name"] for item in tools} == {
        "read_current_note", "read_current_selection", "begin_note_edit", "append_note_operations", "finish_note_edit"
    }
    assert json.loads(note_result["content"][0]["text"])["markdown"] == "Original\n"
    assert json.loads(selection_result["content"][0]["text"])["text"] == "Original"
    assert json.loads(append["content"][0]["text"])["preview_title"] == "Proposed"
    assert json.loads(finish["content"][0]["text"])["status"] == "ready"

    with Session(engine, expire_on_commit=False) as session:
        page = session.get(Note, "note_a")
        assert page.title == "Draft"
        assert page.revision == 1
        proposal = ProposalService(session).accept(
            proposal_id=begin_body["proposal_id"], owner_user_id="user_a", idempotency_key="accept_once"
        )
        session.commit()
        assert proposal.title == "Proposed"
        assert proposal.revision == 2
        assert "Proposed text" in proposal.markdown

    assert token not in json.dumps([initialized, tools, note_result, selection_result, begin, append, finish])


def test_private_mcp_rejects_capability_without_proposal_scope(tmp_path: Path) -> None:
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path / 'mcp-scope.sqlite3'}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    keyring = KeyRing.for_test("mcp-scope-test")
    app = create_app(settings=Settings(environment="test", issuer_url="https://notes.test"), engine=engine, session_factory=sessions, keyring=keyring, testing_legacy_notes_agent=True)
    with Session(engine) as session:
        session.add(User(user_id="user_a", email="read@example.test", name="Read", roles=["user"], status="active"))
        session.add(Space(space_id="space_a", kind="personal", name="Read Personal", owner_user_id="user_a", created_by_user_id="user_a", status="active"))
        session.add(Note(note_id="note_a", space_id="space_a", owner_user_id="user_a", title="Draft", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"))
        session.commit()
        grant = NoteCapabilityService(session, keyring, issuer="https://notes.test", max_lifetime_seconds=300).issue(
            owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:read"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=2),
        )
        session.commit()

    async def send() -> httpx.Response:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://notes.test") as client:
            return await client.post(
                "/mcp",
                headers={"Authorization": f"Bearer {grant.token}"},
                json={"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "begin_note_edit", "arguments": {"base_revision": 1}}},
            )
    response = asyncio.run(send())
    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "NOTE_CAPABILITY_DENIED"


def test_private_mcp_enforces_configured_capability_lifetime(tmp_path: Path) -> None:
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path / 'mcp-lifetime.sqlite3'}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    keyring = KeyRing.for_test("mcp-lifetime-test")
    app = create_app(
        settings=Settings(
            environment="test",
            issuer_url="https://notes.test",
            note_capability_ttl_seconds=300,
        ),
        engine=engine,
        session_factory=sessions,
        keyring=keyring,
        testing_legacy_notes_agent=True,
    )
    with Session(engine) as session:
        session.add(User(user_id="user_a", email="lifetime@example.test", name="Lifetime", roles=["user"], status="active"))
        session.add(Space(space_id="space_a", kind="personal", name="Lifetime Personal", owner_user_id="user_a", created_by_user_id="user_a", status="active"))
        session.add(Note(note_id="note_a", space_id="space_a", owner_user_id="user_a", title="Draft", document_json={"type": "doc", "schema_version": 1, "content": []}, markdown="", revision=1, status="active"))
        session.commit()
        grant = NoteCapabilityService(
            session, keyring, issuer="https://notes.test", max_lifetime_seconds=1200
        ).issue(
            owner_user_id="user_a", note_id="note_a", run_id="run_a", scopes=["note:read"],
            run_expires_at=datetime.now(UTC) + timedelta(minutes=20),
        )
        session.commit()

    async def send() -> httpx.Response:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://notes.test") as client:
            return await client.post(
                "/mcp",
                headers={"Authorization": f"Bearer {grant.token}"},
                json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
            )

    response = asyncio.run(send())
    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "NOTE_CAPABILITY_DENIED"
