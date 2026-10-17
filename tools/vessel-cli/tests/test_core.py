import json
from pathlib import Path

import httpx
import pytest

from vessel_cli.config import Config, CliError, normalize_origin
from vessel_cli.credentials import CredentialStore
from vessel_cli.client import VesselClient


class FakeBackend:
    priority = 5
    def __init__(self):
        self.values = {}
    def get_password(self, service, key):
        return self.values.get((service, key))
    def set_password(self, service, key, value):
        self.values[(service, key)] = value
    def delete_password(self, service, key):
        self.values.pop((service, key), None)


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


def test_credentials_isolate_environment_and_origin():
    backend = FakeBackend()
    store = CredentialStore(backend=backend, allow_test_backend=True)
    session = {"access_token": "short", "refresh_token": "long", "expires_at": 9999999999}
    store.save("local", "http://localhost:1", session)
    assert store.load("local", "http://localhost:1") == session
    with pytest.raises(CliError, match="NOT_LOGGED_IN"):
        store.load("test", "http://localhost:1")
    with pytest.raises(CliError, match="NOT_LOGGED_IN"):
        store.load("local", "http://localhost:2")
    with pytest.raises(CliError, match="CREDENTIAL_STORE_UNAVAILABLE"):
        CredentialStore(backend=backend)


def test_login_refresh_and_api_error_redaction():
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
        return httpx.Response(409, json={"detail": {"code": "PAGE_REVISION_CONFLICT", "message": "secret1"}})
    store = CredentialStore(backend=FakeBackend(), allow_test_backend=True)
    client = VesselClient("local", "http://localhost:1", store, transport=httpx.MockTransport(handler), now=lambda: 100)
    result = client.login("a@example.com", "password")
    assert result == {"user": {"user_id": "u"}}
    assert store.load("local", "http://localhost:1")["refresh_token"] == "secret1"
    assert client.request("GET", "/v1/spaces") == {"spaces": []}
    assert store.load("local", "http://localhost:1")["refresh_token"] == "secret2"
    with pytest.raises(CliError) as caught:
        client.request("GET", "/v1/missing")
    assert caught.value.code == "PAGE_REVISION_CONFLICT"
    assert "secret1" not in str(caught.value)
