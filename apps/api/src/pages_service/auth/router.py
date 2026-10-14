import hashlib
import re
import secrets
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from pages_service.auth.passwords import hash_password, verify_password
from pages_service.auth.tokens import KeyRing
from pages_service.models import RefreshSession, User, UserCredential
from pages_service.settings import Settings

router = APIRouter()
bearer = HTTPBearer(auto_error=False)
REFRESH_COOKIE_NAME = "pages_refresh"


class RegisterRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=8, max_length=256)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", normalized):
            raise ValueError("Invalid email address")
        return normalized


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=1, max_length=256)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_keyring(request: Request) -> KeyRing:
    keyring = request.app.state.keyring
    if keyring is None:
        raise HTTPException(status_code=503, detail={"code": "AUTH_NOT_CONFIGURED"})
    return keyring


def get_session(request: Request) -> Iterator[Session]:
    session_factory = request.app.state.session_factory
    if session_factory is None:
        raise HTTPException(status_code=503, detail={"code": "DATABASE_NOT_CONFIGURED"})
    with session_factory() as session:
        yield session


def _user_payload(user: User) -> dict[str, object]:
    return {
        "user_id": user.user_id,
        "email": user.email,
        "name": user.name,
        "roles": user.roles,
    }


def _issue_access_token(user: User, settings: Settings, keyring: KeyRing) -> str:
    return keyring.issue(
        subject=user.user_id,
        issuer=settings.issuer_url,
        audience="baizhi-pages-api",
        scope="pages:session",
        lifetime_seconds=settings.access_token_ttl_seconds,
    )


def _set_refresh_cookie(
    response: Response, raw_token: str, settings: Settings
) -> None:
    response.set_cookie(
        key=REFRESH_COOKIE_NAME,
        value=raw_token,
        max_age=settings.refresh_token_ttl_seconds,
        path="/v1/auth",
        secure=settings.refresh_cookie_secure,
        httponly=True,
        samesite="lax",
    )


def _create_refresh_session(session: Session, user: User, settings: Settings) -> str:
    raw_token = secrets.token_urlsafe(48)
    session.add(
        RefreshSession(
            session_id=str(uuid4()),
            user_id=user.user_id,
            token_hash=hashlib.sha256(raw_token.encode("utf-8")).hexdigest(),
            expires_at=datetime.now(UTC)
            + timedelta(seconds=settings.refresh_token_ttl_seconds),
        )
    )
    return raw_token


def _auth_response(
    user: User, session: Session, response: Response, settings: Settings, keyring: KeyRing
) -> dict[str, object]:
    raw_refresh = _create_refresh_session(session, user, settings)
    session.commit()
    _set_refresh_cookie(response, raw_refresh, settings)
    return {
        "access_token": _issue_access_token(user, settings, keyring),
        "token_type": "bearer",
        "expires_in": settings.access_token_ttl_seconds,
        "user": _user_payload(user),
    }


@router.get("/v1/auth/options")
def auth_options(settings: Settings = Depends(get_settings)) -> dict[str, bool]:
    return {"registration_enabled": settings.allow_registration}


@router.post("/v1/auth/register", status_code=201)
def register(
    payload: RegisterRequest,
    response: Response,
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    if not settings.allow_registration:
        raise HTTPException(status_code=403, detail={"code": "REGISTRATION_DISABLED"})
    if session.scalar(select(User.user_id).where(User.email == payload.email)):
        raise HTTPException(status_code=409, detail={"code": "EMAIL_ALREADY_REGISTERED"})

    user = User(
        user_id=str(uuid4()),
        email=payload.email,
        name=payload.name.strip(),
        roles=["user"],
        status="active",
    )
    user.credential = UserCredential(password_hash=hash_password(payload.password))
    session.add(user)
    try:
        session.flush()
        body = _auth_response(user, session, response, settings, keyring)
    except IntegrityError as error:
        session.rollback()
        raise HTTPException(
            status_code=409, detail={"code": "EMAIL_ALREADY_REGISTERED"}
        ) from error
    return body


@router.post("/v1/auth/login")
def login(
    payload: LoginRequest,
    response: Response,
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    user = session.scalar(
        select(User)
        .options(selectinload(User.credential))
        .where(User.email == payload.email)
    )
    password_hash = user.credential.password_hash if user and user.credential else None
    password_ok = verify_password(password_hash, payload.password)
    if not user or user.status != "active" or not password_ok:
        raise HTTPException(status_code=401, detail={"code": "INVALID_CREDENTIALS"})
    return _auth_response(user, session, response, settings, keyring)


@router.post("/v1/auth/refresh")
def refresh(
    request: Request,
    response: Response,
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    raw_token = request.cookies.get(REFRESH_COOKIE_NAME)
    if not raw_token:
        raise HTTPException(status_code=401, detail={"code": "INVALID_REFRESH_TOKEN"})
    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    current = session.scalar(
        select(RefreshSession).where(RefreshSession.token_hash == token_hash)
    )
    now = datetime.now(UTC)
    if not current or current.revoked_at or _as_utc(current.expires_at) <= now:
        raise HTTPException(status_code=401, detail={"code": "INVALID_REFRESH_TOKEN"})
    user = session.get(User, current.user_id)
    if not user or user.status != "active":
        current.revoked_at = now
        session.commit()
        raise HTTPException(status_code=401, detail={"code": "INVALID_REFRESH_TOKEN"})
    current.revoked_at = now
    return _auth_response(user, session, response, settings, keyring)


@router.post("/v1/auth/logout", status_code=204)
def logout(
    request: Request,
    settings: Settings = Depends(get_settings),
    session: Session = Depends(get_session),
) -> Response:
    raw_token = request.cookies.get(REFRESH_COOKIE_NAME)
    if raw_token:
        token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
        current = session.scalar(
            select(RefreshSession).where(RefreshSession.token_hash == token_hash)
        )
        if current and current.revoked_at is None:
            current.revoked_at = datetime.now(UTC)
            session.commit()
    cleared = Response(status_code=204)
    cleared.delete_cookie(
        key=REFRESH_COOKIE_NAME,
        path="/v1/auth",
        secure=settings.refresh_cookie_secure,
        httponly=True,
        samesite="lax",
    )
    return cleared


@router.get("/v1/auth/me")
def me(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    if not credentials:
        raise HTTPException(status_code=401, detail={"code": "AUTHENTICATION_REQUIRED"})
    claims = keyring.verify(
        credentials.credentials,
        issuer=settings.issuer_url,
        audience="baizhi-pages-api",
        required_scope="pages:session",
    )
    user = session.get(User, claims["sub"]) if claims else None
    if not user or user.status != "active":
        raise HTTPException(status_code=401, detail={"code": "INVALID_ACCESS_TOKEN"})
    return {"user": _user_payload(user)}


@router.get("/.well-known/jwks.json")
def jwks(keyring: KeyRing = Depends(get_keyring)) -> dict[str, list[dict[str, str]]]:
    return keyring.jwks()


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)
