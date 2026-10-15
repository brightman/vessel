"""Recoverable file jobs. Network work never holds the space transaction lock."""

import hashlib
import json
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import HTTPException
from sqlalchemy import func, or_, select

from vessel_service.models import Space, User

from .models import (
    DriveAuditEvent,
    DriveFile,
    DriveFileVersion,
    DriveItem,
    DriveOutbox,
    DrivePurgeJob,
    DriveTrashBatch,
    DriveUpload,
)
from .permissions import access_item, fail, space_role, utc
from .storage import StorageError
from .uploads import enqueue, quota, release_reservation, row_dict


def upload_snapshot(upload):
    snapshot = row_dict(upload)
    if upload.verified_json:
        snapshot.update(source_version_id=upload.verified_json.get("source_version_id"))
    return snapshot


def _terminal(session, upload, code, status="failed"):
    upload.status = status
    upload.failure_code = code
    upload.updated_at = datetime.now(UTC)
    release_reservation(session, upload)
    enqueue(
        session,
        "cleanup:" + upload.upload_id,
        "cleanup_upload",
        {"upload_id": upload.upload_id},
    )
    enqueue(
        session,
        "cleanup-late:" + upload.upload_id,
        "cleanup_upload",
        {"upload_id": upload.upload_id},
    )
    late = session.scalar(
        select(DriveOutbox).where(
            DriveOutbox.business_key == "cleanup-late:" + upload.upload_id
        )
    )
    if late:
        late.available_at = utc(upload.expires_at) + timedelta(hours=1)


