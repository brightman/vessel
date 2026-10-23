"""Persist Note Agent Runs independently of MCP capabilities.

Revision ID: 0013_note_agent_runs
Revises: 0012_notes_rename
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB


revision = "0013_note_agent_runs"
down_revision = "0012_notes_rename"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "note_agent_runs",
        sa.Column("run_id", sa.String(128), primary_key=True),
        sa.Column("note_id", sa.String(36), sa.ForeignKey("notes.note_id", ondelete="CASCADE"), nullable=False),
        sa.Column("owner_user_id", sa.String(36), sa.ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False),
        sa.Column("mode", sa.String(8), nullable=False),
        sa.Column("base_revision", sa.Integer(), nullable=False),
        sa.Column("selection_json", sa.JSON().with_variant(JSONB(), "postgresql"), nullable=True),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("failure_code", sa.String(64), nullable=True),
        sa.Column("reply", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_note_agent_runs_note_id", "note_agent_runs", ["note_id"])
    op.create_index("ix_note_agent_runs_owner_user_id", "note_agent_runs", ["owner_user_id"])


def downgrade() -> None:
    op.drop_index("ix_note_agent_runs_owner_user_id", table_name="note_agent_runs")
    op.drop_index("ix_note_agent_runs_note_id", table_name="note_agent_runs")
    op.drop_table("note_agent_runs")
