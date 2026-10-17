"""Registration-only email codes. No plaintext code is persisted or returned."""
import hashlib
import hmac
import math
import secrets
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import httpx
from fastapi import HTTPException
from sqlalchemy import select, text, update
from sqlalchemy.orm import Session

from vessel_service.models import User
from vessel_service.models.registration_email import RegistrationEmailChallenge, RegistrationEmailLimit
from vessel_service.settings import Settings

TTL_SECONDS = 600
RESEND_SECONDS = 60
MAX_ATTEMPTS = 5
# One short critical section shares cooldowns, quotas and consumption across instances.
# Never hold this PostgreSQL transaction lock during provider network I/O.
REGISTRATION_LOCK = 7820364182991

class MailDeliveryError(Exception):
    def __init__(self):
        super().__init__("EMAIL_DELIVERY_UNAVAILABLE")

class BrevoMailer:
    def __init__(self, settings: Settings, *, transport: httpx.BaseTransport | None = None):
        self.settings = settings
        self.transport = transport

    def ensure_configured(self):
        if not self.settings.brevo_api_key or not self.settings.brevo_api_key.get_secret_value() or not self.settings.brevo_sender_email:
            raise MailDeliveryError()

    def send(self, email: str, code: str) -> str:
        self.ensure_configured()
        message = f"Your Memory on Cloud verification code is {code}. It expires in 10 minutes. If you did not request this code, ignore this email."
        try:
            with httpx.Client(timeout=self.settings.brevo_timeout_seconds, transport=self.transport, trust_env=False) as client:
                response = client.post("https://api.brevo.com/v3/smtp/email", headers={
                    "api-key": self.settings.brevo_api_key.get_secret_value(),
                    "accept": "application/json", "content-type": "application/json",
                }, json={
                    "sender": {"email": self.settings.brevo_sender_email, "name": self.settings.brevo_sender_name},
                    "to": [{"email": email}], "subject": "Your Memory on Cloud verification code",
                    "textContent": message,
                    "htmlContent": f"<html><body><h1>Verify your email</h1><p>Your Memory on Cloud verification code:</p><p style='font-size:32px;letter-spacing:6px'><strong>{code}</strong></p><p>Expires in 10 minutes. If you did not request this code, ignore this email.</p></body></html>",
                })
            if response.status_code != 201:
                raise MailDeliveryError()
            message_id = response.json().get("messageId")
            if not isinstance(message_id, str) or not message_id:
                raise MailDeliveryError()
            return message_id
        except (httpx.HTTPError, ValueError, TypeError, AttributeError):
            raise MailDeliveryError() from None


def utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def lock_registration(session: Session):
    if session.get_bind().dialect.name == "postgresql":
        session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": REGISTRATION_LOCK})


def digest(settings: Settings, *parts: str) -> str:
    if not settings.registration_code_secret:
        raise HTTPException(503, detail={"code": "EMAIL_DELIVERY_UNAVAILABLE"})
    return hmac.new(settings.registration_code_secret.get_secret_value().encode(), "\0".join(parts).encode(), hashlib.sha256).hexdigest()


