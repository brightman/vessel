"""Persist non-authoritative Page edit proposals.

Revision ID: 0003_page_proposals
Revises: 0002_page_versions
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0003_page_proposals"
down_revision: Union[str, None] = "0002_page_versions"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("page_versions", sa.Column("run_id", sa.String(length=128), nullable=True))
    op.create_table(
        "page_proposals",
        sa.Column("proposal_id", sa.String(length=36), primary_key=True),
        sa.Column("page_id", sa.String(length=36), nullable=False),
        sa.Column("owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("base_revision", sa.Integer(), nullable=False),
        sa.Column("run_id", sa.String(length=128), nullable=False),
        sa.Column("allow_full_rewrite", sa.Boolean(), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("operations", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=False),
        sa.Column("applied_operations", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=False),
        sa.Column("preview_title", sa.String(length=256), nullable=False),
        sa.Column("preview_document", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=False),
        sa.Column("preview_markdown", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=True),
        sa.Column("failure_code", sa.String(length=64), nullable=True),
        sa.Column("accepted_revision", sa.Integer(), nullable=True),
        sa.Column("acceptance_idempotency_key", sa.String(length=128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["page_id"], ["pages.page_id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.user_id"], ondelete="CASCADE"),
        sa.UniqueConstraint("page_id", "run_id", name="uq_page_proposals_page_run"),
    )
    op.create_index("ix_page_proposals_page_id", "page_proposals", ["page_id"])
    op.create_index("ix_page_proposals_owner_user_id", "page_proposals", ["owner_user_id"])
    op.create_index("ix_page_proposals_status", "page_proposals", ["status"])


def downgrade() -> None:
    op.drop_index("ix_page_proposals_status", table_name="page_proposals")
    op.drop_index("ix_page_proposals_owner_user_id", table_name="page_proposals")
    op.drop_index("ix_page_proposals_page_id", table_name="page_proposals")
    op.drop_table("page_proposals")
    op.drop_column("page_versions", "run_id")
