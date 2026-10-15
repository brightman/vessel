"""State transitions for immutable Vessel App releases."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import tempfile
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from vessel_service.apps.h5_release import H5PackageValidator, cleanup_h5_package
from vessel_service.apps.release_storage import AppReleaseStorage, AppReleaseStorageError
from vessel_service.models import User, VesselApp, VesselAppAuditEvent, VesselAppRelease
from vessel_service.settings import Settings


class ReleaseError(RuntimeError):
    def __init__(self, code: str, *, status_code: int = 409):
        self.code = code
        self.status_code = status_code
        super().__init__(code)


def release_payload(release: VesselAppRelease) -> dict:
    return {
        "release_id": release.release_id,
        "app_id": release.app_id,
        "version": release.version,
        "manifest_version": release.manifest_version,
        "status": release.status,
        "entry_file": release.entry_file,
        "file_count": release.file_count,
        "total_size_bytes": release.total_size_bytes,
        "checksum_sha256": release.checksum_sha256,
        "validation_error_code": release.validation_error_code,
        "is_current": release.is_current,
        "created_by": release.created_by,
        "created_at": release.created_at.isoformat(),
        "published_by": release.published_by,
        "published_at": release.published_at.isoformat() if release.published_at else None,
    }


def _audit(session: Session, app_id: str, actor_user_id: str, action: str, details: dict, *, release_id: str | None = None) -> None:
    session.add(VesselAppAuditEvent(
        event_id=str(uuid4()), app_id=app_id, release_id=release_id, actor_user_id=actor_user_id,
        action=action, details_json=details, created_at=datetime.now(UTC),
    ))


def create_draft(session: Session, app: VesselApp, actor: User) -> VesselAppRelease:
    session.scalar(select(VesselApp.app_id).where(VesselApp.app_id == app.app_id).with_for_update())
    latest_version = session.scalar(select(VesselAppRelease.version).where(
        VesselAppRelease.app_id == app.app_id,
    ).order_by(VesselAppRelease.version.desc()).limit(1).with_for_update())
    next_version = (latest_version or 0) + 1
    release_id = str(uuid4())
    release = VesselAppRelease(
        release_id=release_id,
        app_id=app.app_id,
        version=next_version,
        manifest_version=app.manifest_version,
        status="draft",
        object_prefix=f"vessel-apps/{app.app_id}/releases/{next_version}/",
        draft_object_key=f"vessel-apps/{app.app_id}/drafts/{release_id}.zip",
        created_by=actor.user_id,
        created_at=datetime.now(UTC),
        is_current=False,
    )
    session.add(release)
    # PostgreSQL can insert the audit row before the pending Release row when
    # both are flushed at commit time, despite the audit FK pointing at it.
    # Persist the Release first while retaining a single transaction.
    session.flush()
    _audit(session, app.app_id, actor.user_id, "release.created", {"version": next_version}, release_id=release_id)
    session.commit()
    return release


def _release(session: Session, app_id: str, release_id: str) -> VesselAppRelease:
    release = session.scalar(select(VesselAppRelease).where(
        VesselAppRelease.release_id == release_id, VesselAppRelease.app_id == app_id,
    ))
    if release is None:
        raise ReleaseError("APP_RELEASE_NOT_FOUND", status_code=404)
    return release


def _validate_archive(archive: bytes, app: VesselApp):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as temporary:
        temporary.write(archive)
        archive_path = Path(temporary.name)
    try:
        return H5PackageValidator().validate(archive_path, app.app_id, app.manifest_json)
    finally:
        archive_path.unlink(missing_ok=True)


def upload_draft(session: Session, app: VesselApp, release_id: str, actor: User,
                 storage: AppReleaseStorage, archive: bytes) -> VesselAppRelease:
    release = _release(session, app.app_id, release_id)
    if release.status not in {"draft", "validation_failed"}:
        raise ReleaseError("APP_RELEASE_NOT_UPLOADABLE")
    package = None
    try:
        package = _validate_archive(archive, app)
        storage.put_draft(release.draft_object_key, archive)
    except ValueError as error:
        code = str(error)
        release.status = "validation_failed"
        release.validation_error_code = code
        release.entry_file = None
        release.file_count = None
        release.total_size_bytes = None
        release.checksum_sha256 = None
        _audit(session, app.app_id, actor.user_id, "release.validation_failed", {"code": code}, release_id=release.release_id)
        session.commit()
        return release
    except AppReleaseStorageError as error:
        raise ReleaseError(error.code, status_code=503) from None
    except ValueError:
        raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE") from None
    finally:
        cleanup_h5_package(package)
    release.status = "draft"
    release.entry_file = package.entry_file
    release.file_count = package.file_count
    release.total_size_bytes = package.total_size_bytes
    release.checksum_sha256 = package.checksum_sha256
    release.validation_error_code = None
    _audit(session, app.app_id, actor.user_id, "release.uploaded", {
        "version": release.version, "file_count": package.file_count, "checksum_sha256": package.checksum_sha256,
    }, release_id=release.release_id)
    session.commit()
    return release


def publish_draft(session: Session, app: VesselApp, release_id: str, actor: User,
                  storage: AppReleaseStorage) -> VesselAppRelease:
    release = _release(session, app.app_id, release_id)
    if release.status != "draft" or not release.checksum_sha256 or release.manifest_version != app.manifest_version:
        raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE")
    package = None
    try:
        package = _validate_archive(storage.get_draft(release.draft_object_key), app)
        if package.checksum_sha256 != release.checksum_sha256:
            raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE")
        storage.publish_tree(release.object_prefix, package)
    except AppReleaseStorageError as error:
        raise ReleaseError(error.code, status_code=503) from None
    except ValueError:
        raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE") from None
    finally:
        cleanup_h5_package(package)
    now = datetime.now(UTC)
    session.execute(update(VesselAppRelease).where(
        VesselAppRelease.app_id == app.app_id, VesselAppRelease.is_current.is_(True),
    ).values(is_current=False))
    release.status = "published"
    release.is_current = True
    release.published_by = actor.user_id
    release.published_at = now
    _audit(session, app.app_id, actor.user_id, "release.published", {
        "version": release.version, "checksum_sha256": release.checksum_sha256,
    }, release_id=release.release_id)
    session.commit()
    try:
        storage.delete_draft(release.draft_object_key)
    except AppReleaseStorageError:
        pass
    return release


def rollback_release(session: Session, app: VesselApp, release_id: str, actor: User) -> VesselAppRelease:
    release = _release(session, app.app_id, release_id)
    if release.status != "published":
        raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE")
    session.execute(update(VesselAppRelease).where(
        VesselAppRelease.app_id == app.app_id, VesselAppRelease.is_current.is_(True),
    ).values(is_current=False))
    release.is_current = True
    _audit(session, app.app_id, actor.user_id, "release.rolled_back", {"version": release.version}, release_id=release.release_id)
    session.commit()
    return release


def _preview_secret(settings: Settings) -> bytes:
    return (settings.h5_preview_secret or f"{settings.issuer_url}|development-preview-ticket").encode()


def issue_preview_ticket(settings: Settings, app_id: str, release_id: str) -> str:
    payload = json.dumps({
        "app_id": app_id, "release_id": release_id,
        "expires_at": int(datetime.now(UTC).timestamp()) + 600,
    }, sort_keys=True, separators=(",", ":")).encode()
    encoded = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    signature = hmac.new(_preview_secret(settings), encoded.encode(), hashlib.sha256).digest()
    return encoded + "." + base64.urlsafe_b64encode(signature).decode().rstrip("=")


def verify_preview_ticket(settings: Settings, ticket: str, app_id: str, release_id: str) -> bool:
    try:
        encoded, supplied = ticket.split(".")
        if len(ticket) > 2048:
            return False
        expected = hmac.new(_preview_secret(settings), encoded.encode(), hashlib.sha256).digest()
        actual = base64.urlsafe_b64decode(supplied + "=" * (-len(supplied) % 4))
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        return (
            hmac.compare_digest(expected, actual)
            and set(payload) == {"app_id", "release_id", "expires_at"}
            and payload["app_id"] == app_id
            and payload["release_id"] == release_id
            and type(payload["expires_at"]) is int
            and payload["expires_at"] > int(datetime.now(UTC).timestamp())
        )
    except (ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
        return False


def issue_h5_launch_ticket(settings: Settings, user_id: str, app_id: str, release: VesselAppRelease) -> str:
    payload = json.dumps({
        "app_id": app_id,
        "release_id": release.release_id,
        "release_version": release.version,
        "user_id": user_id,
        "expires_at": int(datetime.now(UTC).timestamp()) + 300,
    }, sort_keys=True, separators=(",", ":")).encode()
    encoded = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    signature = hmac.new(_preview_secret(settings), encoded.encode(), hashlib.sha256).digest()
    return encoded + "." + base64.urlsafe_b64encode(signature).decode().rstrip("=")


def verify_h5_launch_ticket(settings: Settings, ticket: str, app_id: str, version: int) -> tuple[str, str] | None:
    try:
        encoded, supplied = ticket.split(".")
        if len(ticket) > 2048:
            return None
        expected = hmac.new(_preview_secret(settings), encoded.encode(), hashlib.sha256).digest()
        actual = base64.urlsafe_b64decode(supplied + "=" * (-len(supplied) % 4))
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        if not (
            hmac.compare_digest(expected, actual)
            and set(payload) == {"app_id", "release_id", "release_version", "user_id", "expires_at"}
            and payload["app_id"] == app_id
            and type(payload["release_version"]) is int
            and payload["release_version"] == version
            and isinstance(payload["release_id"], str)
            and isinstance(payload["user_id"], str)
            and bool(payload["user_id"])
            and type(payload["expires_at"]) is int
            and payload["expires_at"] > int(datetime.now(UTC).timestamp())
        ):
            return None
        return payload["user_id"], payload["release_id"]
    except (ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
        return None


def draft_asset(storage: AppReleaseStorage, app: VesselApp, release: VesselAppRelease, asset_path: str) -> bytes | None:
    if release.status != "draft" or not release.checksum_sha256:
        raise ReleaseError("APP_RELEASE_NOT_FOUND", status_code=404)
    path = PurePosixPath(asset_path)
    if not asset_path or path.is_absolute() or ".." in path.parts or any(part in {"", "."} for part in path.parts):
        return None
    package = None
    try:
        package = _validate_archive(storage.get_draft(release.draft_object_key), app)
        if package.checksum_sha256 != release.checksum_sha256:
            raise ReleaseError("APP_RELEASE_NOT_PUBLISHABLE")
        target = (package.root / path.as_posix()).resolve()
        if not target.is_relative_to(package.root.resolve()) or not target.is_file():
            if path.suffix or not release.entry_file:
                return None
            target = package.root / release.entry_file
        return target.read_bytes()
    except AppReleaseStorageError as error:
        raise ReleaseError(error.code, status_code=503) from None
    finally:
        cleanup_h5_package(package)
