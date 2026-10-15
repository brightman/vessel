"""Persistent upload intent and file-version operations (OSS work lives in jobs)."""

import math
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import func, select

from .models import (
    DriveAuditEvent,
    DriveFile,
    DriveFileVersion,
    DriveOutbox,
    DriveQuotaUsage,
    DriveUpload,
)
from .permissions import access_item, fail, space_role, utc


class UploadCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    mode: str = Field(pattern="^(create|new_version)$")
    size_bytes: int = Field(ge=0)
    sha256: str = Field(pattern="^[a-fA-F0-9]{64}$")
    content_type: str = Field(
        min_length=1, max_length=128, pattern=r"^[\w.+-]+/[\w.+-]+$"
    )
    parent_folder_id: str | None = None
    name: str | None = None
    file_id: str | None = None
    expected_current_version_id: str | None = None
    expected_metadata_version: int | None = Field(default=None, ge=1)

    @model_validator(mode="after")
    def mode_fields(self):
        if self.mode == "create":
            if (
                not self.parent_folder_id
                or not self.name
                or self.file_id
                or self.expected_current_version_id
                or self.expected_metadata_version is not None
            ):
                raise ValueError("create requires name and parent_folder_id only")
        elif (
            not self.file_id
            or not self.expected_current_version_id
            or self.expected_metadata_version is None
            or self.name is not None
            or self.parent_folder_id is not None
        ):
            raise ValueError("new_version requires file_id and expected versions only")
        self.sha256 = self.sha256.lower()
        return self


class PartReceipt(BaseModel):
    model_config = ConfigDict(extra="forbid")
    part_number: int = Field(ge=1, le=10000)
    etag: str = Field(min_length=1, max_length=256)


class CompleteUpload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    parts: list[PartReceipt] = Field(default_factory=list, max_length=10000)


class SignParts(BaseModel):
    model_config = ConfigDict(extra="forbid")
    part_numbers: list[int] = Field(min_length=1, max_length=20)


