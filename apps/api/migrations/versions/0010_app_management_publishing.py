"""Add Vessel App settings, releases, and audit events.

Revision ID: 0010_app_management_publishing
Revises: 0009_shared_files
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB


revision = "0010_app_management_publishing"
down_revision = "0009_shared_files"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vessel_apps", sa.Column("description", sa.String(2000), nullable=False, server_default=""))
    op.add_column("vessel_apps", sa.Column("settings_version", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("vessel_apps", sa.Column("archived_by", sa.String(36), nullable=True))
    op.add_column("vessel_apps", sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True))
    op.create_foreign_key("fk_vessel_apps_archived_by", "vessel_apps", "users", ["archived_by"], ["user_id"], ondelete="RESTRICT")

    payload = sa.JSON().with_variant(JSONB(), "postgresql")
    op.create_table(
        "vessel_app_releases",
        sa.Column("release_id", sa.String(36), primary_key=True),
        sa.Column("app_id", sa.String(36), sa.ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("manifest_version", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("entry_file", sa.String(512), nullable=True),
        sa.Column("object_prefix", sa.String(512), nullable=False, unique=True),
        sa.Column("draft_object_key", sa.String(512), nullable=False, unique=True),
        sa.Column("file_count", sa.Integer(), nullable=True),
        sa.Column("total_size_bytes", sa.BigInteger(), nullable=True),
        sa.Column("checksum_sha256", sa.String(64), nullable=True),
        sa.Column("validation_error_code", sa.String(128), nullable=True),
        sa.Column("created_by", sa.String(36), sa.ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("published_by", sa.String(36), sa.ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=True),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.CheckConstraint("NOT is_current OR status = 'published'", name="ck_vessel_app_releases_current_published"),
        sa.UniqueConstraint("app_id", "version", name="uq_vessel_app_releases_app_version"),
    )
    op.create_index(
        "uq_vessel_app_releases_current", "vessel_app_releases", ["app_id"], unique=True,
        postgresql_where=sa.text("is_current"), sqlite_where=sa.text("is_current = 1"),
    )
    op.create_table(
        "vessel_app_audit_events",
        sa.Column("event_id", sa.String(36), primary_key=True),
        sa.Column("app_id", sa.String(36), sa.ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False),
        sa.Column("release_id", sa.String(36), sa.ForeignKey("vessel_app_releases.release_id", ondelete="CASCADE"), nullable=True),
        sa.Column("actor_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False),
        sa.Column("action", sa.String(64), nullable=False),
        sa.Column("details_json", payload, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_vessel_app_audit_events_app_page", "vessel_app_audit_events", ["app_id", "created_at", "event_id"])
    op.create_index("ix_vessel_app_audit_events_release", "vessel_app_audit_events", ["release_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_vessel_app_audit_events_release", table_name="vessel_app_audit_events")
    op.drop_index("ix_vessel_app_audit_events_app_page", table_name="vessel_app_audit_events")
    op.drop_table("vessel_app_audit_events")
    op.drop_index("uq_vessel_app_releases_current", table_name="vessel_app_releases")
    op.drop_table("vessel_app_releases")
    op.drop_constraint("fk_vessel_apps_archived_by", "vessel_apps", type_="foreignkey")
    op.drop_column("vessel_apps", "archived_at")
    op.drop_column("vessel_apps", "archived_by")
    op.drop_column("vessel_apps", "settings_version")
    op.drop_column("vessel_apps", "description")
