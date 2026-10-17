"""Named Vessel origins; this file never contains credentials."""

import json
import ipaddress
import os
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


ENVIRONMENTS = ("local", "test", "staging", "production")


class CliError(Exception):
    def __init__(self, code: str, *, status: int | None = None):
        super().__init__(code)
        self.code = code
        self.status = status


def normalize_origin(value: str) -> str:
    try:
        parts = urlsplit(value.strip())
        port = parts.port
    except (AttributeError, ValueError) as exc:
        raise CliError("ORIGIN_INVALID") from exc
    if (parts.scheme not in {"http", "https"} or not parts.hostname or parts.username or parts.password
            or parts.path not in {"", "/"} or parts.query or parts.fragment):
        raise CliError("ORIGIN_INVALID")
    host = parts.hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    return urlunsplit((parts.scheme.lower(), host + (f":{port}" if port is not None else ""), "", "", ""))


def validate_environment_origin(environment: str, origin: str) -> str:
    normalized = normalize_origin(origin)
    parts = urlsplit(normalized)
    if parts.scheme == "https":
        return normalized
    if environment not in {"local", "test"}:
        raise CliError("HTTPS_REQUIRED")
    host = parts.hostname or ""
    is_loopback = host == "localhost" or host.endswith(".localhost")
    if not is_loopback:
        try:
            is_loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            is_loopback = False
    if not is_loopback:
        raise CliError("HTTPS_REQUIRED")
    return normalized


class Config:
    def __init__(self, path: Path | None = None, *, environ=None):
        self.environ = os.environ if environ is None else environ
        base = self.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        self.path = path or Path(base) / "vessel" / "hosts.json"

    def _name(self, name: str | None) -> str:
        chosen = name or self.environ.get("VESSEL_ENV")
        if not chosen:
            raise CliError("ENVIRONMENT_REQUIRED")
        if chosen not in ENVIRONMENTS:
            raise CliError("ENVIRONMENT_INVALID")
        return chosen

    def _read(self) -> dict[str, str]:
        if not self.path.exists():
            return {}
        try:
            values = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(values, dict):
                raise ValueError()
            return {self._name(k): normalize_origin(v) for k, v in values.items()}
        except (OSError, ValueError, TypeError) as exc:
            raise CliError("HOST_CONFIG_INVALID") from exc

    def resolve(self, name: str | None) -> str:
        selected = self._name(name)
        origin = self.environ.get(f"VESSEL_HOST_{selected.upper()}") or self._read().get(selected)
        if not origin:
            raise CliError("HOST_NOT_CONFIGURED")
        return validate_environment_origin(selected, origin)

    def set(self, name: str, origin: str) -> str:
        selected = self._name(name)
        origin = validate_environment_origin(selected, origin)
        values = self._read()
        values[selected] = origin
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        from tempfile import NamedTemporaryFile
        with NamedTemporaryFile("w", encoding="utf-8", dir=self.path.parent, prefix=".hosts.", delete=False) as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(values, output, sort_keys=True, indent=2)
            output.write("\n")
            temporary = Path(output.name)
        os.replace(temporary, self.path)
        return origin

    def list(self) -> dict[str, str | None]:
        return {name: (self.resolve(name) if self.environ.get(f"VESSEL_HOST_{name.upper()}") or name in self._read() else None)
                for name in ENVIRONMENTS}
