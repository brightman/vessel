"""Space-owned App manifests and typed records for the Vessel HTTP API."""

import base64
import hashlib
import json
import mimetypes
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, Response, UploadFile
from fastapi.responses import RedirectResponse
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field, field_validator, model_validator
from sqlalchemy import Numeric, and_, cast, func, or_, select, update
from sqlalchemy.orm import Session

from vessel_service.apps.h5_release import MAX_ZIP_BYTES
from vessel_service.apps.manifest import ManifestError, check_additive_manifest, normalize_manifest, normalize_record, normalize_value
from vessel_service.apps.releases import (
    ReleaseError, create_draft, draft_asset, issue_h5_launch_ticket, issue_preview_ticket, publish_draft,
    release_payload, rollback_release, upload_draft, verify_h5_launch_ticket, verify_preview_ticket,
)
from vessel_service.apps.release_storage import AppReleaseStorageError
from vessel_service.auth.router import bearer, get_keyring, get_session, get_settings
from vessel_service.auth.tokens import KeyRing
from vessel_service.models import User, VesselApp, VesselAppAuditEvent, VesselAppRecord, VesselAppRelease
from vessel_service.pages.router import current_user
from vessel_service.settings import Settings
from vessel_service.spaces.permissions import space_access

router = APIRouter(tags=["apps"])
APP_MANAGER_ROLES = {"owner", "admin"}
PREVIEW_COOKIE_NAME = "vessel_app_preview"
H5_LAUNCH_COOKIE_NAME = "vessel_app_h5_launch"


class AppCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    manifest: dict[str, Any]

    @field_validator("name")
    @classmethod
    def trim_name(cls, value: str) -> str:
        name = value.strip()
        if not name:
            raise ValueError("App name cannot be blank")
        return name


class ManifestUpdate(BaseModel):
    expected_version: int = Field(ge=1)
    manifest: dict[str, Any]


class AppSettingsUpdate(BaseModel):
    expected_settings_version: int = Field(ge=1)
    name: str | None = Field(default=None, max_length=120)
    description: str | None = Field(default=None, max_length=2000)

    @field_validator("name")
    @classmethod
    def trim_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            raise ValueError("App name cannot be blank")
        return value

    @field_validator("description")
    @classmethod
    def trim_description(cls, value: str | None) -> str | None:
        return value.strip() if value is not None else None

    @model_validator(mode="after")
    def requires_change(self) -> "AppSettingsUpdate":
        if self.name is None and self.description is None:
            raise ValueError("At least one App setting is required")
        return self


class SettingsVersionRequest(BaseModel):
    expected_settings_version: int = Field(ge=1)


class RecordCreate(BaseModel):
    values: dict[str, Any]


class BulkCreate(BaseModel):
    records: list[RecordCreate] = Field(min_length=1, max_length=100)


class RecordUpdate(BaseModel):
    expected_row_version: int = Field(ge=1)
    values: dict[str, Any]


class VersionRequest(BaseModel):
    expected_row_version: int = Field(ge=1)


class RecordVersion(BaseModel):
    id: str = Field(min_length=1, max_length=36)
    expected_row_version: int = Field(ge=1)


class BulkDeleteRequest(BaseModel):
    records: list[RecordVersion] = Field(min_length=1, max_length=100)


