"""Per-environment Vessel sessions stored in a private dotenv file."""

import json
import os
import re
from hashlib import sha256
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

from .config import CliError


ASSIGNMENT = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


class CredentialStore:
    def __init__(self, path: Path | None = None, *, environ=None):
        self.environ = os.environ if environ is None else environ
        base = self.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        self.path = path or Path(base) / "vessel" / ".env"

    @staticmethod
    def _keys(environment: str, origin: str) -> dict[str, str]:
        suffix = f"{environment.upper()}_{sha256(origin.encode('utf-8')).hexdigest()[:16].upper()}"
        return {
            "access_token": f"VESSEL_ACCESS_TOKEN_{suffix}",
            "refresh_token": f"VESSEL_REFRESH_TOKEN_{suffix}",
            "expires_at": f"VESSEL_EXPIRES_AT_{suffix}",
        }

    @staticmethod
    def _decode(value: str) -> str:
        value = value.strip()
        if value.startswith('"'):
            try:
                result = json.loads(value)
            except ValueError as exc:
                raise CliError("CREDENTIAL_ENV_INVALID") from exc
            if not isinstance(result, str):
                raise CliError("CREDENTIAL_ENV_INVALID")
            return result
        if value.startswith("'") and value.endswith("'") and len(value) >= 2:
            return value[1:-1]
        return value.partition(" #")[0].strip()

    def _read_file(self) -> dict[str, str]:
        try:
            if self.path.is_symlink():
                raise CliError("CREDENTIAL_STORE_UNAVAILABLE")
            if not self.path.exists():
                return {}
            if os.name != "nt":
                os.chmod(self.path, 0o600)
            values = {}
            for line in self.path.read_text(encoding="utf-8").splitlines():
                match = ASSIGNMENT.match(line)
                if match:
                    values[match.group(1)] = self._decode(match.group(2))
            return values
        except CliError:
            raise
        except (OSError, UnicodeError) as exc:
            raise CliError("CREDENTIAL_STORE_READ_FAILED") from exc

    def _update_file(self, changes: dict[str, str | None]) -> None:
        temporary = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if os.name != "nt" and self.path.parent.name == "vessel":
                os.chmod(self.path.parent, 0o700)
            if self.path.is_symlink():
                raise CliError("CREDENTIAL_STORE_UNAVAILABLE")
            existing = self.path.read_text(encoding="utf-8").splitlines() if self.path.exists() else []
            retained = []
            for line in existing:
                match = ASSIGNMENT.match(line)
                if not match or match.group(1) not in changes:
                    retained.append(line)
            for key, value in changes.items():
                if value is not None:
                    retained.append(f"{key}={json.dumps(value)}")
            if not retained:
                self.path.unlink(missing_ok=True)
                return
            text = "\n".join(retained) + ("\n" if retained else "")
            with NamedTemporaryFile("w", encoding="utf-8", dir=self.path.parent, prefix=".credentials.", delete=False) as output:
                if os.name != "nt":
                    os.fchmod(output.fileno(), 0o600)
                output.write(text)
                output.flush()
                os.fsync(output.fileno())
                temporary = Path(output.name)
            os.replace(temporary, self.path)
            temporary = None
        except CliError:
            raise
        except (OSError, UnicodeError) as exc:
            raise CliError("CREDENTIAL_STORE_WRITE_FAILED") from exc
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def probe(self) -> None:
        """Check dotenv write/read/delete before requesting or rotating a session."""
        key = f"VESSEL_CLI_PROBE_{uuid4().hex.upper()}"
        value = uuid4().hex
        try:
            self._update_file({key: value})
            if self._read_file().get(key) != value:
                raise CliError("CREDENTIAL_STORE_VALIDATION_FAILED")
        finally:
            self._update_file({key: None})

    def save(self, environment: str, origin: str, session: dict) -> None:
        if not all(session.get(key) for key in ("access_token", "refresh_token", "expires_at")):
            raise CliError("SESSION_INVALID")
        if not isinstance(session["expires_at"], int):
            raise CliError("SESSION_INVALID")
        keys = self._keys(environment, origin)
        self._update_file({key: str(session[field]) for field, key in keys.items()})

    def load(self, environment: str, origin: str) -> dict:
        keys = self._keys(environment, origin)
        values = self._read_file()
        try:
            session = {
                field: values[key] for field, key in keys.items()
            }
            session["expires_at"] = int(session["expires_at"])
            if not session["access_token"] or not session["refresh_token"]:
                raise ValueError()
            return session
        except (KeyError, TypeError, ValueError) as exc:
            if not any(key in values for key in keys.values()):
                raise CliError("NOT_LOGGED_IN") from exc
            raise CliError("SESSION_INVALID") from exc

    def delete(self, environment: str, origin: str) -> None:
        keys = self._keys(environment, origin)
        self._update_file({key: None for key in keys.values()})