class RestoreVersion(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_current_version_id: str


class DownloadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version_id: str | None = None


def row_dict(row):
    return {column.name: getattr(row, column.name) for column in row.__table__.columns}


def upload_payload(upload):
    return {
        "upload_id": upload.upload_id,
        "space_id": upload.space_id,
        "mode": upload.mode,
        "file_id": upload.target_item_id
        if upload.status == "ready" or upload.mode == "new_version"
        else None,
        "status": upload.status,
        "size_bytes": upload.size_bytes,
        "sha256": upload.sha256,
        "content_type": upload.content_type,
        "transfer_mode": upload.transfer_mode,
        "part_size_bytes": upload.part_size_bytes,
        "part_count": upload.part_count,
        "expires_at": utc(upload.expires_at).isoformat(),
        "version_id": upload.version_id,
        "failure_code": upload.failure_code,
        "status_url": f"/v1/file-uploads/{upload.upload_id}",
    }


def version_payload(version):
    return {
        "version_id": version.version_id,
        "file_id": version.item_id,
        "ordinal": version.ordinal,
        "size_bytes": version.size_bytes,
        "sha256": version.sha256,
        "crc64": version.crc64,
        "content_type": version.content_type,
        "created_by_user_id": version.created_by_user_id,
        "created_at": utc(version.created_at).isoformat(),
        "source": version.source,
        "restored_from_version_id": version.restored_from_version_id,
    }


def quota(session, space_id, limit=10 * 1024**3):
    state = session.get(DriveQuotaUsage, space_id)
    if state is None:
        state = DriveQuotaUsage(
            space_id=space_id, committed_bytes=0, reserved_bytes=0, limit_bytes=limit
        )
        session.add(state)
        session.flush()
    return state


def authorize_upload(session, user, upload_id, write=True):
    upload = session.scalar(
        select(DriveUpload)
        .where(DriveUpload.upload_id == upload_id)
        .execution_options(populate_existing=True)
    )
    if upload is None:
        fail("FILE_UPLOAD_NOT_FOUND", 404)
    space, role = space_role(session, user, upload.space_id, lock=write)
    if upload.actor_user_id != user.user_id and role not in ("owner", "admin"):
        fail("FILE_UPLOAD_NOT_FOUND", 404)
    target = (
        upload.target_item_id
        if upload.mode == "new_version" or upload.status == "ready"
        else upload.parent_id
    )
    try:
        access_item(session, user, target, action="write", lock=write)
    except HTTPException as exc:
        if exc.status_code == 404:
            fail("FILE_UPLOAD_NOT_FOUND", 404)
        raise
    session.refresh(upload)
    return upload


def release_reservation(session, upload):
    state = quota(session, upload.space_id)
    state.reserved_bytes = max(0, state.reserved_bytes - upload.reserved_bytes)
    upload.reserved_bytes = 0


def enqueue(session, key, kind, payload):
    existing = session.scalar(
        select(DriveOutbox).where(DriveOutbox.business_key == key)
    )
    if existing is None:
        session.add(
            DriveOutbox(
                outbox_id=str(uuid4()),
                business_key=key,
                kind=kind,
                payload=payload,
                status="pending",
            )
        )


class UploadService:
    def __init__(self, session, user, storage, settings=None):
        self.session = session
        self.user = user
        self.storage = storage
        self.settings = settings

    def create(self, space_id, payload):
        from .metadata import normalize_name

        if self.storage is None:
            fail("FILE_STORAGE_UNAVAILABLE", 503)
        space_role(self.session, self.user, space_id, lock=True)
        if payload.mode == "create":
            parent, caps = access_item(
                self.session,
                self.user,
                payload.parent_folder_id,
                "create_children",
                True,
            )
            if parent.space_id != space_id:
                fail("FOLDER_NOT_FOUND", 404)
            name, normalized = normalize_name(payload.name)
            parent_id = parent.item_id
        else:
            item, _ = access_item(
                self.session, self.user, payload.file_id, "write", True
            )
            if item.space_id != space_id or item.kind != "file":
                fail("FILE_NOT_FOUND", 404)
            state = self.session.get(DriveFile, item.item_id)
            if state.current_version_id != payload.expected_current_version_id:
                fail("FILE_VERSION_CONFLICT")
            if item.metadata_version != payload.expected_metadata_version:
                fail("FILE_METADATA_VERSION_CONFLICT")
            name = None
            parent_id = None
        usage = quota(
            self.session,
            space_id,
            getattr(self.settings, "space_quota_bytes", 10 * 1024**3),
        )
        if payload.size_bytes > getattr(self.settings, "max_file_bytes", 512 * 1024**2):
            fail("FILE_TOO_LARGE", 413)
        if (
            usage.committed_bytes + usage.reserved_bytes + payload.size_bytes
            > usage.limit_bytes
        ):
            fail("SPACE_QUOTA_EXCEEDED", 413)
        upload_id = str(uuid4())
        publication = str(uuid4())
        multipart = payload.size_bytes > getattr(
            self.settings, "multipart_threshold_bytes", 16 * 1024**2
        )
        part_size = (
            getattr(self.settings, "part_size_bytes", 8 * 1024**2)
            if multipart
            else max(1, payload.size_bytes)
        )
        prefix = getattr(self.settings, "oss_prefix", "vessel-files").strip("/")
        upload = DriveUpload(
            upload_id=upload_id,
            space_id=space_id,
            actor_user_id=self.user.user_id,
            mode=payload.mode,
            target_item_id=payload.file_id,
            parent_id=parent_id,
            name=name,
            expected_current_version_id=payload.expected_current_version_id,
            expected_metadata_version=payload.expected_metadata_version,
            size_bytes=payload.size_bytes,
            sha256=payload.sha256,
            content_type=payload.content_type,
            reserved_bytes=payload.size_bytes,
            temp_key=f"{prefix}/uploads/{upload_id}",
            final_key=f"{prefix}/files/{space_id}/{publication}",
            status="pending",
            transfer_mode="multipart" if multipart else "single",
            part_size_bytes=part_size,
            part_count=max(1, math.ceil(payload.size_bytes / part_size)),
            expires_at=datetime.now(UTC) + timedelta(hours=24),
            publication_id=publication,
        )
        usage.reserved_bytes += upload.size_bytes
        self.session.add(upload)
        self.session.flush()
        return {"upload": upload_payload(upload)}

    def sign(self, upload_id, numbers):
        upload = authorize_upload(self.session, self.user, upload_id)
        if utc(upload.expires_at) <= datetime.now(UTC) or upload.status not in (
            "pending",
            "uploading",
        ):
            fail("UPLOAD_STATE_CONFLICT")
        if len(set(numbers)) != len(numbers) or any(
            isinstance(n, bool) or n < 1 or n > upload.part_count for n in numbers
        ):
            fail("UPLOAD_PARTS_INVALID", 422)
        # The intent/key already committed before any remote multipart session exists.
        if upload.transfer_mode == "multipart" and not upload.oss_upload_id:
            started = self.storage.start_upload(row_dict(upload))
            upload.oss_upload_id = started.get("oss_upload_id")
        upload.status = "uploading"
        return {"instructions": self.storage.sign_parts(row_dict(upload), numbers)}

    def complete(self, upload_id, payload):
        upload = authorize_upload(self.session, self.user, upload_id)
        if upload.status == "ready":
            return {"upload": upload_payload(upload)}, 200
        if upload.status in ("verifying", "publishing"):
            return {"upload": upload_payload(upload)}, 202
        if upload.status not in ("pending", "uploading") or utc(
            upload.expires_at
        ) <= datetime.now(UTC):
            fail("UPLOAD_STATE_CONFLICT")
        parts = [p.model_dump() for p in payload.parts]
        if upload.transfer_mode == "multipart":
            if sorted(p["part_number"] for p in parts) != list(
                range(1, upload.part_count + 1)
            ):
                fail("UPLOAD_PARTS_INVALID", 422)
        elif parts:
            fail("UPLOAD_PARTS_INVALID", 422)
        upload.complete_parts = sorted(parts, key=lambda p: p["part_number"])
        upload.status = "verifying"
        upload.updated_at = datetime.now(UTC)
        enqueue(self.session, "upload:" + upload_id, "upload", {"upload_id": upload_id})
        return {"upload": upload_payload(upload)}, 202

    def cancel(self, upload_id):
        upload = authorize_upload(self.session, self.user, upload_id)
        if upload.status == "ready":
            fail("UPLOAD_STATE_CONFLICT")
        if upload.status not in ("cancelled", "expired", "failed", "conflict"):
            upload.status = "cancelled"
            release_reservation(self.session, upload)
            enqueue(
                self.session,
                "cleanup:" + upload_id,
                "cleanup_upload",
                {"upload_id": upload_id},
            )
            enqueue(
                self.session,
                "cleanup-late:" + upload_id,
                "cleanup_upload",
                {"upload_id": upload_id},
            )
            late = self.session.scalar(
                select(DriveOutbox).where(
                    DriveOutbox.business_key == "cleanup-late:" + upload_id
                )
            )
            if late:
                late.available_at = utc(upload.expires_at) + timedelta(hours=1)
        return {"upload": upload_payload(upload)}

    def restore(self, file_id, version_id, expected):
        item, _ = access_item(self.session, self.user, file_id, "write", True)
        if item.kind != "file":
            fail("FILE_NOT_FOUND", 404)
        file = self.session.get(DriveFile, file_id)
        if file.current_version_id != expected:
            fail("FILE_VERSION_CONFLICT")
        old = self.session.scalar(
            select(DriveFileVersion).where(
                DriveFileVersion.version_id == version_id,
                DriveFileVersion.item_id == file_id,
            )
        )
        if old is None:
            fail("FILE_VERSION_NOT_FOUND", 404)
        ordinal = (
            self.session.scalar(
                select(func.max(DriveFileVersion.ordinal)).where(
                    DriveFileVersion.item_id == file_id
                )
            )
            + 1
        )
        version = DriveFileVersion(
            version_id=str(uuid4()),
            item_id=file_id,
            ordinal=ordinal,
            bucket=old.bucket,
            object_key=old.object_key,
            oss_version_id=old.oss_version_id,
            size_bytes=old.size_bytes,
            sha256=old.sha256,
            crc64=old.crc64,
            content_type=old.content_type,
            created_by_user_id=self.user.user_id,
            source="restore",
            restored_from_version_id=version_id,
        )
        self.session.add(version)
        file.current_version_id = version.version_id
        item.metadata_version += 1
        item.updated_at = datetime.now(UTC)
        item.updated_by_user_id = self.user.user_id
        self.session.add(
            DriveAuditEvent(
                event_id=str(uuid4()),
                space_id=item.space_id,
                item_id=file_id,
                actor_user_id=self.user.user_id,
                operation="file.version.restore",
                after_version=item.metadata_version,
            )
        )
        self.session.flush()
        from .metadata import serialize_item

        return {
            "file": serialize_item(item, self.session),
            "version": version_payload(version),
        }
