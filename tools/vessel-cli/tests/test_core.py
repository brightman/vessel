import json
import os
import stat
from pathlib import Path

import httpx
import pytest

from vessel_cli.config import Config, CliError, normalize_origin
from vessel_cli.credentials import CredentialStore
from vessel_cli.client import VesselClient


def test_config_requires_named_environment_and_https_production(tmp_path):
    config = Config(tmp_path / "hosts.json", environ={})
    with pytest.raises(CliError, match="ENVIRONMENT_REQUIRED"):
        config.resolve(None)
    with pytest.raises(CliError, match="HTTPS_REQUIRED"):
        config.set("production", "http://example.com")
    assert normalize_origin("http://LOCALHOST:52003/") == "http://localhost:52003"
    config.set("local", "http://127.0.0.1:52003")
    assert config.resolve("local") == "http://127.0.0.1:52003"
    assert "token" not in (tmp_path / "hosts.json").read_text()


def test_credentials_store_env_sessions_with_private_permissions(tmp_path):
    path = tmp_path / "vessel" / "credentials.env"
    store = CredentialStore(path=path)
    session = {"access_token": "short", "refresh_token": "long", "expires_at": 9999999999}
    store.save("local", "http://localhost:1", session)
    assert store.load("local", "http://localhost:1") == session
    content = path.read_text(encoding="utf-8")
    assert "VESSEL_ACCESS_TOKEN_LOCAL_" in content
    assert "short" in content and "long" in content
    with pytest.raises(CliError, match="NOT_LOGGED_IN"):
        store.load("test", "http://localhost:1")
    with pytest.raises(CliError, match="NOT_LOGGED_IN"):
        store.load("local", "http://localhost:2")
    if os.name != "nt":
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    store.delete("local", "http://localhost:1")
    with pytest.raises(CliError, match="NOT_LOGGED_IN"):
        store.load("local", "http://localhost:1")


def test_login_refresh_and_api_error_redaction(tmp_path):
    requests = []
    def handler(request):
        requests.append(request)
        if request.url.path == "/v1/auth/login":
            return httpx.Response(200, json={"access_token": "first", "expires_in": 1, "user": {"user_id": "u"}}, headers={"set-cookie": "vessel_refresh=secret1; Path=/; HttpOnly"})
        if request.url.path == "/v1/auth/refresh":
            assert request.headers["cookie"] == "vessel_refresh=secret1"
            return httpx.Response(200, json={"access_token": "second", "expires_in": 900, "user": {"user_id": "u"}}, headers={"set-cookie": "vessel_refresh=secret2; Path=/; HttpOnly"})
        if request.url.path == "/v1/spaces":
            assert request.headers["authorization"] == "Bearer second"
            return httpx.Response(200, json={"spaces": []})
        return httpx.Response(409, json={"detail": {"code": "NOTE_REVISION_CONFLICT", "message": "secret1"}})
    store = CredentialStore(path=tmp_path / "credentials.env")
    client = VesselClient("local", "http://localhost:1", store, transport=httpx.MockTransport(handler), now=lambda: 100)
    result = client.login("a@example.com", "password")
    assert result == {"user": {"user_id": "u"}}
    assert store.load("local", "http://localhost:1")["refresh_token"] == "secret1"
    assert "secret1" in (tmp_path / "credentials.env").read_text(encoding="utf-8")
    assert client.request("GET", "/v1/spaces") == {"spaces": []}
    assert store.load("local", "http://localhost:1")["refresh_token"] == "secret2"
    with pytest.raises(CliError) as caught:
        client.request("GET", "/v1/missing")
    assert caught.value.code == "NOTE_REVISION_CONFLICT"
    assert "secret1" not in str(caught.value)


@pytest.mark.parametrize("operation", ["login", "refresh"])
def test_auth_preflights_env_file_writes_before_network(operation, tmp_path):
    requests = []

    def handler(request):
        requests.append(request)
        if request.url.path == "/v1/auth/login":
            return httpx.Response(
                200,
                json={"access_token": "new", "expires_in": 900, "user": {}},
                headers={"set-cookie": "vessel_refresh=new-refresh; Path=/; HttpOnly"},
            )
        return httpx.Response(
            200,
            json={"access_token": "new", "expires_in": 900, "user": {}},
            headers={"set-cookie": "vessel_refresh=new-refresh; Path=/; HttpOnly"},
        )

    path = tmp_path / "credentials" / "sessions.env"
    store = CredentialStore(path=path)
    if operation == "refresh":
        store.save("local", "http://localhost:1", {
            "access_token": "old", "refresh_token": "old-refresh", "expires_at": 1000,
        })
        store.delete("local", "http://localhost:1")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.rmdir()
    path.parent.write_text("directory replaced with a file", encoding="utf-8")
    client = VesselClient(
        "local", "http://localhost:1", store,
        transport=httpx.MockTransport(handler), now=lambda: 100,
    )

    with pytest.raises(CliError) as caught:
        if operation == "login":
            client.login("a@example.com", "password")
        else:
            client.refresh()

    assert caught.value.code == "CREDENTIAL_STORE_WRITE_FAILED"
    assert requests == []


def test_env_probe_removes_only_its_temporary_entry(tmp_path):
    path = tmp_path / "credentials.env"
    path.write_text("KEEP_THIS=unchanged\n", encoding="utf-8")
    store = CredentialStore(path=path)
    store.probe()
    content = path.read_text(encoding="utf-8")
    assert content == "KEEP_THIS=unchanged\n"


def test_auth_login_sends_request_after_env_preflight(tmp_path):
    requests = []
    store = CredentialStore(path=tmp_path / "credentials.env")
    client = VesselClient(
        "local", "http://localhost:1", store,
        transport=httpx.MockTransport(lambda request: requests.append(request) or httpx.Response(
            200,
            json={"access_token": "issued", "expires_in": 900, "user": {}},
            headers={"set-cookie": "vessel_refresh=issued-refresh; Path=/; HttpOnly"},
        )),
        now=lambda: 100,
    )

    client.login("a@example.com", "password")
    assert [request.url.path for request in requests] == ["/v1/auth/login"]
    assert store.load("local", "http://localhost:1")["access_token"] == "issued"
