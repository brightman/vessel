"""Verify local user provisioning and login with public registration disabled."""

import os
import secrets
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

import httpx


def main(base_url: str) -> None:
    if not os.environ.get("NOTES_DATABASE_URL"):
        raise SystemExit("Set NOTES_DATABASE_URL to an isolated local test database")
    email = f"local-{uuid4().hex[:10]}@example.test"
    password = secrets.token_urlsafe(24)
    api_dir = Path(__file__).resolve().parents[2] / "apps" / "api"
    env = os.environ.copy()
    env["PYTHONPATH"] = str(api_dir / "src")
    created = subprocess.run(
        [sys.executable, "-m", "vessel_service.bootstrap_admin", "--role", "user"],
        input=f"Local User\n{email}\n{password}\n", text=True,
        cwd=api_dir, env=env, capture_output=True, check=False,
    )
    assert created.returncode == 0, created.stderr

    with httpx.Client(base_url=base_url, timeout=10) as client:
        assert client.get("/healthz").status_code == 200
        disabled = client.post(
            "/v1/auth/register",
            json={"name": "Public", "email": f"public-{email}", "password": password},
        )
        assert disabled.status_code == 403, disabled.text
        login = client.post("/v1/auth/login", json={"email": email, "password": password})
        assert login.status_code == 200, login.text
        token = login.json()["access_token"]
        assert login.json()["user"]["roles"] == ["user"]
        spaces = client.get("/v1/spaces", headers={"Authorization": f"Bearer {token}"})
        assert spaces.status_code == 200, spaces.text
        assert len(spaces.json()["spaces"]) == 1
        assert spaces.json()["spaces"][0]["kind"] == "personal"

    print("local_user=created registration=403 login=200 personal_space=200")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/dev/local_user_http_e2e.py http://127.0.0.1:PORT")
    main(sys.argv[1])
