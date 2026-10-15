"""State transitions for immutable Vessel App releases."""

from __future__ import annotations

import tempfile
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from vessel_service.apps.h5_release import H5PackageValidator, cleanup_h5_package
from vessel_service.apps.release_storage import AppReleaseStorage, AppReleaseStorageError
from vessel_service.models import User, VesselApp, VesselAppAuditEvent, VesselAppRelease


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
