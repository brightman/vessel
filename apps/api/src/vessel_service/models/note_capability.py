from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, JSON, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteCapability(Base):
    __tablename__ = "note_capabilities"
    __table_args__ = (
        UniqueConstraint("jti", name="uq_note_capabilities_jti"),
    )

    capability_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    jti: Mapped[str] = mapped_column(String(36), index=True)
    owner_user_id: Mapped[str] = mapped_column(
        ForeignKey("users.user_id", ondelete="CASCADE"), index=True
    )
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id", ondelete="CASCADE"), index=True
    )
    run_id: Mapped[str] = mapped_column(String(128), index=True)
    scope: Mapped[str] = mapped_column(String(128))
    selection_json: Mapped[dict | None] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
