"""Persistent file-domain state; deliberately independent of Note and App models."""

from datetime import UTC, datetime

from sqlalchemy import (
    JSON,
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


def now():
    return datetime.now(UTC)


def ident():
    return mapped_column(String(36), primary_key=True)


def string(nullable=False):
    return mapped_column(String(512), nullable=nullable)


def stamp():
    return mapped_column(DateTime(timezone=True), default=now)


class DriveItem(Base):
    __tablename__ = "drive_items"
    __table_args__ = (
        UniqueConstraint("space_id", "item_id"),
        ForeignKeyConstraint(
            ["space_id", "parent_id"], ["drive_items.space_id", "drive_items.item_id"]
        ),
        CheckConstraint("kind IN ('folder','file')"),
        CheckConstraint("status IN ('active','trashed','purging','purged')"),
        Index(
            "uq_drive_item_active_name",
            "space_id",
            "parent_id",
            "normalized_name",
            unique=True,
            sqlite_where=text("status='active' AND parent_id IS NOT NULL"),
            postgresql_where=text("status='active' AND parent_id IS NOT NULL"),
        ),
        Index(
            "uq_drive_item_root",
            "space_id",
            unique=True,
            sqlite_where=text("parent_id IS NULL"),
            postgresql_where=text("parent_id IS NULL"),
        ),
        Index("ix_drive_items_parent_status", "space_id", "parent_id", "status"),
    )
    item_id: Mapped[str] = ident()
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id"))
    kind: Mapped[str] = string()
    parent_id: Mapped[str | None] = string(True)
    name: Mapped[str] = string()
    normalized_name: Mapped[str] = string()
    metadata_version: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(16), default="active")
    trash_batch_id: Mapped[str | None] = string(True)
    created_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    updated_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    created_at: Mapped[datetime] = stamp()
    updated_at: Mapped[datetime] = stamp()


class DriveSpaceState(Base):
    __tablename__ = "drive_space_state"
    space_id: Mapped[str] = mapped_column(
        ForeignKey("spaces.space_id"), primary_key=True
    )
    root_item_id: Mapped[str] = mapped_column(
        ForeignKey("drive_items.item_id"), unique=True
    )
    acl_revision: Mapped[int] = mapped_column(Integer, default=1)


class DriveFile(Base):
    __tablename__ = "drive_files"
    __table_args__ = (
        ForeignKeyConstraint(
            ["item_id", "current_version_id"],
            ["drive_file_versions.item_id", "drive_file_versions.version_id"],
            name="fk_drive_current_version",
            use_alter=True,
            deferrable=True,
            initially="DEFERRED",
        ),
    )
    item_id: Mapped[str] = mapped_column(
        ForeignKey("drive_items.item_id"), primary_key=True
    )
    current_version_id: Mapped[str | None] = string(True)


class DriveFileVersion(Base):
    __tablename__ = "drive_file_versions"
    __table_args__ = (
        UniqueConstraint("item_id", "ordinal"),
        UniqueConstraint("item_id", "version_id"),
    )
    version_id: Mapped[str] = ident()
    item_id: Mapped[str] = mapped_column(ForeignKey("drive_files.item_id"))
    ordinal: Mapped[int] = mapped_column(Integer)
    bucket: Mapped[str] = string()
    object_key: Mapped[str] = string()
    oss_version_id: Mapped[str] = string()
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = string()
    crc64: Mapped[str | None] = string(True)
    content_type: Mapped[str] = string()
    created_by_user_id: Mapped[str] = string()
    created_at: Mapped[datetime] = stamp()
    source: Mapped[str] = mapped_column(String(16), default="upload")
    restored_from_version_id: Mapped[str | None] = string(True)


class DriveUpload(Base):
    __tablename__ = "drive_file_uploads"
    upload_id: Mapped[str] = ident()
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id"))
    actor_user_id: Mapped[str] = string()
    mode: Mapped[str] = string()
    target_item_id: Mapped[str | None] = string(True)
    parent_id: Mapped[str | None] = string(True)
    name: Mapped[str | None] = string(True)
    expected_current_version_id: Mapped[str | None] = string(True)
    expected_metadata_version: Mapped[int | None] = mapped_column(
        Integer, nullable=True
    )
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = string()
    content_type: Mapped[str] = string()
    reserved_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    temp_key: Mapped[str] = string()
    final_key: Mapped[str | None] = string(True)
    verified_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    complete_parts: Mapped[list] = mapped_column(JSON, default=list)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    lease_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    oss_upload_id: Mapped[str | None] = string(True)
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    transfer_mode: Mapped[str] = string()
    part_size_bytes: Mapped[int] = mapped_column(BigInteger)
    part_count: Mapped[int] = mapped_column(Integer)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    version_id: Mapped[str | None] = string(True)
    failure_code: Mapped[str | None] = string(True)
    publication_id: Mapped[str] = string()
    verified_bucket: Mapped[str | None] = string(True)
    verified_key: Mapped[str | None] = string(True)
    verified_version_id: Mapped[str | None] = string(True)
    parts: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = stamp()
    updated_at: Mapped[datetime] = stamp()


