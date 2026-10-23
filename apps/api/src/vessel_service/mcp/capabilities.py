from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session
from fastapi import HTTPException

from vessel_service.auth.tokens import KeyRing
from vessel_service.models import Note, NoteCapability, User
from vessel_service.spaces.permissions import space_access


ALLOWED_SCOPES = frozenset({"note:read", "note:propose"})


class CapabilityError(ValueError):
    pass


@dataclass(frozen=True)
class CapabilityGrant:
    token: str
    jti: str
    expires_at: datetime


class NoteCapabilityService:
    def __init__(
        self,
        session: Session,
        keyring: KeyRing,
        *,
        issuer: str,
        max_lifetime_seconds: int,
    ) -> None:
        if max_lifetime_seconds < 1:
            raise ValueError("Capability lifetime must be positive")
        self.session = session
        self.keyring = keyring
        self.issuer = issuer
        self.max_lifetime_seconds = max_lifetime_seconds

    def issue(
        self,
        *,
        owner_user_id: str,
        note_id: str,
        run_id: str,
        scopes: list[str],
        run_expires_at: datetime,
        selection: dict[str, Any] | None = None,
        now: datetime | None = None,
    ) -> CapabilityGrant:
        issued_at = now or datetime.now(UTC)
        run_expiry = _aware(run_expires_at)
        self._check_access(note_id, owner_user_id, write="note:propose" in scopes)
        if not isinstance(run_id, str) or not run_id.strip() or len(run_id) > 128:
            raise CapabilityError("Invalid run id")
        if not scopes or len(set(scopes)) != len(scopes) or not set(scopes).issubset(ALLOWED_SCOPES):
            raise CapabilityError("Capability scope is not allowed")
        expires_at = min(issued_at + timedelta(seconds=self.max_lifetime_seconds), run_expiry)
        lifetime_seconds = int((expires_at - issued_at).total_seconds())
        if lifetime_seconds < 1:
            raise CapabilityError("Capability exceeds run lifetime")
        expires_at = issued_at + timedelta(seconds=lifetime_seconds)
        jti = str(uuid4())
        scope = " ".join(sorted(scopes))
        token = self.keyring.issue(
            subject=owner_user_id,
            issuer=self.issuer,
            audience="baizhi-notes-mcp",
            scope=scope,
            lifetime_seconds=lifetime_seconds,
            token_id=jti,
            additional_claims={"note_id": note_id, "run_id": run_id},
            now=issued_at,
        )
        self.session.add(
            NoteCapability(
                capability_id=str(uuid4()),
                jti=jti,
                owner_user_id=owner_user_id,
                note_id=note_id,
                run_id=run_id,
                scope=scope,
                selection_json=selection,
                expires_at=expires_at,
                revoked_at=None,
                created_at=issued_at,
            )
        )
        self.session.flush()
        return CapabilityGrant(token=token, jti=jti, expires_at=expires_at)

    def verify(
        self,
        token: str,
        *,
        required_scope: str,
        note_id: str | None = None,
        run_id: str | None = None,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        if required_scope not in ALLOWED_SCOPES:
            raise CapabilityError("Capability scope is not allowed")
        claims = self.keyring.verify(
            token,
            issuer=self.issuer,
            audience="baizhi-notes-mcp",
            required_scope=required_scope,
        )
        if not claims:
            raise CapabilityError("Invalid Note capability")
        issued_at = claims.get("iat")
        expires_at = claims.get("exp")
        if (
            isinstance(issued_at, bool)
            or not isinstance(issued_at, (int, float))
            or isinstance(expires_at, bool)
            or not isinstance(expires_at, (int, float))
            or expires_at <= issued_at
            or expires_at - issued_at > self.max_lifetime_seconds
        ):
            raise CapabilityError("Note capability lifetime exceeds the configured maximum")
        claim_note_id = claims.get("note_id")
        claim_run_id = claims.get("run_id")
        if not isinstance(claim_note_id, str) or not isinstance(claim_run_id, str):
            raise CapabilityError("Note capability scope mismatch")
        note_id = note_id or claim_note_id
        run_id = run_id or claim_run_id
        if claim_note_id != note_id or claim_run_id != run_id:
            raise CapabilityError("Note capability scope mismatch")
        scopes = claims.get("scope", "").split()
        if not scopes or not set(scopes).issubset(ALLOWED_SCOPES):
            raise CapabilityError("Capability scope is not allowed")
        record = self.session.scalar(
            select(NoteCapability).where(
                NoteCapability.jti == claims.get("jti"),
                NoteCapability.owner_user_id == claims.get("sub"),
                NoteCapability.note_id == note_id,
                NoteCapability.run_id == run_id,
            )
        )
        if record is None:
            raise CapabilityError("Note capability was not issued by this service")
        if record.revoked_at is not None:
            raise CapabilityError("Note capability was revoked")
        current_time = now or datetime.now(UTC)
        if _aware(record.expires_at) <= current_time:
            raise CapabilityError("Note capability expired")
        if set(record.scope.split()) != set(scopes):
            raise CapabilityError("Note capability scope mismatch")
        self._check_access(note_id, claims["sub"], write=required_scope == "note:propose")
        return claims

    def _check_access(self, note_id: str, actor_user_id: str, *, write: bool) -> None:
        note = self.session.scalar(select(Note).where(Note.note_id == note_id, Note.status == "active"))
        user = self.session.get(User, actor_user_id)
        if note is None or user is None or user.status != "active":
            raise CapabilityError("Note not found")
        try:
            space_access(self.session, user, note.space_id, capability="can_write" if write else "can_read")
        except HTTPException as error:
            raise CapabilityError("Note access denied") from error

    def revoke(self, jti: str, *, now: datetime | None = None) -> bool:
        result = self.session.execute(
            update(NoteCapability)
            .where(NoteCapability.jti == jti, NoteCapability.revoked_at.is_(None))
            .values(revoked_at=now or datetime.now(UTC))
        )
        self.session.flush()
        return result.rowcount == 1

    def revoke_run(self, *, note_id: str, run_id: str, now: datetime | None = None) -> int:
        result = self.session.execute(
            update(NoteCapability)
            .where(
                NoteCapability.note_id == note_id,
                NoteCapability.run_id == run_id,
                NoteCapability.revoked_at.is_(None),
            )
            .values(revoked_at=now or datetime.now(UTC))
        )
        self.session.flush()
        return result.rowcount or 0


def _aware(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
