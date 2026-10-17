"""Authenticated HTTP transport for Vessel's existing API."""

import time
from uuid import uuid4

import httpx

from .config import CliError


class VesselClient:
    def __init__(self, environment: str, origin: str, credentials, *, transport=None, now=time.time):
        self.environment, self.origin, self.credentials, self.now = environment, origin, credentials, now
        self.http = httpx.Client(base_url=origin, timeout=30, follow_redirects=False, transport=transport)

    def close(self):
        self.http.close()

    def _send(self, method: str, path: str, *, authenticated=False, body=None, params=None, idempotent=False, refresh=False):
        headers = {}
        if authenticated:
            session = self.credentials.load(self.environment, self.origin)
            if session["expires_at"] <= self.now() + 30 and not refresh:
                session = self.refresh()
            headers["Authorization"] = f"Bearer {session['access_token']}"
        if refresh:
            session = self.credentials.load(self.environment, self.origin)
            headers["Cookie"] = f"vessel_refresh={session['refresh_token']}"
        if idempotent:
            headers["Idempotency-Key"] = str(uuid4())
        try:
            response = self.http.request(method, path, json=body, params=params, headers=headers)
        except httpx.HTTPError as exc:
            raise CliError("NETWORK_ERROR") from exc
        if response.status_code >= 400:
            try:
                detail = response.json().get("detail", {})
                code = detail.get("code") if isinstance(detail, dict) else None
            except ValueError:
                code = None
            raise CliError(code or "HTTP_ERROR", status=response.status_code)
        if response.status_code == 204:
            return {}, response
        try:
            return response.json(), response
        except ValueError as exc:
            raise CliError("RESPONSE_INVALID") from exc

    def _save_session(self, data, response):
        token = data.get("access_token")
        refresh = response.cookies.get("vessel_refresh")
        ttl = data.get("expires_in")
        if not token or not refresh or not isinstance(ttl, int):
            raise CliError("SESSION_INVALID")
        self.credentials.save(self.environment, self.origin, {"access_token": token, "refresh_token": refresh,
                                                                "expires_at": int(self.now() + ttl)})

    def login(self, email: str, password: str) -> dict:
        data, response = self._send("POST", "/v1/auth/login", body={"email": email, "password": password})
        self._save_session(data, response)
        return {"user": data.get("user")}

    def refresh(self) -> dict:
        data, response = self._send("POST", "/v1/auth/refresh", refresh=True)
        self._save_session(data, response)
        return self.credentials.load(self.environment, self.origin)

    def logout(self) -> dict:
        self._send("POST", "/v1/auth/logout", refresh=True)
        self.credentials.delete(self.environment, self.origin)
        return {"logged_out": True}

    def request(self, method: str, path: str, *, body=None, params=None, idempotent=False) -> dict:
        result, _ = self._send(method, path, authenticated=True, body=body, params=params, idempotent=idempotent)
        return result

    def text(self, method: str, path: str) -> dict:
        session = self.credentials.load(self.environment, self.origin)
        if session["expires_at"] <= self.now() + 30:
            session = self.refresh()
        try:
            response = self.http.request(method, path, headers={"Authorization": f"Bearer {session['access_token']}"})
        except httpx.HTTPError as exc:
            raise CliError("NETWORK_ERROR") from exc
        if response.status_code >= 400:
            try:
                detail = response.json().get("detail", {})
                code = detail.get("code") if isinstance(detail, dict) else None
            except ValueError:
                code = None
            raise CliError(code or "HTTP_ERROR", status=response.status_code)
        return {"markdown": response.text}
