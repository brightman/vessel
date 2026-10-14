from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from pages_service.auth.tokens import KeyRing
from pages_service.models import Page, PageCapability


ALLOWED_SCOPES = frozenset({"page:read", "page:propose"})


class CapabilityError(ValueError):
    pass


@dataclass(frozen=True)
class CapabilityGrant:
    token: str
    jti: str
    expires_at: datetime


class PageCapabilityService:
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
        page_id: str,
        run_id: str,
        scopes: list[str],
        run_expires_at: datetime,
        selection: dict[str, Any] | None = None,
        now: datetime | None = None,
    ) -> CapabilityGrant:
        issued_at = now or datetime.now(UTC)
        run_expiry = _aware(run_expires_at)
        page = self.session.scalar(
            select(Page).where(
                Page.page_id == page_id,
                Page.owner_user_id == owner_user_id,
                Page.status == "active",
            )
        )
        if page is None:
            raise CapabilityError("Page not found")
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
            audience="baizhi-pages-mcp",
            scope=scope,
            lifetime_seconds=lifetime_seconds,
            token_id=jti,
            additional_claims={"page_id": page_id, "run_id": run_id},
            now=issued_at,
        )
        self.session.add(
            PageCapability(
                capability_id=str(uuid4()),
                jti=jti,
                owner_user_id=owner_user_id,
                page_id=page_id,
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
        page_id: str | None = None,
        run_id: str | None = None,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        if required_scope not in ALLOWED_SCOPES:
            raise CapabilityError("Capability scope is not allowed")
        claims = self.keyring.verify(
            token,
            issuer=self.issuer,
            audience="baizhi-pages-mcp",
            required_scope=required_scope,
        )
        if not claims:
            raise CapabilityError("Invalid Page capability")
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
            raise CapabilityError("Page capability lifetime exceeds the configured maximum")
        claim_page_id = claims.get("page_id")
        claim_run_id = claims.get("run_id")
        if not isinstance(claim_page_id, str) or not isinstance(claim_run_id, str):
            raise CapabilityError("Page capability scope mismatch")
        page_id = page_id or claim_page_id
        run_id = run_id or claim_run_id
        if claim_page_id != page_id or claim_run_id != run_id:
            raise CapabilityError("Page capability scope mismatch")
        scopes = claims.get("scope", "").split()
        if not scopes or not set(scopes).issubset(ALLOWED_SCOPES):
            raise CapabilityError("Capability scope is not allowed")
        record = self.session.scalar(
            select(PageCapability).where(
                PageCapability.jti == claims.get("jti"),
                PageCapability.owner_user_id == claims.get("sub"),
                PageCapability.page_id == page_id,
                PageCapability.run_id == run_id,
            )
        )
        if record is None:
            raise CapabilityError("Page capability was not issued by this service")
        if record.revoked_at is not None:
            raise CapabilityError("Page capability was revoked")
        current_time = now or datetime.now(UTC)
        if _aware(record.expires_at) <= current_time:
            raise CapabilityError("Page capability expired")
        if set(record.scope.split()) != set(scopes):
            raise CapabilityError("Page capability scope mismatch")
        return claims

    def revoke(self, jti: str, *, now: datetime | None = None) -> bool:
        result = self.session.execute(
            update(PageCapability)
            .where(PageCapability.jti == jti, PageCapability.revoked_at.is_(None))
            .values(revoked_at=now or datetime.now(UTC))
        )
        self.session.flush()
        return result.rowcount == 1

    def revoke_run(self, *, page_id: str, run_id: str, now: datetime | None = None) -> int:
        result = self.session.execute(
            update(PageCapability)
            .where(
                PageCapability.page_id == page_id,
                PageCapability.run_id == run_id,
                PageCapability.revoked_at.is_(None),
            )
            .values(revoked_at=now or datetime.now(UTC))
        )
        self.session.flush()
        return result.rowcount or 0


def _aware(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
