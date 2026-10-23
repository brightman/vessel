from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, JSON, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class NoteAgentEvent(Base):
    __tablename__ = "note_agent_events"
    __table_args__ = (
        UniqueConstraint("event_id", name="uq_note_agent_events_event_id"),
        Index("ix_note_agent_events_note_sequence", "note_id", "sequence_id"),
    )

    sequence_id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    event_id: Mapped[str] = mapped_column(String(36), nullable=False)
    correlation_id: Mapped[str] = mapped_column(String(128), nullable=False)
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id", ondelete="CASCADE"), nullable=False
    )
    proposal_id: Mapped[str] = mapped_column(
        ForeignKey("note_proposals.proposal_id", ondelete="CASCADE"), nullable=False
    )
    run_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    payload: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )
