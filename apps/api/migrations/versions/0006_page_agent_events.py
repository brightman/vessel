"""Persist redacted, replayable Page Agent proposal events.

Revision ID: 0006_page_agent_events
Revises: 0005_page_assets
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0006_page_agent_events"
down_revision: Union[str, None] = "0005_page_assets"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "page_agent_events",
        sa.Column("sequence_id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("event_id", sa.String(length=36), nullable=False),
        sa.Column("correlation_id", sa.String(length=128), nullable=False),
        sa.Column("page_id", sa.String(length=36), nullable=False),
        sa.Column("proposal_id", sa.String(length=36), nullable=False),
        sa.Column("run_id", sa.String(length=128), nullable=False),
        sa.Column("event_type", sa.String(length=64), nullable=False),
        sa.Column("payload", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["page_id"], ["pages.page_id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["proposal_id"], ["page_proposals.proposal_id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("sequence_id"),
        sa.UniqueConstraint("event_id", name="uq_page_agent_events_event_id"),
    )
    op.create_index(
        "ix_page_agent_events_page_sequence",
        "page_agent_events",
        ["page_id", "sequence_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_page_agent_events_page_sequence", table_name="page_agent_events")
    op.drop_table("page_agent_events")
