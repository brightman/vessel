"""Regressions for the current gateway-based Note Agent adapter."""

from pydantic import SecretStr
from vessel_service.mcp.server import TOOLS


def test_edit_runtime_mcp_names_fit_model_limit_and_tokens_stay_run_scoped(api_factory, monkeypatch):
    applications = []
    def configure(app):
        applications.append(app)
        settings = app.state.settings
        settings.agent_platform_url = "http://agent.test"
        settings.agent_id = "agent_test"
        settings.agent_gateway_user_id = "agent_owner"
        settings.agent_gateway_secret = SecretStr("gateway-test-secret")
        settings.agent_mcp_url = "http://notes.test/mcp"

    api = api_factory(configure_application=configure)
    auth = api("POST", "/v1/auth/register", json={
        "name": "MCP regression", "email": "mcp-names@example.test", "password": "mcp-regression-2026",
    })
    assert auth.status_code == 201
    headers = {"Authorization": f"Bearer {auth.json()['access_token']}"}
    captured = []

    class Response:
        def __init__(self, payload):
            self.payload = payload

        def raise_for_status(self):
            pass

        def json(self):
            return self.payload

    def post(url, *, headers, json, timeout):
        captured.append(json)
        return Response({"run_id": json["options"]["run_id"], "thread_id": json["thread_id"], "status": "queued"})

    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", post)
    note_ids = []
    for index in range(2):
        created = api("POST", "/v1/notes", headers=headers, json={
            "title": f"MCP regression {index}",
            "document": {"type": "doc", "schema_version": 1, "content": []},
        })
        assert created.status_code == 201
        note_id = created.json()["note"]["note_id"]
        note_ids.append(note_id)
        started = api("POST", f"/v1/notes/{note_id}/agent/runs", headers=headers,
                      json={"message": "Propose a title change", "mode": "edit"})
        assert started.status_code == 202, started.text

    configs = [body["options"]["runtime_mcps"][0] for body in captured]
    for index, config in enumerate(configs):
        for tool in TOOLS:
            name = f"mcp_runtime_{config['id']}_{tool['name']}"
            assert len(name) <= 64, name
        assert config["tool_selection"] == {
            "mode": "allowlist", "tool_names": [tool["name"] for tool in TOOLS],
        }
        token = config["headers_template"]["Authorization"].removeprefix("Bearer ")
        claims = applications[0].state.keyring.verify(
            token, issuer="https://notes.test", audience="baizhi-notes-mcp", required_scope="note:propose",
        )
        assert claims["note_id"] == note_ids[index]
        assert claims["run_id"] == captured[index]["options"]["run_id"]
    assert configs[0]["id"] == configs[1]["id"] == "vessel_note"
    assert configs[0]["headers_template"] != configs[1]["headers_template"]

