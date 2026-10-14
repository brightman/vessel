"""Add immutable Page content versions.

Revision ID: 0002_page_versions
Revises: 0001_pages_identity_and_content
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0002_page_versions"
down_revision: Union[str, None] = "0001_pages_identity_and_content"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "page_versions",
        sa.Column("version_id", sa.String(length=36), primary_key=True),
        sa.Column("page_id", sa.String(length=36), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(length=256), nullable=False),
        sa.Column(
            "document_json",
            sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"),
            nullable=False,
        ),
        sa.Column("markdown", sa.Text(), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=False),
        sa.Column("actor_user_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["page_id"], ["pages.page_id"], ondelete="CASCADE"),
        sa.UniqueConstraint("page_id", "revision", name="uq_page_versions_page_revision"),
    )
    op.create_index("ix_page_versions_page_id", "page_versions", ["page_id"])


def downgrade() -> None:
    op.drop_index("ix_page_versions_page_id", table_name="page_versions")
    op.drop_table("page_versions")
