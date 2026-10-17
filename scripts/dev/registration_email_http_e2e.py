"""Isolated PostgreSQL + real HTTP/browser acceptance. Never sends real email.

Requires an already migrated dedicated database named vessel_e2e and a built console.
Run from repository root using the API virtualenv. Starts/stops its own loopback HTTP server.
"""
import os
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlsplit

import httpx
import uvicorn
from pydantic import SecretStr
from sqlalchemy import func, select

from vessel_service.auth.email_verification import MailDeliveryError, lock_registration
from vessel_service.auth.cleanup_email_codes import cleanup
from datetime import UTC, datetime, timedelta
from vessel_service.main import create_app
from vessel_service.models import RefreshSession, Space, User
from vessel_service.models.registration_email import RegistrationEmailChallenge, RegistrationEmailLimit
from vessel_service.settings import Settings


def main():
    database_url = os.environ["PAGES_DATABASE_URL"]
    if urlsplit(database_url).path != "/vessel_e2e" or not database_url.startswith("postgresql"):
        raise SystemExit("Use only a dedicated PostgreSQL database named vessel_e2e")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    base = f"http://127.0.0.1:{listener.getsockname()[1]}"
    settings = Settings(environment="test", database_url=database_url, issuer_url=base,
                        allow_registration=True, refresh_cookie_secure=False,
                        registration_email_verification_required=True,
                        registration_code_secret=SecretStr("isolated-registration-e2e-secret-not-for-production"))
    application = create_app(settings)
    class Mailbox:
        def ensure_configured(self): pass
        def send(self, email, code):
            if not email.endswith("@example.test") or code != "246810":
                raise MailDeliveryError()
            return "controlled-test-mail"
    application.state.registration_mailer = Mailbox()
    server = uvicorn.Server(uvicorn.Config(application, log_level="error", access_log=False))
    thread = threading.Thread(target=server.run, kwargs={"sockets":[listener]}, daemon=True)
    with patch("vessel_service.auth.email_verification.secrets.randbelow", return_value=246810):
        thread.start()
        try:
            for _ in range(500):
                if server.started: break
                if not thread.is_alive(): raise RuntimeError("HTTP server failed")
                time.sleep(0.01)
            if not server.started: raise RuntimeError("HTTP startup timeout")
            run_id = os.urandom(6).hex()
            # Cleanup must not select an expired bucket then delete its renewed version.
            bucket = f"ip-hour:cleanup-race-{run_id}"
            with application.state.session_factory() as session:
                session.add(RegistrationEmailLimit(bucket_key=bucket, hits=1, expires_at=datetime.now(UTC)-timedelta(days=9)))
                session.commit()
            with application.state.session_factory() as writer, ThreadPoolExecutor(max_workers=1) as pool:
                lock_registration(writer)
                writer.get(RegistrationEmailLimit, bucket).expires_at = datetime.now(UTC) + timedelta(hours=1)
                writer.flush()
                def prune():
                    with application.state.session_factory() as session:
                        return cleanup(session)
                pruning = pool.submit(prune)
                try:
                    pruning.result(timeout=0.25)
                    raise AssertionError("Cleanup must wait for the reservation transaction")
                except FutureTimeout:
                    pass
                writer.commit()
                pruning.result(timeout=5)
            with application.state.session_factory() as session:
                assert session.get(RegistrationEmailLimit, bucket) is not None, "Cleanup deleted a renewed rate bucket"
            print("PostgreSQL cleanup/reservation race passed", flush=True)
            email = f"concurrent-{run_id}@example.test"
            def send():
                return httpx.post(base + "/v1/auth/registration/email-code", json={"email":email})
            with ThreadPoolExecutor(max_workers=2) as pool:
                sent = list(pool.map(lambda _: send(), range(2)))
            assert sorted(result.status_code for result in sent) == [202,429]
            challenge = next(result.json()["challenge_id"] for result in sent if result.status_code == 202)
            def signup():
                return httpx.post(base + "/v1/auth/register", json={"email":email, "name":"Concurrent", "password":"concurrent-test-password", "challenge_id":challenge, "verification_code":"246810"})
            with ThreadPoolExecutor(max_workers=2) as pool:
                registered = list(pool.map(lambda _: signup(), range(2)))
            assert sum(result.status_code == 201 for result in registered) == 1
            assert all(result.status_code in {201,409,422} for result in registered)
            with application.state.session_factory() as session:
                user = session.scalar(select(User).where(User.email == email))
                assert user.email_verified_at is not None
                assert session.scalar(select(func.count()).select_from(RefreshSession).where(RefreshSession.user_id == user.user_id)) == 1
                assert session.scalar(select(func.count()).select_from(Space).where(Space.owner_user_id == user.user_id)) == 1
                assert session.get(RegistrationEmailChallenge, challenge).status == "consumed"
            bad_email = f"guesses-{run_id}@example.test"
            result = httpx.post(base + "/v1/auth/registration/email-code", json={"email":bad_email})
            assert result.status_code == 202
            bad_id = result.json()["challenge_id"]
            def guess():
                return httpx.post(base + "/v1/auth/register", json={"email":bad_email, "name":"Guess", "password":"concurrent-test-password", "challenge_id":bad_id, "verification_code":"111111"})
            with ThreadPoolExecutor(max_workers=6) as pool:
                guesses = list(pool.map(lambda _: guess(), range(6)))
            assert all(result.status_code == 422 for result in guesses)
            with application.state.session_factory() as session:
                row = session.get(RegistrationEmailChallenge, bad_id)
                assert row.status == "locked" and row.attempts == 5
                assert session.scalar(select(User).where(User.email == bad_email)) is None
                before = session.scalar(select(func.count()).select_from(User))
            print("PostgreSQL HTTP concurrency: send cooldown, one-time consumption, five-attempt lock passed", flush=True)
            repo = Path(__file__).resolve().parents[2]
            subprocess.run(["npx", "playwright", "test", "tests/e2e/registration-email.spec.mjs", "--reporter=line"], cwd=repo,
                env={**os.environ, "VESSEL_E2E_ORIGIN":base, "VESSEL_REGISTRATION_REAL_E2E":"1"}, check=True)
            with application.state.session_factory() as session:
                assert session.scalar(select(func.count()).select_from(User)) == before + 1
            print("Real HTTP browser signup and refresh passed; no real provider email sent", flush=True)
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            listener.close()
            application.state.database_engine.dispose()

if __name__ == "__main__": main()
