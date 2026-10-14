"""Add revocable, Page/Run-scoped MCP capabilities.

Revision ID: 0004_page_capabilities
Revises: 0003_page_proposals
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0004_page_capabilities"
down_revision: Union[str, None] = "0003_page_proposals"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "page_capabilities",
        sa.Column("capability_id", sa.String(length=36), primary_key=True),
        sa.Column("jti", sa.String(length=36), nullable=False),
        sa.Column("owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("page_id", sa.String(length=36), nullable=False),
        sa.Column("run_id", sa.String(length=128), nullable=False),
        sa.Column("scope", sa.String(length=128), nullable=False),
        sa.Column("selection_json", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.user_id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["page_id"], ["pages.page_id"], ondelete="CASCADE"),
        sa.UniqueConstraint("jti", name="uq_page_capabilities_jti"),
    )
    op.create_index("ix_page_capabilities_jti", "page_capabilities", ["jti"])
    op.create_index("ix_page_capabilities_owner_user_id", "page_capabilities", ["owner_user_id"])
    op.create_index("ix_page_capabilities_page_id", "page_capabilities", ["page_id"])
    op.create_index("ix_page_capabilities_run_id", "page_capabilities", ["run_id"])


def downgrade() -> None:
    op.drop_index("ix_page_capabilities_run_id", table_name="page_capabilities")
    op.drop_index("ix_page_capabilities_page_id", table_name="page_capabilities")
    op.drop_index("ix_page_capabilities_owner_user_id", table_name="page_capabilities")
    op.drop_index("ix_page_capabilities_jti", table_name="page_capabilities")
    op.drop_table("page_capabilities")
