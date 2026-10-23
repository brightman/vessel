from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteAsset(Base):
    __tablename__ = "note_assets"

    asset_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_user_id: Mapped[str] = mapped_column(
        ForeignKey("users.user_id", ondelete="RESTRICT"), index=True
    )
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id", ondelete="CASCADE"), index=True
    )
    object_key: Mapped[str] = mapped_column(String(160), unique=True)
    content_type: Mapped[str] = mapped_column(String(32))
    size_bytes: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