def owns_lease(session, lease):
    if lease is None:
        return True
    task_id, attempt = lease
    task = session.scalar(
        select(DriveOutbox)
        .where(DriveOutbox.outbox_id == task_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    return task is not None and task.status == "running" and task.attempts == attempt


def lock_upload_space(session, upload):
    session.scalar(
        select(Space).where(Space.space_id == upload.space_id).with_for_update()
    )
    session.refresh(upload)


def process_upload(sessions, storage, upload_id, lease=None):
    with sessions() as session:
        upload = session.get(DriveUpload, upload_id)
        if upload is None or upload.status not in ("verifying", "publishing"):
            return
        if not owns_lease(session, lease):
            return
        snapshot = upload_snapshot(upload)
        verified = upload.verified_json
    if not verified:
        verified = storage.verify(snapshot, snapshot["complete_parts"])
        with sessions() as session:
            upload = session.get(DriveUpload, upload_id)
            lock_upload_space(session, upload)
            if not owns_lease(session, lease):
                return
            if upload.status not in ("verifying", "publishing"):
                return
            upload.verified_json = verified
            upload.status = "publishing"
            session.commit()
    published = storage.publish(snapshot, verified)
    # Persist the sealed object before DB publication, so cancellation/conflict can clean it.
    with sessions() as session:
        upload = session.get(DriveUpload, upload_id)
        lock_upload_space(session, upload)
        identity = hashlib.sha256(
            json.dumps(published, sort_keys=True).encode()
        ).hexdigest()
        enqueue(
            session,
            "object:" + identity,
            "cleanup_object",
            {"upload_id": upload_id, "object": published},
        )
        if not owns_lease(session, lease):
            session.commit()
            return
        upload.verified_bucket = published["bucket"]
        upload.verified_key = published["object_key"]
        upload.verified_version_id = published["oss_version_id"]
        session.commit()
    with sessions() as session:
        upload = session.get(DriveUpload, upload_id)
        actor = session.get(User, upload.actor_user_id)
        try:
            space_role(session, actor, upload.space_id, lock=True)
            session.refresh(upload)
            if not owns_lease(session, lease):
                return
            if upload.status not in ("verifying", "publishing"):
                enqueue(
                    session,
                    "cleanup-published:" + upload_id,
                    "cleanup_upload",
                    {"upload_id": upload_id},
                )
                session.commit()
                return
            if utc(upload.expires_at) <= datetime.now(UTC):
                fail("UPLOAD_EXPIRED", 409)
            from .metadata import normalize_name

            if upload.mode == "create":
                parent, _ = access_item(
                    session, actor, upload.parent_id, "create_children", True
                )
                name, normalized = normalize_name(upload.name)
                existing = session.scalar(
                    select(DriveItem).where(
                        DriveItem.space_id == upload.space_id,
                        DriveItem.parent_id == parent.item_id,
                        DriveItem.status == "active",
                        DriveItem.normalized_name == normalized,
                    )
                )
                if existing:
                    fail("ITEM_NAME_CONFLICT")
                # Root is depth 0, max folder/file depth is 32.
                from .permissions import ancestors

                if len(ancestors(session, parent)) > 32:
                    fail("FILE_HIERARCHY_INVALID", 422)
                item = DriveItem(
                    item_id=str(uuid4()),
                    space_id=upload.space_id,
                    kind="file",
                    parent_id=parent.item_id,
                    name=name,
                    normalized_name=normalized,
                    metadata_version=1,
                    status="active",
                    created_by_user_id=actor.user_id,
                    updated_by_user_id=actor.user_id,
                )
                session.add(item)
                session.flush()
                file = DriveFile(item_id=item.item_id, current_version_id=None)
                session.add(file)
                session.flush()
                ordinal = 1
            else:
                item, _ = access_item(
                    session, actor, upload.target_item_id, "write", True
                )
                file = session.get(DriveFile, item.item_id)
                if file.current_version_id != upload.expected_current_version_id:
                    fail("FILE_VERSION_CONFLICT")
                if item.metadata_version != upload.expected_metadata_version:
                    fail("FILE_METADATA_VERSION_CONFLICT")
                item.metadata_version += 1
                item.updated_by_user_id = actor.user_id
                item.updated_at = datetime.now(UTC)
                ordinal = (
                    session.scalar(
                        select(func.max(DriveFileVersion.ordinal)).where(
                            DriveFileVersion.item_id == item.item_id
                        )
                    )
                    + 1
                )
            version = DriveFileVersion(
                version_id=str(uuid4()),
                item_id=item.item_id,
                ordinal=ordinal,
                bucket=published["bucket"],
                object_key=published["object_key"],
                oss_version_id=published["oss_version_id"],
                size_bytes=verified["size_bytes"],
                sha256=verified["sha256"],
                crc64=verified.get("crc64"),
                content_type=upload.content_type,
                created_by_user_id=actor.user_id,
                source="upload",
            )
            session.add(version)
            file.current_version_id = version.version_id
            usage = quota(session, upload.space_id)
            release_reservation(session, upload)
            usage.committed_bytes += version.size_bytes
            upload.target_item_id = item.item_id
            upload.version_id = version.version_id
            upload.status = "ready"
            upload.updated_at = datetime.now(UTC)
            session.add(
                DriveAuditEvent(
                    event_id=str(uuid4()),
                    space_id=item.space_id,
                    item_id=item.item_id,
                    actor_user_id=actor.user_id,
                    operation="file.version.publish",
                    after_version=item.metadata_version,
                )
            )
            enqueue(
                session,
                "cleanup:" + upload_id,
                "cleanup_upload",
                {"upload_id": upload_id},
            )
            enqueue(
                session,
                "cleanup-late:" + upload_id,
                "cleanup_upload",
                {"upload_id": upload_id},
            )
            late = session.scalar(
                select(DriveOutbox).where(
                    DriveOutbox.business_key == "cleanup-late:" + upload_id
                )
            )
            if late:
                late.available_at = utc(upload.expires_at) + timedelta(hours=1)
            session.commit()
        except HTTPException as exc:
            session.rollback()
            upload = session.get(DriveUpload, upload_id)
            # Match lock protocol even when revoked actor cannot lock through authorization.

            session.scalar(
                select(Space).where(Space.space_id == upload.space_id).with_for_update()
            )
            session.refresh(upload)
            if not owns_lease(session, lease):
                return
            if upload.status in ("verifying", "publishing"):
                code = (
                    exc.detail.get("code")
                    if isinstance(exc.detail, dict)
                    else "FILE_PERMISSION_REVOKED"
                )
                status = (
                    "conflict"
                    if code
                    in (
                        "FILE_VERSION_CONFLICT",
                        "FILE_METADATA_VERSION_CONFLICT",
                        "ITEM_NAME_CONFLICT",
                    )
                    else "expired"
                    if code == "UPLOAD_EXPIRED"
                    else "failed"
                )
                _terminal(
                    session,
                    upload,
                    "FILE_PERMISSION_REVOKED"
                    if exc.status_code in (403, 404)
                    else code,
                    status,
                )
            session.commit()


def process_cleanup_object(sessions, storage, upload_id, version):
    with sessions() as session:
        upload = session.get(DriveUpload, upload_id)
        if upload is not None and upload.status in ("verifying", "publishing"):
            raise StorageError("FILE_JOB_IN_PROGRESS")
        refs = session.scalar(
            select(func.count())
            .select_from(DriveFileVersion)
            .where(
                DriveFileVersion.bucket == version["bucket"],
                DriveFileVersion.object_key == version["object_key"],
                DriveFileVersion.oss_version_id == version["oss_version_id"],
            )
        )
    if not refs:
        storage.delete_version(version)


def process_cleanup(sessions, storage, upload_id):
    with sessions() as session:
        upload = session.get(DriveUpload, upload_id)
        if upload is None:
            return
        snapshot = upload_snapshot(upload)
        status = upload.status
        published = {
            "bucket": upload.verified_bucket,
            "object_key": upload.verified_key,
            "oss_version_id": upload.verified_version_id,
        }
    if status in ("verifying", "publishing"):
        raise StorageError("FILE_JOB_IN_PROGRESS")
    storage.cleanup_upload(snapshot)
    candidates = [published] if published["object_key"] else []
    # Recover copies whose response was lost before their immutable identity could be stored.
    discover = getattr(storage, "publication_versions", None)
    if discover:
        candidates.extend(discover(snapshot))
    seen = set()
    for version in candidates:
        identity = (version["bucket"], version["object_key"], version["oss_version_id"])
        if identity in seen:
            continue
        seen.add(identity)
        process_cleanup_object(sessions, storage, upload_id, version)


def process_purge(sessions, storage, purge_id, lease=None):
    with sessions() as session:
        job = session.get(DrivePurgeJob, purge_id)
        if job is None or job.status == "succeeded":
            return
        if not owns_lease(session, lease):
            return
        batch = session.get(DriveTrashBatch, job.batch_id)
        ids = list(
            session.scalars(
                select(DriveItem.item_id).where(
                    DriveItem.trash_batch_id == batch.batch_id
                )
            )
        )
        versions = list(
            session.scalars(
                select(DriveFileVersion).where(DriveFileVersion.item_id.in_(ids))
            )
        )
        objects = {
            (v.bucket, v.object_key, v.oss_version_id): row_dict(v) for v in versions
        }
        # No cross-file/space object reuse, restore creates references only within same file.
        for identity in list(objects):
            outside = session.scalar(
                select(func.count())
                .select_from(DriveFileVersion)
                .where(
                    DriveFileVersion.bucket == identity[0],
                    DriveFileVersion.object_key == identity[1],
                    DriveFileVersion.oss_version_id == identity[2],
                    DriveFileVersion.item_id.not_in(ids),
                )
            )
            if outside:
                del objects[identity]
        job.status = "running"
        job.failure_code = None
        session.commit()
    for version in objects.values():
        storage.delete_version(version)
    with sessions() as session:
        job = session.get(DrivePurgeJob, purge_id)

        session.scalar(
            select(Space).where(Space.space_id == job.space_id).with_for_update()
        )
        session.refresh(job)
        if not owns_lease(session, lease):
            return
        if job.status == "succeeded":
            return
        batch = session.get(DriveTrashBatch, job.batch_id)
        for version in session.scalars(
            select(DriveFileVersion).where(DriveFileVersion.item_id.in_(ids))
        ).all():
            session.delete(version)
        for file in session.scalars(
            select(DriveFile).where(DriveFile.item_id.in_(ids))
        ).all():
            file.current_version_id = None
        for item in session.scalars(
            select(DriveItem).where(DriveItem.item_id.in_(ids))
        ).all():
            item.status = "purged"
        usage = quota(session, job.space_id)
        usage.committed_bytes = max(
            0, usage.committed_bytes - sum(v["size_bytes"] for v in objects.values())
        )
        batch.status = "purged"
        batch.batch_version += 1
        job.status = "succeeded"
        job.updated_at = datetime.now(UTC)
        session.commit()


def process_jobs(sessions, storage, limit=20):
    if storage is None:
        return 0
    processed = 0
    for _ in range(limit):
        now = datetime.now(UTC)
        with sessions() as session:
            task = session.scalar(
                select(DriveOutbox)
                .where(
                    DriveOutbox.available_at <= now,
                    or_(
                        DriveOutbox.status.in_(("pending", "failed")),
                        (DriveOutbox.status == "running")
                        & (DriveOutbox.lease_until < now),
                    ),
                )
                .order_by(DriveOutbox.created_at)
                .with_for_update(skip_locked=True)
            )
            if task is None:
                break
            task.status = "running"
            task.lease_until = now + timedelta(minutes=30)
            task.attempts += 1
            task.updated_at = now
            task_id = task.outbox_id
            kind = task.kind
            payload = task.payload
            attempts = task.attempts
            session.commit()
        try:
            if kind == "upload":
                process_upload(
                    sessions, storage, payload["upload_id"], (task_id, attempts)
                )
            elif kind == "cleanup_upload":
                process_cleanup(sessions, storage, payload["upload_id"])
            elif kind == "cleanup_object":
                process_cleanup_object(
                    sessions, storage, payload["upload_id"], payload["object"]
                )
            elif kind == "purge":
                process_purge(
                    sessions, storage, payload["purge_id"], (task_id, attempts)
                )
            else:
                raise RuntimeError("Unknown file task")
        except Exception as exc:
            code = (
                exc.code
                if isinstance(exc, StorageError)
                else "FILE_STORAGE_UNAVAILABLE"
            )
            with sessions() as session:
                # All state-changing error paths follow Space -> outbox lock ordering.
                if kind == "upload":
                    upload = session.get(DriveUpload, payload["upload_id"])
                    lock_upload_space(session, upload)
                elif kind == "purge":
                    job = session.get(DrivePurgeJob, payload["purge_id"])
                    session.scalar(
                        select(Space)
                        .where(Space.space_id == job.space_id)
                        .with_for_update()
                    )
                if not owns_lease(session, (task_id, attempts)):
                    continue
                task = session.get(DriveOutbox, task_id)
                task.status = "failed"
                task.failure_code = code
                task.lease_until = None
                task.available_at = datetime.now(UTC) + timedelta(
                    seconds=min(300, 2 ** min(attempts, 8))
                )
                if kind == "upload" and code == "UPLOAD_CHECKSUM_MISMATCH":
                    upload = session.get(DriveUpload, payload["upload_id"])

                    session.scalar(
                        select(Space)
                        .where(Space.space_id == upload.space_id)
                        .with_for_update()
                    )
                    session.refresh(upload)
                    if upload.status in ("verifying", "publishing"):
                        _terminal(session, upload, code)
                    task.status = "done"
                if kind == "purge":
                    job = session.get(DrivePurgeJob, payload["purge_id"])
                    job.status = "failed"
                    job.failure_code = code
                session.commit()
        else:
            with sessions() as session:
                if not owns_lease(session, (task_id, attempts)):
                    continue
                task = session.get(DriveOutbox, task_id)
                task.status = "done"
                task.lease_until = None
                task.failure_code = None
                task.updated_at = datetime.now(UTC)
                session.commit()
        processed += 1
    return processed


def expire_uploads(sessions):
    now = datetime.now(UTC)
    with sessions() as session:
        ids = list(
            session.scalars(
                select(DriveUpload.upload_id).where(
                    DriveUpload.status.in_(
                        ("pending", "uploading", "verifying", "publishing")
                    ),
                    DriveUpload.expires_at <= now,
                )
            )
        )
    for upload_id in ids:
        with sessions() as session:
            upload = session.get(DriveUpload, upload_id)

            session.scalar(
                select(Space).where(Space.space_id == upload.space_id).with_for_update()
            )
            session.refresh(upload)
            if (
                upload.status in ("pending", "uploading", "verifying", "publishing")
                and utc(upload.expires_at) <= now
            ):
                _terminal(session, upload, "UPLOAD_EXPIRED", "expired")
                session.commit()
    return len(ids)
