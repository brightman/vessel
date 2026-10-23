from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteDirectory(Base):
    __tablename__ = "note_directories"
    __table_args__ = (Index("ix_note_directories_space_status", "space_id", "status"),)

    directory_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id", ondelete="RESTRICT"), nullable=False)
    owner_user_id: Mapped[str] = mapped_column(
        ForeignKey("users.user_id", ondelete="RESTRICT"), index=True
    )
    name: Mapped[str] = mapped_column(String(120))
    status: Mapped[str] = mapped_column(String(16), default="active")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC)
    )
