"""Give fresh Page rows a space and add Vessel Apps storage.

Revision ID: 0008_space_resources
Revises: 0007_spaces_and_team_permissions
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0008_space_resources"
down_revision = "0007_spaces_and_team_permissions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    connection = op.get_bind()
    for table in ("pages", "page_directories"):
        if connection.scalar(sa.text(f"SELECT count(*) FROM {table}")):
            raise RuntimeError("Vessel space migration requires an empty Pages database")
        op.add_column(table, sa.Column("space_id", sa.String(36), sa.ForeignKey("spaces.space_id", ondelete="RESTRICT"), nullable=False))
    for table in ("pages", "page_directories", "page_assets"):
        op.drop_constraint(f"{table}_owner_user_id_fkey", table, type_="foreignkey")
        op.create_foreign_key(
            f"{table}_owner_user_id_fkey", table, "users", ["owner_user_id"], ["user_id"], ondelete="RESTRICT"
        )
    op.create_index("ix_pages_space_status_updated", "pages", ["space_id", "status", "updated_at"])
    op.create_index("ix_page_directories_space_status", "page_directories", ["space_id", "status"])

    op.create_table(
        "vessel_apps",
        sa.Column("app_id", sa.String(36), primary_key=True),
        sa.Column("space_id", sa.String(36), sa.ForeignKey("spaces.space_id", ondelete="RESTRICT"), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("manifest_json", JSONB(), nullable=False),
        sa.Column("manifest_version", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_by", sa.String(36), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("updated_by", sa.String(36), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_vessel_apps_space_status", "vessel_apps", ["space_id", "status"])
    op.create_table(
        "vessel_app_records",
        sa.Column("record_id", sa.String(36), primary_key=True),
        sa.Column("app_id", sa.String(36), sa.ForeignKey("vessel_apps.app_id", ondelete="CASCADE"), nullable=False),
        sa.Column("table_name", sa.String(63), nullable=False),
        sa.Column("values_json", JSONB(), nullable=False),
        sa.Column("row_version", sa.Integer(), nullable=False),
        sa.Column("created_by", sa.String(36), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("updated_by", sa.String(36), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_vessel_app_records_table_page", "vessel_app_records", ["app_id", "table_name", "deleted_at", "created_at", "record_id"])


def downgrade() -> None:
    op.drop_index("ix_vessel_app_records_table_page", table_name="vessel_app_records")
    op.drop_table("vessel_app_records")
    op.drop_index("ix_vessel_apps_space_status", table_name="vessel_apps")
    op.drop_table("vessel_apps")
    op.drop_index("ix_page_directories_space_status", table_name="page_directories")
    op.drop_index("ix_pages_space_status_updated", table_name="pages")
    op.drop_column("page_directories", "space_id")
    op.drop_column("pages", "space_id")
    for table in ("pages", "page_directories", "page_assets"):
        op.drop_constraint(f"{table}_owner_user_id_fkey", table, type_="foreignkey")
        op.create_foreign_key(
            f"{table}_owner_user_id_fkey", table, "users", ["owner_user_id"], ["user_id"], ondelete="CASCADE"
        )
