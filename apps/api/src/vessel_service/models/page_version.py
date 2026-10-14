from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, JSON, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class PageVersion(Base):
    __tablename__ = "page_versions"
    __table_args__ = (
        UniqueConstraint("page_id", "revision", name="uq_page_versions_page_revision"),
    )

    version_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    page_id: Mapped[str] = mapped_column(
        ForeignKey("pages.page_id", ondelete="CASCADE"), index=True
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
