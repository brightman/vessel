"""Create Pages users, sessions, directories, and pages.

Revision ID: 0001_pages_identity_and_content
Revises:
Create Date: 2026-10-07
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0001_pages_identity_and_content"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("user_id", sa.String(length=36), primary_key=True),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("roles", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("email", name="uq_users_email"),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    op.create_table(
        "user_credentials",
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("password_hash", sa.String(length=512), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.user_id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id"),
    )

    op.create_table(
        "refresh_sessions",
        sa.Column("session_id", sa.String(length=36), primary_key=True),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.user_id"], ondelete="CASCADE"),
        sa.UniqueConstraint("token_hash", name="uq_refresh_sessions_token_hash"),
    )
    op.create_index("ix_refresh_sessions_user_id", "refresh_sessions", ["user_id"])
    op.create_index("ix_refresh_sessions_token_hash", "refresh_sessions", ["token_hash"], unique=True)
    op.create_index("ix_refresh_sessions_expires_at", "refresh_sessions", ["expires_at"])

    op.create_table(
        "page_directories",
        sa.Column("directory_id", sa.String(length=36), primary_key=True),
        sa.Column("owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.user_id"], ondelete="CASCADE"),
    )
    op.create_index("ix_page_directories_owner_user_id", "page_directories", ["owner_user_id"])

    op.create_table(
        "pages",
        sa.Column("page_id", sa.String(length=36), primary_key=True),
        sa.Column("owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("directory_id", sa.String(length=36), nullable=True),
        sa.Column("title", sa.String(length=256), nullable=False),
        sa.Column(
            "document_json",
            sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"),
            nullable=False,
        ),
        sa.Column("markdown", sa.Text(), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("agent_thread_id", sa.String(length=128), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["directory_id"], ["page_directories.directory_id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.user_id"], ondelete="CASCADE"),
    )
    op.create_index("ix_pages_owner_user_id", "pages", ["owner_user_id"])
    op.create_index("ix_pages_directory_id", "pages", ["directory_id"])
    op.create_index("ix_pages_status", "pages", ["status"])


def downgrade() -> None:
    op.drop_index("ix_pages_status", table_name="pages")
    op.drop_index("ix_pages_directory_id", table_name="pages")
    op.drop_index("ix_pages_owner_user_id", table_name="pages")
    op.drop_table("pages")
    op.drop_index("ix_page_directories_owner_user_id", table_name="page_directories")
    op.drop_table("page_directories")
    op.drop_index("ix_refresh_sessions_expires_at", table_name="refresh_sessions")
    op.drop_index("ix_refresh_sessions_token_hash", table_name="refresh_sessions")
    op.drop_index("ix_refresh_sessions_user_id", table_name="refresh_sessions")
    op.drop_table("refresh_sessions")
    op.drop_table("user_credentials")
    op.drop_index("ix_users_email", table_name="users")
    op.drop_table("users")