class DriveGrant(Base):
    __tablename__ = "drive_grants"
    __table_args__ = (
        CheckConstraint("role IN ('viewer','editor')"),
        Index(
            "uq_drive_grants_live",
            "item_id",
            "user_id",
            unique=True,
            sqlite_where=text("revoked_at IS NULL"),
            postgresql_where=text("revoked_at IS NULL"),
        ),
        Index("ix_drive_grants_user", "user_id", "revoked_at", "item_id"),
    )
    grant_id: Mapped[str] = ident()
    item_id: Mapped[str] = mapped_column(ForeignKey("drive_items.item_id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    role: Mapped[str] = string()
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_by_user_id: Mapped[str] = string()
    created_at: Mapped[datetime] = stamp()
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    version: Mapped[int] = mapped_column(Integer, default=1)


class DriveTrashBatch(Base):
    __tablename__ = "drive_trash_batches"
    batch_id: Mapped[str] = ident()
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id"))
    root_item_id: Mapped[str] = string()
    original_parent_folder_id: Mapped[str] = string()
    actor_user_id: Mapped[str] = string()
    status: Mapped[str] = mapped_column(String(16), default="trashed")
    batch_version: Mapped[int] = mapped_column(Integer, default=1)
    trashed_at: Mapped[datetime] = stamp()
    retention_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class DriveQuotaUsage(Base):
    __tablename__ = "drive_quota_usage"
    __table_args__ = (
        CheckConstraint(
            "committed_bytes >= 0 AND reserved_bytes >= 0 AND limit_bytes >= 0",
            name="ck_drive_quota_nonnegative",
        ),
    )
    space_id: Mapped[str] = mapped_column(
        ForeignKey("spaces.space_id"), primary_key=True
    )
    committed_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    reserved_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    limit_bytes: Mapped[int] = mapped_column(BigInteger, default=10 * 1024**3)


class DriveIdempotencyReceipt(Base):
    __tablename__ = "drive_idempotency_receipts"
    __table_args__ = (UniqueConstraint("actor_user_id", "operation", "target", "key"),)
    receipt_id: Mapped[str] = ident()
    actor_user_id: Mapped[str] = string()
    operation: Mapped[str] = string()
    target: Mapped[str] = string()
    key: Mapped[str] = mapped_column(String(128))
    request_hash: Mapped[str] = string()
    status: Mapped[str] = string()
    response: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    status_code: Mapped[int | None] = mapped_column(Integer, nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = stamp()


class DriveAuditEvent(Base):
    __tablename__ = "drive_audit_events"
    event_id: Mapped[str] = ident()
    space_id: Mapped[str] = string()
    item_id: Mapped[str | None] = string(True)
    actor_user_id: Mapped[str] = string()
    operation: Mapped[str] = string()
    result: Mapped[str] = mapped_column(String(16), default="success")
    before_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    after_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    request_id: Mapped[str | None] = string(True)
    created_at: Mapped[datetime] = stamp()


class DriveOutbox(Base):
    __tablename__ = "drive_outbox"
    outbox_id: Mapped[str] = ident()
    business_key: Mapped[str] = mapped_column(String(512), unique=True)
    kind: Mapped[str] = string()
    payload: Mapped[dict] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    lease_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    available_at: Mapped[datetime] = stamp()
    failure_code: Mapped[str | None] = string(True)
    created_at: Mapped[datetime] = stamp()
    updated_at: Mapped[datetime] = stamp()


class DrivePurgeJob(Base):
    __tablename__ = "drive_purge_jobs"
    purge_id: Mapped[str] = ident()
    space_id: Mapped[str] = string()
    batch_id: Mapped[str] = string()
    status: Mapped[str] = mapped_column(String(16), default="pending")
    failure_code: Mapped[str | None] = string(True)
    created_at: Mapped[datetime] = stamp()
    updated_at: Mapped[datetime] = stamp()


class DriveOperationPreview(Base):
    __tablename__ = "drive_operation_previews"
    preview_id: Mapped[str] = ident()
    actor_user_id: Mapped[str] = string()
    space_id: Mapped[str] = string()
    kind: Mapped[str] = string()
    item_id: Mapped[str] = string()
    batch_id: Mapped[str | None] = string(True)
    preview_hash: Mapped[str] = string()
    payload: Mapped[dict] = mapped_column(JSON)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
