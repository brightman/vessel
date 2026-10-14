"""Add personal and team spaces, memberships, and invitations.

Revision ID: 0007_spaces_and_team_permissions
Revises: 0006_page_agent_events
"""

from datetime import UTC, datetime
from uuid import uuid4

from alembic import op
import sqlalchemy as sa

revision = "0007_spaces_and_team_permissions"
down_revision = "0006_page_agent_events"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "spaces",
        sa.Column("space_id", sa.String(36), primary_key=True),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("owner_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="CASCADE")),
        sa.Column("created_by_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="SET NULL")),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("kind IN ('personal', 'team')", name="ck_spaces_kind"),
        sa.CheckConstraint(
            "(kind = 'personal' AND owner_user_id IS NOT NULL) OR "
            "(kind = 'team' AND owner_user_id IS NULL)",
            name="ck_spaces_owner_kind",
        ),
    )
    op.create_index("ix_spaces_owner_user_id", "spaces", ["owner_user_id"])
    op.create_index(
        "uq_spaces_personal_owner", "spaces", ["owner_user_id"], unique=True,
        postgresql_where=sa.text("kind = 'personal'"),
        sqlite_where=sa.text("kind = 'personal'"),
    )
    op.create_table(
        "team_members",
        sa.Column("space_id", sa.String(36), sa.ForeignKey("spaces.space_id", ondelete="CASCADE"), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="RESTRICT"), primary_key=True),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("role IN ('owner', 'admin', 'editor', 'viewer')", name="ck_team_members_role"),
        sa.CheckConstraint("status IN ('active', 'removed')", name="ck_team_members_status"),
    )
    op.create_index("ix_team_members_user_status", "team_members", ["user_id", "status"])
    op.create_table(
        "team_invitations",
        sa.Column("invitation_id", sa.String(36), primary_key=True),
        sa.Column("space_id", sa.String(36), sa.ForeignKey("spaces.space_id", ondelete="CASCADE"), nullable=False),
        sa.Column("invitee_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False),
        sa.Column("invited_by_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("responded_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("role IN ('owner', 'admin', 'editor', 'viewer')", name="ck_team_invitations_role"),
        sa.CheckConstraint("status IN ('pending', 'accepted', 'revoked', 'expired')", name="ck_team_invitations_status"),
    )
    op.create_index(
        "uq_team_invitations_pending", "team_invitations", ["space_id", "invitee_user_id"], unique=True,
        postgresql_where=sa.text("status = 'pending'"),
        sqlite_where=sa.text("status = 'pending'"),
    )
    op.create_index(
        "ix_team_invitations_invitee_status_expiry", "team_invitations",
        ["invitee_user_id", "status", "expires_at"],
    )

    connection = op.get_bind()
    users = connection.execute(sa.text("SELECT user_id, name FROM users ORDER BY user_id"))
    spaces = sa.table(
        "spaces",
        sa.column("space_id", sa.String(36)), sa.column("kind", sa.String(16)),
        sa.column("name", sa.String(120)), sa.column("owner_user_id", sa.String(36)),
        sa.column("created_by_user_id", sa.String(36)), sa.column("status", sa.String(16)),
        sa.column("created_at", sa.DateTime(timezone=True)),
        sa.column("updated_at", sa.DateTime(timezone=True)),
    )
    now = datetime.now(UTC)
    for user_id, name in users:
        connection.execute(spaces.insert().values(
            space_id=str(uuid4()), kind="personal", name=f"{name[:108]} Personal",
            owner_user_id=user_id, created_by_user_id=user_id, status="active",
            created_at=now, updated_at=now,
        ))


def downgrade() -> None:
    op.drop_index("ix_team_invitations_invitee_status_expiry", table_name="team_invitations")
    op.drop_index("uq_team_invitations_pending", table_name="team_invitations")
    op.drop_table("team_invitations")
    op.drop_index("ix_team_members_user_status", table_name="team_members")
    op.drop_table("team_members")
    op.drop_index("uq_spaces_personal_owner", table_name="spaces")
    op.drop_index("ix_spaces_owner_user_id", table_name="spaces")
    op.drop_table("spaces")
