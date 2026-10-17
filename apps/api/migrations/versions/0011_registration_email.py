"""Pre-registration email verification and shared send limits.

Revision ID: 0011_registration_email
Revises: 0010_app_management_publishing
"""
from alembic import op
import sqlalchemy as sa
revision = "0011_registration_email"
down_revision = "0010_app_management_publishing"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("users", sa.Column("email_verified_at", sa.DateTime(timezone=True), nullable=True))
    op.create_table("registration_email_challenges",
        sa.Column("challenge_id", sa.String(36), primary_key=True),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("code_digest", sa.String(64), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("attempts >= 0 AND attempts <= 5", name="ck_registration_email_attempts"))
    op.create_index("ix_registration_email_challenges_email", "registration_email_challenges", ["email"])
    op.create_index("ix_registration_email_challenges_expires_at", "registration_email_challenges", ["expires_at"])
    op.create_table("registration_email_limits",
        sa.Column("bucket_key", sa.String(160), primary_key=True),
        sa.Column("hits", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_registration_email_limits_expires_at", "registration_email_limits", ["expires_at"])

def downgrade():
    op.drop_table("registration_email_limits")
    op.drop_table("registration_email_challenges")
    op.drop_column("users", "email_verified_at")
