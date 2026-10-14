import base64
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


@dataclass(frozen=True)
class SigningKey:
    kid: str
    public_key: Ed25519PublicKey
    private_key: Ed25519PrivateKey | None = None


class KeyRing:
    def __init__(self, keys: list[SigningKey], active_kid: str) -> None:
        indexed = {key.kid: key for key in keys}
        if len(indexed) != len(keys):
            raise ValueError("Signing key IDs must be unique")
        active = indexed.get(active_kid)
        if active is None or active.private_key is None:
            raise ValueError("Active signing key must include private key material")
        self._keys = indexed
        self.active_kid = active_kid

    @classmethod
    def for_test(cls, kid: str) -> "KeyRing":
        private_key = Ed25519PrivateKey.generate()
        return cls(
            [SigningKey(kid, private_key.public_key(), private_key)],
            active_kid=kid,
        )

    @classmethod
    def for_development(cls) -> "KeyRing":
        """Create a process-local key that is never suitable for production."""
        private_key = Ed25519PrivateKey.generate()
        return cls(
            [SigningKey("local-ephemeral", private_key.public_key(), private_key)],
            active_kid="local-ephemeral",
        )

    @classmethod
    def from_file(cls, path: Path) -> "KeyRing":
        content = json.loads(path.read_text(encoding="utf-8"))
        keys: list[SigningKey] = []
        for entry in content["keys"]:
            private_key = None
            if entry.get("private_key_pem"):
                loaded = serialization.load_pem_private_key(
                    entry["private_key_pem"].encode("utf-8"), password=None
                )
                if not isinstance(loaded, Ed25519PrivateKey):
                    raise ValueError("Only Ed25519 signing keys are supported")
                private_key = loaded
                public_key = loaded.public_key()
            else:
                loaded_public = serialization.load_pem_public_key(
                    entry["public_key_pem"].encode("utf-8")
                )
                if not isinstance(loaded_public, Ed25519PublicKey):
                    raise ValueError("Only Ed25519 public keys are supported")
                public_key = loaded_public
            keys.append(SigningKey(entry["kid"], public_key, private_key))
        return cls(keys, active_kid=content["active_kid"])

    def issue(
        self,
        *,
        subject: str,
        issuer: str,
        audience: str,
        scope: str,
        lifetime_seconds: int,
        token_id: str | None = None,
        additional_claims: dict[str, Any] | None = None,
        now: datetime | None = None,
    ) -> str:
        issued_at = now or datetime.now(UTC)
        key = self._keys[self.active_kid]
        claims = {
            "iss": issuer,
            "sub": subject,
            "aud": audience,
            "scope": scope,
            "iat": issued_at,
            "nbf": issued_at,
            "exp": issued_at + timedelta(seconds=lifetime_seconds),
            "jti": token_id or str(uuid4()),
        }
        extras = additional_claims or {}
        if set(extras).intersection(claims):
            raise ValueError("Additional JWT claims cannot override registered claims")
        claims.update(extras)
        return jwt.encode(
            claims,
            key.private_key,
            algorithm="EdDSA",
            headers={"kid": key.kid, "typ": "JWT"},
        )

    def verify(
        self,
        token: str,
        *,
        issuer: str,
        audience: str,
        required_scope: str,
    ) -> dict[str, Any] | None:
        try:
            header = jwt.get_unverified_header(token)
            key = self._keys.get(header.get("kid", ""))
            if key is None:
                return None
            claims = jwt.decode(
                token,
                key.public_key,
                algorithms=["EdDSA"],
                issuer=issuer,
                audience=audience,
                options={
                    "require": ["exp", "iat", "nbf", "iss", "aud", "sub", "jti", "scope"]
                },
            )
            if required_scope not in claims.get("scope", "").split():
                return None
            return claims
        except (jwt.PyJWTError, TypeError, ValueError):
            return None

    def jwks(self) -> dict[str, list[dict[str, str]]]:
        keys = []
        for key in self._keys.values():
            raw_public = key.public_key.public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
            keys.append(
                {
                    "kty": "OKP",
                    "crv": "Ed25519",
                    "use": "sig",
                    "alg": "EdDSA",
                    "kid": key.kid,
                    "x": base64.urlsafe_b64encode(raw_public).rstrip(b"=").decode("ascii"),
                }
            )
        return {"keys": keys}