class RecordQuery(BaseModel):
    filter: dict[str, Any] | None = None
    search: str | None = Field(default=None, max_length=120)
    sort: list[dict[str, str]] = Field(default_factory=list, max_length=3)
    limit: int = Field(default=50, ge=1, le=200)
    cursor: str | None = None

    @field_validator("search")
    @classmethod
    def normalize_search(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        return value or None


def _invalid(error: ManifestError) -> HTTPException:
    return HTTPException(status_code=422, detail={"code": error.code})


def current_app_user(
    app_id: str,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> User:
    if not credentials:
        raise HTTPException(status_code=401, detail={"code": "AUTHENTICATION_REQUIRED"})
    token = credentials.credentials
    claims = keyring.verify(token, issuer=settings.issuer_url, audience="vessel-api", required_scope="vessel:session")
    if claims is None:
        claims = keyring.verify(token, issuer=settings.issuer_url, audience="vessel-app-h5", required_scope="vessel:app-h5")
        if claims is None:
            raise HTTPException(status_code=401, detail={"code": "INVALID_ACCESS_TOKEN"})
        if claims.get("app_id") != app_id or type(claims.get("release_version")) is not int:
            raise HTTPException(status_code=404, detail={"code": "APP_NOT_FOUND"})
    user = session.get(User, claims["sub"])
    if not user or user.status != "active":
        raise HTTPException(status_code=401, detail={"code": "INVALID_ACCESS_TOKEN"})
    return user


def _app(
    session: Session, user: User, app_id: str, *, write: bool = False,
    include_archived_for_manager: bool = False, require_manager: bool = False,
) -> VesselApp:
    app = session.scalar(select(VesselApp).where(VesselApp.app_id == app_id))
    if app is None:
        raise HTTPException(status_code=404, detail={"code": "APP_NOT_FOUND"})
    try:
        _, role = space_access(
            session, user, app.space_id,
            capability="can_read" if require_manager else ("can_write" if write else "can_read"),
            lock=write or require_manager,
        )
    except HTTPException as error:
        if error.status_code == 404:
            raise HTTPException(status_code=404, detail={"code": "APP_NOT_FOUND"}) from error
        raise
    if write or require_manager:
        session.refresh(app)
    if require_manager and role not in APP_MANAGER_ROLES:
        raise HTTPException(status_code=403, detail={"code": "APP_MANAGER_REQUIRED"})
    if app.status != "active" and not (include_archived_for_manager and role in APP_MANAGER_ROLES):
        raise HTTPException(status_code=404, detail={"code": "APP_NOT_FOUND"})
    return app


def _fields(app: VesselApp, table_name: str) -> dict:
    table = app.manifest_json["tables"].get(table_name)
    if table is None:
        raise HTTPException(status_code=404, detail={"code": "APP_TABLE_NOT_FOUND"})
    return table["fields"]


def _row(session: Session, app: VesselApp, table_name: str, record_id: str, *, deleted: bool = False) -> VesselAppRecord:
    row = session.scalar(select(VesselAppRecord).where(
        VesselAppRecord.record_id == record_id,
        VesselAppRecord.app_id == app.app_id,
        VesselAppRecord.table_name == table_name,
        VesselAppRecord.deleted_at.is_not(None) if deleted else VesselAppRecord.deleted_at.is_(None),
    ))
    if row is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RECORD_NOT_FOUND"})
    return row


def _app_payload(app: VesselApp) -> dict:
    return {"app_id": app.app_id, "space_id": app.space_id, "name": app.name,
            "manifest": app.manifest_json, "manifest_version": app.manifest_version,
            "description": app.description, "settings_version": app.settings_version,
            "status": app.status, "archived_at": app.archived_at.isoformat() if app.archived_at else None,
            "created_at": app.created_at.isoformat(),
            "updated_at": app.updated_at.isoformat()}


def _row_payload(row: VesselAppRecord) -> dict:
    return {"id": row.record_id, "values": row.values_json, "created_at": row.created_at.isoformat(),
            "updated_at": row.updated_at.isoformat(), "created_by": row.created_by,
            "updated_by": row.updated_by, "row_version": row.row_version,
            "deleted_at": row.deleted_at.isoformat() if row.deleted_at else None}


def _audit(session: Session, app_id: str, actor_user_id: str, action: str, details: dict[str, Any]) -> None:
    session.add(VesselAppAuditEvent(
        event_id=str(uuid4()), app_id=app_id, actor_user_id=actor_user_id,
        action=action, details_json=details, created_at=datetime.now(UTC),
    ))


def _release_storage(request: Request):
    storage = getattr(request.app.state, "app_release_storage", None)
    if storage is None:
        raise HTTPException(status_code=503, detail={"code": "APP_RELEASE_STORAGE_UNAVAILABLE"})
    return storage


def _release_error(error: ReleaseError) -> HTTPException:
    return HTTPException(status_code=error.status_code, detail={"code": error.code})


def _release_origin(settings: Settings, app_id: str) -> str:
    try:
        origin = settings.app_release_origin_for(app_id)
    except ValueError:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"}) from None
    if not origin:
        raise HTTPException(status_code=503, detail={"code": "APP_RELEASE_ORIGIN_NOT_CONFIGURED"})
    return origin


def _release_url(settings: Settings, app_id: str, path: str) -> str:
    return _release_origin(settings, app_id).rstrip("/") + path


def _require_release_origin(request: Request, settings: Settings, app_id: str) -> None:
    expected_host = _release_origin(settings, app_id).split("://", 1)[1]
    if request.headers.get("host", "").lower() != expected_host:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"})


def _release_payload(release: VesselAppRelease, settings: Settings) -> dict:
    payload = release_payload(release)
    payload["public_url"] = (
        _release_url(settings, release.app_id, f"/apps/{release.app_id}/releases/{release.version}/{release.entry_file or 'index.html'}")
        if release.status == "published" else None
    )
    return payload


@router.get("/v1/spaces/{space_id}/apps")
def list_apps(space_id: str, status: Literal["active", "archived"] = "active",
              user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    _, role = space_access(session, user, space_id)
    if status == "archived" and role not in APP_MANAGER_ROLES:
        raise HTTPException(status_code=403, detail={"code": "APP_MANAGER_REQUIRED"})
    apps = session.scalars(select(VesselApp).where(VesselApp.space_id == space_id, VesselApp.status == status)
                           .order_by(VesselApp.created_at, VesselApp.app_id)).all()
    return {"apps": [_app_payload(app) for app in apps]}


@router.post("/v1/spaces/{space_id}/apps", status_code=201)
def create_app(space_id: str, payload: AppCreate, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    _, role = space_access(session, user, space_id, capability="can_write", lock=True)
    if role not in APP_MANAGER_ROLES:
        raise HTTPException(status_code=403, detail={"code": "APP_MANAGER_REQUIRED"})
    try:
        manifest = normalize_manifest(payload.manifest)
    except ManifestError as error:
        raise _invalid(error) from error
    now = datetime.now(UTC)
    app = VesselApp(app_id=str(uuid4()), space_id=space_id, name=payload.name,
                    manifest_json=manifest, manifest_version=1, settings_version=1, status="active", description="",
                    created_by=user.user_id, updated_by=user.user_id, created_at=now, updated_at=now)
    session.add(app)
    session.commit()
    return {"app": _app_payload(app)}


@router.get("/v1/apps/{app_id}")
def get_app(app_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    return {"app": _app_payload(_app(session, user, app_id, include_archived_for_manager=True))}


@router.get("/v1/apps/{app_id}/tables")
def list_tables(app_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id)
    return {"tables": [{"name": name, "fields": table["fields"]} for name, table in app.manifest_json["tables"].items()],
            "manifest_version": app.manifest_version}


@router.put("/v1/apps/{app_id}/manifest")
def update_manifest(app_id: str, payload: ManifestUpdate, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True, require_manager=True)
    if app.manifest_version != payload.expected_version:
        raise HTTPException(status_code=409, detail={"code": "APP_MANIFEST_VERSION_CONFLICT"})
    try:
        manifest = normalize_manifest(payload.manifest)
        check_additive_manifest(app.manifest_json, manifest)
    except ManifestError as error:
        raise _invalid(error) from error
    result = session.execute(update(VesselApp).where(
        VesselApp.app_id == app_id, VesselApp.manifest_version == payload.expected_version,
    ).values(manifest_json=manifest, manifest_version=payload.expected_version + 1,
             updated_by=user.user_id, updated_at=datetime.now(UTC)))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_MANIFEST_VERSION_CONFLICT"})
    _audit(session, app_id, user.user_id, "manifest.updated", {"manifest_version": payload.expected_version + 1})
    session.commit()
    session.refresh(app)
    return {"app": _app_payload(app)}


@router.patch("/v1/apps/{app_id}")
def update_app_settings(app_id: str, payload: AppSettingsUpdate,
                        user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True, require_manager=True)
    changes: dict[str, Any] = {"settings_version": payload.expected_settings_version + 1,
                               "updated_by": user.user_id, "updated_at": datetime.now(UTC)}
    if payload.name is not None:
        changes["name"] = payload.name
    if payload.description is not None:
        changes["description"] = payload.description
    result = session.execute(update(VesselApp).where(
        VesselApp.app_id == app.app_id, VesselApp.status == "active",
        VesselApp.settings_version == payload.expected_settings_version,
    ).values(**changes))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_SETTINGS_VERSION_CONFLICT"})
    _audit(session, app.app_id, user.user_id, "app.updated", {"settings_version": payload.expected_settings_version + 1})
    session.commit()
    session.refresh(app)
    return {"app": _app_payload(app)}


@router.post("/v1/apps/{app_id}/archive")
def archive_app(app_id: str, payload: SettingsVersionRequest,
                user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True, require_manager=True)
    now = datetime.now(UTC)
    result = session.execute(update(VesselApp).where(
        VesselApp.app_id == app.app_id, VesselApp.status == "active",
        VesselApp.settings_version == payload.expected_settings_version,
    ).values(status="archived", archived_by=user.user_id, archived_at=now,
             settings_version=payload.expected_settings_version + 1, updated_by=user.user_id, updated_at=now))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_SETTINGS_VERSION_CONFLICT"})
    _audit(session, app.app_id, user.user_id, "app.archived", {"settings_version": payload.expected_settings_version + 1})
    session.commit()
    session.refresh(app)
    return {"app": _app_payload(app)}


@router.post("/v1/apps/{app_id}/restore")
def restore_app(app_id: str, payload: SettingsVersionRequest,
                user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True, include_archived_for_manager=True, require_manager=True)
    now = datetime.now(UTC)
    result = session.execute(update(VesselApp).where(
        VesselApp.app_id == app.app_id, VesselApp.status == "archived",
        VesselApp.settings_version == payload.expected_settings_version,
    ).values(status="active", archived_by=None, archived_at=None,
             settings_version=payload.expected_settings_version + 1, updated_by=user.user_id, updated_at=now))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_SETTINGS_VERSION_CONFLICT"})
    _audit(session, app.app_id, user.user_id, "app.restored", {"settings_version": payload.expected_settings_version + 1})
    session.commit()
    session.refresh(app)
    return {"app": _app_payload(app)}


def _audit_payload(event: VesselAppAuditEvent) -> dict:
    return {
        "event_id": event.event_id,
        "release_id": event.release_id,
        "actor_user_id": event.actor_user_id,
        "action": event.action,
        "details": event.details_json,
        "created_at": event.created_at.isoformat(),
    }


def _audit_cursor(cursor: str | None) -> tuple[datetime, str] | None:
    if cursor is None:
        return None
    try:
        if len(cursor) > 1024:
            raise ValueError("Cursor too long")
        data = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
        if set(data) != {"created_at", "event_id"}:
            raise ValueError("Cursor shape invalid")
        created_at = datetime.fromisoformat(data["created_at"])
        if str(UUID(data["event_id"])) != data["event_id"]:
            raise ValueError("Cursor values invalid")
        return created_at, data["event_id"]
    except (ValueError, KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
        raise HTTPException(status_code=422, detail={"code": "APP_CURSOR_INVALID"}) from None


@router.get("/v1/apps/{app_id}/audit-events")
def list_app_audit_events(app_id: str, limit: int = Query(default=50, ge=1, le=200), cursor: str | None = None,
                          user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, include_archived_for_manager=True, require_manager=True)
    statement = select(VesselAppAuditEvent).where(VesselAppAuditEvent.app_id == app.app_id)
    anchor = _audit_cursor(cursor)
    if anchor is not None:
        created_at, event_id = anchor
        statement = statement.where(or_(
            VesselAppAuditEvent.created_at < created_at,
            and_(VesselAppAuditEvent.created_at == created_at, VesselAppAuditEvent.event_id < event_id),
        ))
    events = session.scalars(statement.order_by(
        VesselAppAuditEvent.created_at.desc(), VesselAppAuditEvent.event_id.desc(),
    ).limit(limit + 1)).all()
    more = len(events) > limit
    current_page = events[:limit]
    next_cursor = None
    if more:
        last = current_page[-1]
        payload = json.dumps({"created_at": last.created_at.isoformat(), "event_id": last.event_id}, separators=(",", ":"))
        next_cursor = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
    return {"events": [_audit_payload(event) for event in current_page], "next_cursor": next_cursor}


@router.post("/apps/{app_id}/releases/{version}/h5/session", include_in_schema=False)
def create_h5_session(app_id: str, version: int, request: Request, settings: Settings = Depends(get_settings),
                      keyring: KeyRing = Depends(get_keyring), session: Session = Depends(get_session)) -> Response:
    _require_release_origin(request, settings, app_id)
    origin = request.headers.get("origin")
    if origin is not None and origin != _release_origin(settings, app_id):
        raise HTTPException(status_code=403, detail={"code": "APP_H5_SESSION_ORIGIN_INVALID"})
    launch = verify_h5_launch_ticket(settings, request.cookies.get(H5_LAUNCH_COOKIE_NAME, ""), app_id, version)
    if launch is None:
        raise HTTPException(status_code=401, detail={"code": "APP_H5_LAUNCH_INVALID"})
    user_id, release_id = launch
    user = session.get(User, user_id)
    if user is None or user.status != "active":
        raise HTTPException(status_code=401, detail={"code": "APP_H5_LAUNCH_INVALID"})
    app = _app(session, user, app_id)
    release = session.scalar(select(VesselAppRelease).where(
        VesselAppRelease.release_id == release_id, VesselAppRelease.app_id == app.app_id, VesselAppRelease.version == version,
        VesselAppRelease.status == "published",
    ))
    if release is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"})
    response_payload = {
        "access_token": keyring.issue(
            subject=user.user_id,
            issuer=settings.issuer_url,
            audience="vessel-app-h5",
            scope="vessel:app-h5",
            lifetime_seconds=300,
            additional_claims={"app_id": app.app_id, "release_version": release.version},
        ),
        "token_type": "bearer",
        "expires_in": 300,
    }
    return Response(content=json.dumps(response_payload), media_type="application/json", headers={"Cache-Control": "no-store"})


@router.get("/v1/apps/{app_id}/releases/{release_id}/preview/{asset_path:path}", include_in_schema=False)
def preview_release_asset(app_id: str, release_id: str, request: Request, asset_path: str,
                          ticket: str | None = Query(default=None, max_length=2048), settings: Settings = Depends(get_settings),
                          session: Session = Depends(get_session)) -> Response:
    _require_release_origin(request, settings, app_id)
    credential = ticket or request.cookies.get(PREVIEW_COOKIE_NAME)
    if not credential or not verify_preview_ticket(settings, credential, app_id, release_id):
        raise HTTPException(status_code=401, detail={"code": "APP_PREVIEW_TICKET_INVALID"})
    if ticket:
        redirect = RedirectResponse(
            url=request.url.remove_query_params("ticket"), status_code=307,
            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"},
        )
        redirect.set_cookie(
            key=PREVIEW_COOKIE_NAME, value=credential, max_age=600,
            path=f"/v1/apps/{app_id}/releases/{release_id}/preview/",
            secure=settings.refresh_cookie_secure, httponly=True, samesite="strict",
        )
        return redirect
    release = session.scalar(select(VesselAppRelease).where(
        VesselAppRelease.release_id == release_id, VesselAppRelease.app_id == app_id,
    ))
    app = session.get(VesselApp, app_id)
    if release is None or app is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"})
    try:
        content = draft_asset(_release_storage(request), app, release, asset_path)
    except ReleaseError as error:
        raise _release_error(error) from error
    if content is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_ASSET_NOT_FOUND"})
    media_path = release.entry_file if not Path(asset_path).suffix else asset_path
    return Response(content, media_type=mimetypes.guess_type(media_path or "")[0] or "application/octet-stream", headers={
        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
    })


@router.get("/apps/{app_id}/releases/{version}/{asset_path:path}", include_in_schema=False)
def published_release_asset(app_id: str, version: int, asset_path: str, request: Request,
                            launch: str | None = Query(default=None, max_length=2048),
                            settings: Settings = Depends(get_settings), session: Session = Depends(get_session)) -> Response:
    _require_release_origin(request, settings, app_id)
    release = session.scalar(select(VesselAppRelease).where(
        VesselAppRelease.app_id == app_id, VesselAppRelease.version == version,
        VesselAppRelease.status == "published",
    ))
    if release is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"})
    if launch:
        ticket = verify_h5_launch_ticket(settings, launch, app_id, version)
        if asset_path != release.entry_file or ticket is None or ticket[1] != release.release_id:
            raise HTTPException(status_code=401, detail={"code": "APP_H5_LAUNCH_INVALID"})
        redirect = RedirectResponse(
            url=request.url.remove_query_params("launch"), status_code=307,
            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"},
        )
        redirect.set_cookie(
            key=H5_LAUNCH_COOKIE_NAME, value=launch, max_age=300,
            path=f"/apps/{app_id}/releases/{version}/h5/",
            secure=settings.refresh_cookie_secure, httponly=True, samesite="strict",
        )
        return redirect
    storage = _release_storage(request)
    fallback = False
    try:
        content = storage.get_published(release.object_prefix, asset_path)
        if content is None and not Path(asset_path).suffix and release.entry_file:
            content = storage.get_published(release.object_prefix, release.entry_file)
            fallback = content is not None
    except AppReleaseStorageError as error:
        raise HTTPException(status_code=503, detail={"code": error.code}) from None
    if content is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_ASSET_NOT_FOUND"})
    media_type = mimetypes.guess_type(release.entry_file if fallback else asset_path)[0] or "application/octet-stream"
    return Response(content, media_type=media_type, headers={
        "Cache-Control": "public, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
    })


@router.post("/v1/apps/{app_id}/releases", status_code=201)
def create_app_release(app_id: str, request: Request,
                       settings: Settings = Depends(get_settings), user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    _release_origin(settings, app_id)
    app = _app(session, user, app_id, write=True, require_manager=True)
    try:
        return {"release": _release_payload(create_draft(session, app, user), settings)}
    except ReleaseError as error:
        raise _release_error(error) from error


@router.get("/v1/apps/{app_id}/releases")
def list_app_releases(app_id: str, settings: Settings = Depends(get_settings), user: User = Depends(current_user),
                      session: Session = Depends(get_session)) -> dict:
    _release_origin(settings, app_id)
    app = _app(session, user, app_id)
    releases = session.scalars(select(VesselAppRelease).where(
        VesselAppRelease.app_id == app.app_id,
    ).order_by(VesselAppRelease.version.desc())).all()
    return {"releases": [_release_payload(release, settings) for release in releases]}


@router.post("/v1/apps/{app_id}/releases/{release_id}/upload")
async def upload_app_release(app_id: str, release_id: str, request: Request,
                             file: UploadFile = File(...), user: User = Depends(current_user),
                             settings: Settings = Depends(get_settings), session: Session = Depends(get_session)) -> dict:
    _release_origin(settings, app_id)
    app = _app(session, user, app_id, write=True, require_manager=True)
    archive = await file.read(MAX_ZIP_BYTES + 1)
    try:
        release = upload_draft(session, app, release_id, user, _release_storage(request), archive)
        payload = {"release": _release_payload(release, settings), "preview_url": None}
        if release.status == "draft" and release.entry_file:
            ticket = issue_preview_ticket(settings, app.app_id, release.release_id)
            preview_path = f"/v1/apps/{app.app_id}/releases/{release.release_id}/preview/{release.entry_file}"
            payload["preview_url"] = f"{_release_url(settings, app.app_id, preview_path)}?ticket={ticket}"
        return payload
    except ReleaseError as error:
        raise _release_error(error) from error


@router.post("/v1/apps/{app_id}/releases/{release_id}/publish")
def publish_app_release(app_id: str, release_id: str, request: Request,
                        settings: Settings = Depends(get_settings), user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    _release_origin(settings, app_id)
    app = _app(session, user, app_id, write=True, require_manager=True)
    try:
        release = publish_draft(session, app, release_id, user, _release_storage(request))
        return {"release": _release_payload(release, settings)}
    except ReleaseError as error:
        raise _release_error(error) from error


@router.post("/v1/apps/{app_id}/releases/{release_id}/rollback")
def rollback_app_release(app_id: str, release_id: str,
                         settings: Settings = Depends(get_settings), user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    _release_origin(settings, app_id)
    app = _app(session, user, app_id, write=True, require_manager=True)
    try:
        return {"release": _release_payload(rollback_release(session, app, release_id, user), settings)}
    except ReleaseError as error:
        raise _release_error(error) from error


@router.post("/v1/apps/{app_id}/releases/{release_id}/launch")
def launch_published_app_release(app_id: str, release_id: str, settings: Settings = Depends(get_settings),
                                 user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id)
    release = session.scalar(select(VesselAppRelease).where(
        VesselAppRelease.release_id == release_id, VesselAppRelease.app_id == app.app_id,
        VesselAppRelease.status == "published",
    ))
    if release is None:
        raise HTTPException(status_code=404, detail={"code": "APP_RELEASE_NOT_FOUND"})
    ticket = issue_h5_launch_ticket(settings, user.user_id, app.app_id, release)
    return {"launch_url": _release_url(settings, app.app_id, f"/apps/{app.app_id}/releases/{release.version}/{release.entry_file}?launch={ticket}")}


def _insert_record(session: Session, app: VesselApp, table_name: str, fields: dict, values: dict, user: User) -> VesselAppRecord:
    try:
        normalized = normalize_record(fields, values, creating=True)
    except ManifestError as error:
        raise _invalid(error) from error
    now = datetime.now(UTC)
    row = VesselAppRecord(record_id=str(uuid4()), app_id=app.app_id, table_name=table_name,
                          values_json=normalized, row_version=1, created_by=user.user_id, updated_by=user.user_id,
                          created_at=now, updated_at=now)
    session.add(row)
    return row


@router.post("/v1/apps/{app_id}/tables/{table_name}/records", status_code=201)
def create_record(app_id: str, table_name: str, payload: RecordCreate,
                  user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True)
    row = _insert_record(session, app, table_name, _fields(app, table_name), payload.values, user)
    session.commit()
    return {"record": _row_payload(row)}


@router.post("/v1/apps/{app_id}/tables/{table_name}/records/bulk", status_code=201)
def create_records_bulk(app_id: str, table_name: str, payload: BulkCreate,
                        user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True)
    fields = _fields(app, table_name)
    rows = [_insert_record(session, app, table_name, fields, item.values, user) for item in payload.records]
    session.commit()
    return {"records": [_row_payload(row) for row in rows]}


def _field_expression(field: str, fields: dict):
    if field == "id":
        return VesselAppRecord.record_id
    if field in {"created_at", "updated_at", "row_version"}:
        return getattr(VesselAppRecord, field)
    if field not in fields:
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
    expr = VesselAppRecord.values_json[field]
    kind = fields[field]["type"]
    if kind == "integer":
        return expr.as_integer()
    if kind == "numeric":
        return cast(expr.as_string(), Numeric)
    if kind == "boolean":
        return expr.as_boolean()
    if kind == "json":
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
    return expr.as_string()


def _query_predicate(raw: dict, fields: dict, *, leaf: bool = False):
    if not isinstance(raw, dict):
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
    if "and" in raw:
        conditions = raw["and"]
        if leaf or set(raw) != {"and"} or not isinstance(conditions, list) or not 1 <= len(conditions) <= 10:
            raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
        return and_(*(_query_predicate(item, fields, leaf=True) for item in conditions))
    if set(raw) != {"field", "op", "value"} or not isinstance(raw["field"], str) or raw["field"] not in fields:
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
    field, op, value = raw["field"], raw["op"], raw["value"]
    expr = _field_expression(field, fields)
    if op == "is_null":
        if not isinstance(value, bool):
            raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
        return expr.is_(None) if value else expr.is_not(None)
    if not isinstance(op, str) or op not in {"eq", "ne", "lt", "lte", "gt", "gte", "in"}:
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
    try:
        if op == "in":
            if not isinstance(value, list) or not 1 <= len(value) <= 50:
                raise ManifestError("APP_QUERY_INVALID")
            values = [_query_value(fields[field], item) for item in value]
            return expr.in_(values)
        value = _query_value(fields[field], value)
    except ManifestError as error:
        raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"}) from error
    return {"eq": lambda: expr == value, "ne": lambda: expr != value,
            "lt": lambda: expr < value, "lte": lambda: expr <= value,
            "gt": lambda: expr > value, "gte": lambda: expr >= value}[op]()


def _query_value(definition: dict, value: Any) -> Any:
    normalized = normalize_value(definition, value)
    if normalized is not None and definition["type"] == "numeric":
        return Decimal(normalized)
    return normalized


def _cursor_anchor(cursor: str | None, signature: str, fields: dict, sort_fields: list[str]) -> tuple[list[Any], str] | None:
    if cursor is None:
        return None
    try:
        if len(cursor) > 4096:
            raise ValueError("Cursor too long")
        data = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
        if (data["signature"] != signature or not isinstance(data["id"], str)
                or len(data["id"]) != 36 or not isinstance(data["values"], list)
                or len(data["values"]) != len(sort_fields)):
            raise ValueError("Cursor shape invalid")
        values = []
        for field, value in zip(sort_fields, data["values"]):
            if field in {"created_at", "updated_at"}:
                if not isinstance(value, str):
                    raise ValueError("Cursor date invalid")
                value = datetime.fromisoformat(value)
            elif field == "row_version":
                if type(value) is not int:
                    raise ValueError("Cursor version invalid")
            elif field == "id":
                if not isinstance(value, str):
                    raise ValueError("Cursor id invalid")
            elif value is not None:
                value = normalize_value(fields[field], value)
                if fields[field]["type"] == "numeric":
                    value = Decimal(value)
            values.append(value)
        return values, data["id"]
    except (ValueError, KeyError, TypeError, UnicodeDecodeError, ManifestError):
        pass
    raise HTTPException(status_code=422, detail={"code": "APP_CURSOR_INVALID"})


def _seek_after(sort_terms: list[tuple[Any, str]], values: list[Any], record_id: str):
    earlier_equal = []
    later = []
    for (expr, direction), value in zip(sort_terms, values):
        if value is not None:
            greater = expr > value if direction == "asc" else expr < value
            later.append(and_(*earlier_equal, or_(greater, expr.is_(None))))
            earlier_equal.append(expr == value)
        else:
            earlier_equal.append(expr.is_(None))
    later.append(and_(*earlier_equal, VesselAppRecord.record_id > record_id))
    return or_(*later)


def _sort_value(row: VesselAppRecord, field: str):
    if field == "id":
        return row.record_id
    if field in {"created_at", "updated_at"}:
        return getattr(row, field).isoformat()
    if field == "row_version":
        return row.row_version
    return row.values_json.get(field)


def _text_search_predicate(search: str, fields: dict):
    escaped = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    terms = [
        _field_expression(name, fields).ilike(f"%{escaped}%", escape="\\")
        for name, definition in fields.items()
        if definition["type"] == "text"
    ]
    return or_(*terms) if terms else False


def _records_page(session: Session, app: VesselApp, table_name: str, query: RecordQuery) -> dict:
    fields = _fields(app, table_name)
    signature = hashlib.sha256(json.dumps([app.app_id, table_name, query.filter, query.search, query.sort], sort_keys=True).encode()).hexdigest()
    statement = select(VesselAppRecord).where(
        VesselAppRecord.app_id == app.app_id, VesselAppRecord.table_name == table_name,
        VesselAppRecord.deleted_at.is_(None),
    )
    if query.filter is not None:
        statement = statement.where(_query_predicate(query.filter, fields))
    if query.search is not None:
        statement = statement.where(_text_search_predicate(query.search, fields))
    sort = query.sort or [{"field": "created_at", "direction": "asc"}]
    sort_terms = []
    for item in sort:
        if not isinstance(item, dict) or set(item) != {"field", "direction"} or not isinstance(item["field"], str) or item["direction"] not in {"asc", "desc"}:
            raise HTTPException(status_code=422, detail={"code": "APP_QUERY_INVALID"})
        expr = _field_expression(item["field"], fields)
        sort_terms.append((expr, item["direction"]))
        statement = statement.order_by((expr.desc() if item["direction"] == "desc" else expr.asc()).nulls_last())
    anchor = _cursor_anchor(query.cursor, signature, fields, [item["field"] for item in sort])
    if anchor is not None:
        statement = statement.where(_seek_after(sort_terms, *anchor))
    statement = statement.order_by(VesselAppRecord.record_id).limit(query.limit + 1)
    rows = session.scalars(statement).all()
    more = len(rows) > query.limit
    next_cursor = None
    if more:
        last = rows[query.limit - 1]
        payload = json.dumps({"signature": signature, "values": [_sort_value(last, item["field"]) for item in sort],
                              "id": last.record_id}, separators=(",", ":"))
        next_cursor = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
    return {"records": [_row_payload(row) for row in rows[:query.limit]], "next_cursor": next_cursor}


@router.get("/v1/apps/{app_id}/tables/{table_name}/records")
def list_records(app_id: str, table_name: str, limit: int = Query(default=50, ge=1, le=200), cursor: str | None = None,
                 user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    return _records_page(session, _app(session, user, app_id), table_name, RecordQuery(limit=limit, cursor=cursor))


@router.post("/v1/apps/{app_id}/tables/{table_name}/records/query")
def query_records(app_id: str, table_name: str, payload: RecordQuery,
                  user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    return _records_page(session, _app(session, user, app_id), table_name, payload)


@router.post("/v1/apps/{app_id}/tables/{table_name}/records/bulk-delete")
def bulk_delete_records(app_id: str, table_name: str, payload: BulkDeleteRequest,
                        user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True)
    _fields(app, table_name)
    if len({record.id for record in payload.records}) != len(payload.records):
        raise HTTPException(status_code=422, detail={"code": "APP_BULK_DELETE_INVALID"})
    expected_versions = {record.id: record.expected_row_version for record in payload.records}
    rows = session.scalars(select(VesselAppRecord).where(
        VesselAppRecord.record_id.in_(expected_versions), VesselAppRecord.app_id == app.app_id,
        VesselAppRecord.table_name == table_name, VesselAppRecord.deleted_at.is_(None),
    ).with_for_update()).all()
    if (len(rows) != len(expected_versions)
            or any(row.row_version != expected_versions[row.record_id] for row in rows)):
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_RECORD_VERSION_CONFLICT"})
    now = datetime.now(UTC)
    result = session.execute(update(VesselAppRecord).where(
        VesselAppRecord.record_id.in_(expected_versions), VesselAppRecord.app_id == app.app_id,
        VesselAppRecord.table_name == table_name, VesselAppRecord.deleted_at.is_(None),
    ).values(deleted_at=now, row_version=VesselAppRecord.row_version + 1,
             updated_by=user.user_id, updated_at=now))
    if result.rowcount != len(expected_versions):
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_RECORD_VERSION_CONFLICT"})
    _audit(session, app.app_id, user.user_id, "records.bulk_deleted", {"deleted_count": len(expected_versions)})
    session.commit()
    return {"deleted_count": len(expected_versions)}


@router.get("/v1/apps/{app_id}/tables/{table_name}/records/{record_id}")
def get_record(app_id: str, table_name: str, record_id: str,
               user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id)
    _fields(app, table_name)
    return {"record": _row_payload(_row(session, app, table_name, record_id))}


@router.patch("/v1/apps/{app_id}/tables/{table_name}/records/{record_id}")
def update_record(app_id: str, table_name: str, record_id: str, payload: RecordUpdate,
                  user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True)
    fields = _fields(app, table_name)
    row = _row(session, app, table_name, record_id)
    try:
        changes = normalize_record(fields, payload.values, creating=False)
    except ManifestError as error:
        raise _invalid(error) from error
    values = {**row.values_json, **changes}
    result = session.execute(update(VesselAppRecord).where(
        VesselAppRecord.record_id == record_id, VesselAppRecord.app_id == app_id,
        VesselAppRecord.table_name == table_name, VesselAppRecord.deleted_at.is_(None),
        VesselAppRecord.row_version == payload.expected_row_version,
    ).values(values_json=values, row_version=payload.expected_row_version + 1,
             updated_by=user.user_id, updated_at=datetime.now(UTC)))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_RECORD_VERSION_CONFLICT"})
    session.commit()
    session.refresh(row)
    return {"record": _row_payload(row)}


@router.delete("/v1/apps/{app_id}/tables/{table_name}/records/{record_id}", status_code=204)
def delete_record(app_id: str, table_name: str, record_id: str, payload: VersionRequest,
                  user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> Response:
    app = _app(session, user, app_id, write=True)
    _fields(app, table_name)
    _row(session, app, table_name, record_id)
    now = datetime.now(UTC)
    result = session.execute(update(VesselAppRecord).where(
        VesselAppRecord.record_id == record_id, VesselAppRecord.app_id == app_id,
        VesselAppRecord.table_name == table_name, VesselAppRecord.deleted_at.is_(None),
        VesselAppRecord.row_version == payload.expected_row_version,
    ).values(deleted_at=now, row_version=payload.expected_row_version + 1,
             updated_by=user.user_id, updated_at=now))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_RECORD_VERSION_CONFLICT"})
    session.commit()
    return Response(status_code=204)


@router.post("/v1/apps/{app_id}/tables/{table_name}/records/{record_id}/restore")
def restore_record(app_id: str, table_name: str, record_id: str, payload: VersionRequest,
                   user: User = Depends(current_app_user), session: Session = Depends(get_session)) -> dict:
    app = _app(session, user, app_id, write=True)
    _fields(app, table_name)
    row = _row(session, app, table_name, record_id, deleted=True)
    result = session.execute(update(VesselAppRecord).where(
        VesselAppRecord.record_id == record_id, VesselAppRecord.app_id == app_id,
        VesselAppRecord.table_name == table_name, VesselAppRecord.deleted_at.is_not(None),
        VesselAppRecord.row_version == payload.expected_row_version,
    ).values(deleted_at=None, row_version=payload.expected_row_version + 1,
             updated_by=user.user_id, updated_at=datetime.now(UTC)))
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "APP_RECORD_VERSION_CONFLICT"})
    session.commit()
    session.refresh(row)
    return {"record": _row_payload(row)}
