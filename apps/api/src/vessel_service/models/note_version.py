from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, JSON, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteVersion(Base):
    __tablename__ = "note_versions"
    __table_args__ = (
        UniqueConstraint("note_id", "revision", name="uq_note_versions_note_revision"),
    )

    version_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id", ondelete="CASCADE"), index=True
    )
    revision: Mapped[int] = mapped_column()
    title: Mapped[str] = mapped_column(String(256))
    document_json: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    markdown: Mapped[str] = mapped_column(Text)
    source: Mapped[str] = mapped_column(String(16), default="human")
    actor_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    run_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
