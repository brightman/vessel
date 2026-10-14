from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, JSON, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from pages_service.models.base import Base


class PageAgentEvent(Base):
    __tablename__ = "page_agent_events"
    __table_args__ = (
        UniqueConstraint("event_id", name="uq_page_agent_events_event_id"),
        Index("ix_page_agent_events_page_sequence", "page_id", "sequence_id"),
    )

    sequence_id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    event_id: Mapped[str] = mapped_column(String(36), nullable=False)
    correlation_id: Mapped[str] = mapped_column(String(128), nullable=False)
    page_id: Mapped[str] = mapped_column(
        ForeignKey("pages.page_id", ondelete="CASCADE"), nullable=False
    )
    proposal_id: Mapped[str] = mapped_column(
        ForeignKey("page_proposals.proposal_id", ondelete="CASCADE"), nullable=False
    )
    run_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    payload: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )
