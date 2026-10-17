"""Vessel sessions in an operating-system keychain only."""

import json

from .config import CliError


SERVICE = "vessel-cli"
SECURE_PREFIXES = ("keyring.backends.macos.", "keyring.backends.windows.",
                   "keyring.backends.secretservice.", "keyring.backends.libsecret.",
                   "keyring.backends.kwallet")


class CredentialStore:
    def __init__(self, *, backend=None, allow_test_backend=False):
        if backend is None:
            try:
                import keyring
                backend = keyring.get_keyring()
            except Exception as exc:
                raise CliError("CREDENTIAL_STORE_UNAVAILABLE") from exc
        identity = f"{type(backend).__module__}.{type(backend).__name__}".lower()
        if not allow_test_backend and (not identity.startswith(SECURE_PREFIXES) or getattr(backend, "priority", 0) <= 0):
            raise CliError("CREDENTIAL_STORE_UNAVAILABLE")
        self.backend = backend

    @staticmethod
    def _key(environment: str, origin: str) -> str:
        return f"{environment}|{origin}"

    def save(self, environment: str, origin: str, session: dict) -> None:
        if not all(session.get(key) for key in ("access_token", "refresh_token", "expires_at")):
            raise CliError("SESSION_INVALID")
        try:
            self.backend.set_password(SERVICE, self._key(environment, origin), json.dumps(session))
        except Exception as exc:
            raise CliError("CREDENTIAL_STORE_WRITE_FAILED") from exc

    def load(self, environment: str, origin: str) -> dict:
        try:
            raw = self.backend.get_password(SERVICE, self._key(environment, origin))
        except Exception as exc:
            raise CliError("CREDENTIAL_STORE_READ_FAILED") from exc
        if not raw:
            raise CliError("NOT_LOGGED_IN")
        try:
            value = json.loads(raw)
            if not all(value.get(key) for key in ("access_token", "refresh_token", "expires_at")):
                raise ValueError()
            return value
        except (TypeError, ValueError, AttributeError) as exc:
            raise CliError("SESSION_INVALID") from exc

    def delete(self, environment: str, origin: str) -> None:
        try:
            self.backend.delete_password(SERVICE, self._key(environment, origin))
        except Exception as exc:
            if exc.__class__.__name__ not in {"PasswordDeleteError", "PasswordNotFoundError"}:
                raise CliError("CREDENTIAL_STORE_DELETE_FAILED") from exc
