from datetime import UTC, datetime

from sqlalchemy import BigInteger, Boolean, CheckConstraint, DateTime, ForeignKey, Index, Integer, JSON, String, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class VesselApp(Base):
    __tablename__ = "vessel_apps"
    __table_args__ = (Index("ix_vessel_apps_space_status", "space_id", "status"),)

    app_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id", ondelete="RESTRICT"), nullable=False)
    name: Mapped[str] = mapped_column(String(120))
    description: Mapped[str] = mapped_column(String(2000), default="", server_default="")
    manifest_json: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    manifest_version: Mapped[int] = mapped_column(Integer, default=1)
    settings_version: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    status: Mapped[str] = mapped_column(String(16), default="active")
    created_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    updated_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    archived_by: Mapped[str | None] = mapped_column(ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=True)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC))


class VesselAppRecord(Base):
    __tablename__ = "vessel_app_records"
    __table_args__ = (Index("ix_vessel_app_records_table_page", "app_id", "table_name", "deleted_at", "created_at", "record_id"),)

    record_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    app_id: Mapped[str] = mapped_column(ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False)
    table_name: Mapped[str] = mapped_column(String(63))
    values_json: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    row_version: Mapped[int] = mapped_column(Integer, default=1)
    created_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    updated_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC))


class VesselAppRelease(Base):
    __tablename__ = "vessel_app_releases"
    __table_args__ = (
        CheckConstraint("NOT is_current OR status = 'published'", name="ck_vessel_app_releases_current_published"),
        Index("uq_vessel_app_releases_app_version", "app_id", "version", unique=True),
        Index(
            "uq_vessel_app_releases_current", "app_id", unique=True,
            postgresql_where=text("is_current"), sqlite_where=text("is_current = 1"),
        ),
    )

    release_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    app_id: Mapped[str] = mapped_column(ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    manifest_version: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="draft")
    entry_file: Mapped[str | None] = mapped_column(String(512), nullable=True)
    object_prefix: Mapped[str] = mapped_column(String(512), unique=True, nullable=False)
    draft_object_key: Mapped[str] = mapped_column(String(512), unique=True, nullable=False)
    file_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    total_size_bytes: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    checksum_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    validation_error_code: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_by: Mapped[str] = mapped_column(ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    published_by: Mapped[str | None] = mapped_column(ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=True)
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="false")


class VesselAppAuditEvent(Base):
    __tablename__ = "vessel_app_audit_events"
    __table_args__ = (
        Index("ix_vessel_app_audit_events_app_page", "app_id", "created_at", "event_id"),
        Index("ix_vessel_app_audit_events_release", "release_id", "created_at"),
    )

    event_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    app_id: Mapped[str] = mapped_column(ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False)
    release_id: Mapped[str | None] = mapped_column(ForeignKey("vessel_app_releases.release_id", ondelete="CASCADE"), nullable=True)
    actor_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False)
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    details_json: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
