from datetime import UTC, datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, JSON, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class PageProposal(Base):
    __tablename__ = "page_proposals"
    __table_args__ = (
        UniqueConstraint("page_id", "run_id", name="uq_page_proposals_page_run"),
    )

    proposal_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    page_id: Mapped[str] = mapped_column(
        ForeignKey("pages.page_id", ondelete="CASCADE"), index=True
    )
    owner_user_id: Mapped[str] = mapped_column(
        ForeignKey("users.user_id", ondelete="CASCADE"), index=True
    )
    base_revision: Mapped[int] = mapped_column()
    run_id: Mapped[str] = mapped_column(String(128))
    allow_full_rewrite: Mapped[bool] = mapped_column(Boolean, default=False)
    status: Mapped[str] = mapped_column(String(16), default="streaming", index=True)
    operations: Mapped[list] = mapped_column(JSON().with_variant(JSONB, "postgresql"), default=list)
    applied_operations: Mapped[list] = mapped_column(JSON().with_variant(JSONB, "postgresql"), default=list)
    preview_title: Mapped[str] = mapped_column(String(256))
    preview_document: Mapped[dict] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    preview_markdown: Mapped[str] = mapped_column(Text, default="")
    summary: Mapped[str | None] = mapped_column(Text, nullable=True)
    failure_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    accepted_revision: Mapped[int | None] = mapped_column(nullable=True)
    acceptance_idempotency_key: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC)
    )
