from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, JSON, String, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteAgentRun(Base):
    __tablename__ = "note_agent_runs"

    run_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    note_id: Mapped[str] = mapped_column(ForeignKey("notes.note_id", ondelete="CASCADE"), index=True)
    owner_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id", ondelete="CASCADE"), index=True)
    mode: Mapped[str] = mapped_column(String(8))
    base_revision: Mapped[int] = mapped_column()
    selection_json: Mapped[dict | None] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=True)
    status: Mapped[str] = mapped_column(String(32), default="queued")
    failure_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    response_json: Mapped[dict | None] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=True)
    prompt: Mapped[str | None] = mapped_column(Text, nullable=True)
    reply_to_run_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    option_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    answered_by_run_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    reply: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
