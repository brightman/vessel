"""Persist typed Agent replies and clarification continuations."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB
revision = "0014_note_agent_responses"
down_revision = "0013_note_agent_runs"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("note_agent_runs", sa.Column("response_json", sa.JSON().with_variant(JSONB(), "postgresql"), nullable=True))
    op.add_column("note_agent_runs", sa.Column("prompt", sa.Text(), nullable=True))
    op.add_column("note_agent_runs", sa.Column("reply_to_run_id", sa.String(128), nullable=True))
    op.add_column("note_agent_runs", sa.Column("option_id", sa.String(128), nullable=True))
    op.add_column("note_agent_runs", sa.Column("answered_by_run_id", sa.String(128), nullable=True))

def downgrade():
    for name in ("answered_by_run_id", "option_id", "reply_to_run_id", "prompt", "response_json"):
        op.drop_column("note_agent_runs", name)