def request_code(session: Session, settings: Settings, mailer: BrevoMailer, email: str, source: str) -> dict:
    # Check deployment configuration before reserving or sending anything.
    digest(settings, "configuration-check")
    try:
        mailer.ensure_configured()
    except MailDeliveryError:
        raise HTTPException(503, detail={"code": "EMAIL_DELIVERY_UNAVAILABLE"}) from None
    lock_registration(session)
    now = datetime.now(UTC)
    if session.scalar(select(User.user_id).where(User.email == email)):
        raise HTTPException(409, detail={"code": "EMAIL_ALREADY_REGISTERED"})
    tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    email_key = digest(settings, "email-limit", email)
    source_key = digest(settings, "source-limit", source)
    windows = [
        (f"global:{now.date()}", settings.registration_email_daily_limit, tomorrow),
        (f"email-day:{now.date()}:{email_key}", 5, tomorrow),
        (f"ip-hour:{source_key}", 20, now + timedelta(hours=1)),
        (f"cooldown:{email_key}", 1, now + timedelta(seconds=RESEND_SECONDS)),
    ]
    reserved = []
    for key, maximum, expires in windows:
        row = session.get(RegistrationEmailLimit, key)
        if row and utc(row.expires_at) > now and row.hits >= maximum:
            remaining = max(1, math.ceil((utc(row.expires_at) - now).total_seconds()))
            raise HTTPException(429, detail={"code": "EMAIL_CODE_RATE_LIMITED"}, headers={"Retry-After": str(remaining)})
        reserved.append((key, expires, row))
    for key, expires, row in reserved:
        if row is None:
            session.add(RegistrationEmailLimit(bucket_key=key, hits=1, expires_at=expires))
        elif utc(row.expires_at) <= now:
            row.hits, row.expires_at = 1, expires
        else:
            row.hits += 1
    challenge_id = str(uuid4())
    code = f"{secrets.randbelow(1_000_000):06d}"
    session.add(RegistrationEmailChallenge(challenge_id=challenge_id, email=email,
        code_digest=digest(settings, "registration", challenge_id, email, code), status="pending", attempts=0,
        created_at=now, expires_at=now + timedelta(seconds=TTL_SECONDS)))
    session.commit()  # Release all locks before HTTPS; failed/ambiguous sends still cost quota.
    try:
        mailer.send(email, code)
    except MailDeliveryError:
        lock_registration(session)
        row = session.get(RegistrationEmailChallenge, challenge_id)
        row.status = "failed"
        session.commit()
        raise HTTPException(503, detail={"code": "EMAIL_DELIVERY_UNAVAILABLE"}, headers={"Retry-After": str(RESEND_SECONDS)}) from None
    lock_registration(session)
    current = session.get(RegistrationEmailChallenge, challenge_id)
    newer = session.scalar(select(RegistrationEmailChallenge.challenge_id).where(
        RegistrationEmailChallenge.email == email,
        RegistrationEmailChallenge.created_at > current.created_at,
        RegistrationEmailChallenge.status.in_(["sent", "consumed"]),
    ).limit(1))
    if newer:
        current.status = "superseded"
    else:
        session.execute(update(RegistrationEmailChallenge).where(
            RegistrationEmailChallenge.email == email,
            RegistrationEmailChallenge.created_at < current.created_at,
            RegistrationEmailChallenge.status == "sent",
        ).values(status="superseded"))
        current.status = "sent"
    session.commit()
    return {"challenge_id": challenge_id, "expires_in": TTL_SECONDS, "resend_after": RESEND_SECONDS}


def consume_code(session: Session, settings: Settings, email: str, challenge_id: str | None, code: str | None):
    if not challenge_id or not code:
        raise HTTPException(422, detail={"code": "EMAIL_VERIFICATION_REQUIRED"})
    digest(settings, "configuration-check")
    lock_registration(session)
    row = session.scalar(select(RegistrationEmailChallenge).where(RegistrationEmailChallenge.challenge_id == challenge_id).with_for_update())
    now = datetime.now(UTC)
    if not row or row.email != email or row.status != "sent" or row.attempts >= MAX_ATTEMPTS or utc(row.expires_at) <= now:
        raise HTTPException(422, detail={"code": "EMAIL_CODE_INVALID"})
    if not hmac.compare_digest(row.code_digest, digest(settings, "registration", challenge_id, email, code)):
        row.attempts += 1
        if row.attempts >= MAX_ATTEMPTS:
            row.status = "locked"
        session.commit()  # Wrong guesses must survive the error response.
        raise HTTPException(422, detail={"code": "EMAIL_CODE_INVALID"})
    row.status, row.consumed_at = "consumed", now
    # Caller commits consumption together with account/space/session creation.
