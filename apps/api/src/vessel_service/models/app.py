from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, JSON, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class VesselApp(Base):
    __tablename__ = "vessel_apps"
    __table_args__ = (Index("ix_vessel_apps_space_status", "space_id", "status"),)

    app_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id", ondelete="RESTRICT"), nullable=False)
    name: Mapped[str] = mapped_column(String(120))
    manifest_json: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    manifest_version: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(16), default="active")
    created_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
    updated_by: Mapped[str] = mapped_column(ForeignKey("users.user_id"))
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
