"""Run Note Agent browser acceptance against a dedicated migrated vessel_e2e DB.

The gateway is a controlled HTTP server by default. --live uses only the Agent
connection fields from apps/api/.env; credentials never reach browser/output.
All Vessel accounts and Notes are disposable test records in the isolated DB.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import SecretStr
import uvicorn

from vessel_service.main import create_app
from vessel_service.settings import Settings

ROOT = Path(__file__).resolve().parents[2]


def start_server(app):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    origin = f"http://127.0.0.1:{listener.getsockname()[1]}"
    if hasattr(app, "state") and hasattr(app.state, "settings"):
        app.state.settings.issuer_url = origin
    server = uvicorn.Server(uvicorn.Config(app, log_level="error", access_log=False))
    worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    worker.start()
    for _ in range(300):
        if server.started:
            return origin, server, worker
        if not worker.is_alive():
            raise RuntimeError("Test HTTP server stopped during startup")
        time.sleep(0.01)
    raise RuntimeError("Test HTTP server startup timed out")


def controlled_gateway():
    gateway = FastAPI()
    runs = {}

    @gateway.get("/v1/agent-configs/{agent_id}")
    def config(agent_id: str):
        return {"agent_id": agent_id, "agent_type": "native", "output_schema": {"type": "object"}}

    @gateway.post("/v1/agent/runs")
    def start(body: dict):
        options = body["options"]
        context = options["context"]["turn_prompt_context"]
        prompt = body["message"]
        revision = int(re.search(r"revision (\d+)", context)[1])
        response = {"schema_version": 1, "type": "answer", "message": "This Note records the original acceptance text.",
                    "sources": [{"title": "Reference", "url": "https://example.org/reference"}]}
        if "clarify" in prompt:
            response = {"schema_version": 1, "type": "clarification", "message": "Which season should I use?",
                        "options": [{"id": "season-2026", "label": "2026 season"}, {"id": "season-2025", "label": "2025 season"}]}
        elif "edit" in prompt or "season" in prompt:
            document = json.loads(context.split("<note-document-json>\n", 1)[1].split("\n</note-document-json>", 1)[0])
            operations = [{"type": "set_title", "title": "Agent preview title"}]
            # Replace all existing top-level blocks with one table-bearing document fragment.
            existing_ids = [block.get("attrs", {}).get("block_id") for block in document["content"]]
            if existing_ids:
                operations.append({"type": "delete_blocks", "block_ids": existing_ids})
            blocks = [{"type": "paragraph", "attrs": {"block_id": "agent-result"},
                       "content": [{"type": "text", "text": "Agent preview body"}]},
                      {"type": "table", "attrs": {"block_id": "agent-table"}, "content": [
                          {"type": "tableRow", "content": [
                              {"type": "tableCell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": text}]}]}
                              for text in ["2026-01-01", "Test city", "Opponent", "6-4 6-3"]]}]}]
            operations.append({"type": "insert_blocks_after", "after_block_id": None, "blocks_json": json.dumps(blocks)})
            response = {"schema_version": 1, "type": "edit", "message": "Prepared the requested edit.",
                        "proposal": {"base_revision": revision, "operations": operations, "summary": "Replace acceptance content with table preview."}}
        run = {"run_id": options["run_id"], "thread_id": body["thread_id"], "status": "completed", "output_text": json.dumps(response)}
        runs[run["run_id"]] = run
        return {**run, "status": "queued"}

    @gateway.get("/v1/runs/{run_id}")
    def result(run_id: str):
        return runs[run_id]

    @gateway.get("/v1/runs/{run_id}/events")
    def events(run_id: str):
        def frames():
            # Ensure the browser can observe working state before completion.
            yield 'event: RUN_STARTED\ndata: {"payload": {}}\n\n'
            time.sleep(0.15)
            yield 'event: done\ndata: {"status":"completed"}\n\n'
        return StreamingResponse(frames(), media_type="text/event-stream")

    @gateway.post("/v1/runs/{run_id}/cancel")
    def cancel(run_id: str):
        runs[run_id]["status"] = "cancelled"
        return {"status": "cancelled"}

    return gateway


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--serve", action="store_true", help="Leave test server running for manual browser inspection")
    args = parser.parse_args()
    database_url = os.environ["NOTES_DATABASE_URL"]
    if not database_url.startswith("postgresql") or database_url.rsplit("/", 1)[-1] != "vessel_e2e":
        raise SystemExit("Requires dedicated PostgreSQL database vessel_e2e")
    services = []
    if args.live:
        configured = Settings(_env_file=ROOT / "apps/api/.env")
        # Record only disposable test response bodies for protocol diagnostics.
        import vessel_service.agent_platform as adapter
        parse_response = adapter.parse_agent_response
        def record_response(output, **kwargs):
            diagnostic = ROOT / "var/note-agent-live-responses.jsonl"
            diagnostic.parent.mkdir(exist_ok=True)
            with diagnostic.open("a") as stream:
                stream.write(json.dumps({"output_text": output}, ensure_ascii=False) + "\n")
            return parse_response(output, **kwargs)
        adapter.parse_agent_response = record_response
        agent_fields = {key: getattr(configured, key) for key in (
            "agent_platform_url", "agent_id", "agent_gateway_secret", "agent_gateway_user_id")}
        if not all(agent_fields.values()):
            raise SystemExit("Live Agent connection is not configured")
    else:
        gateway_origin, gateway_server, gateway_worker = start_server(controlled_gateway())
        services.append((gateway_server, gateway_worker))
        agent_fields = {"agent_platform_url": gateway_origin, "agent_id": "agent_e2e",
                        "agent_gateway_secret": SecretStr("isolated-gateway-test"), "agent_gateway_user_id": "test_owner"}
    settings = Settings(environment="test", database_url=database_url, issuer_url="http://127.0.0.1",
                        allow_registration=True, registration_email_verification_required=False,
                        refresh_cookie_secure=False, **agent_fields)
    origin, server, worker = start_server(create_app(settings=settings))
    services.append((server, worker))
    print(f"Isolated Note Agent {'live' if args.live else 'controlled'} service: {origin}", flush=True)
    try:
        if args.serve:
            while True:
                time.sleep(1)
        env = {**os.environ, "VESSEL_E2E_ORIGIN": origin, "VESSEL_AGENT_LIVE": "1" if args.live else "0"}
        result = subprocess.run([str(ROOT / "node_modules/.bin/playwright"), "test", "tests/e2e/note-agent-integrated.spec.mjs", "--reporter=line"], cwd=ROOT, env=env)
        raise SystemExit(result.returncode)
    finally:
        for current, thread in reversed(services):
            current.should_exit = True
            thread.join(timeout=5)


if __name__ == "__main__":
    main()
