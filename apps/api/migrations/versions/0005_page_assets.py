"""Store private metadata for Page image assets.

Revision ID: 0005_page_assets
Revises: 0004_page_capabilities
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "0005_page_assets"
down_revision: Union[str, None] = "0004_page_capabilities"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "page_assets",
        sa.Column("asset_id", sa.String(length=36), primary_key=True),
        sa.Column("owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("page_id", sa.String(length=36), nullable=False),
        sa.Column("object_key", sa.String(length=160), nullable=False),
        sa.Column("content_type", sa.String(length=32), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.user_id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["page_id"], ["pages.page_id"], ondelete="CASCADE"),
        sa.UniqueConstraint("object_key", name="uq_page_assets_object_key"),
        sa.CheckConstraint("size_bytes > 0", name="ck_page_assets_size_positive"),
    )
    op.create_index("ix_page_assets_owner_user_id", "page_assets", ["owner_user_id"])
    op.create_index("ix_page_assets_page_id", "page_assets", ["page_id"])


def downgrade() -> None:
    op.drop_index("ix_page_assets_page_id", table_name="page_assets")
    op.drop_index("ix_page_assets_owner_user_id", table_name="page_assets")
    op.drop_table("page_assets")
