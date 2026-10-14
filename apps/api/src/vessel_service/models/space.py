from datetime import UTC, datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, String, text
from sqlalchemy.orm import Mapped, mapped_column

from vessel_service.models.base import Base


class Space(Base):
    __tablename__ = "spaces"
    __table_args__ = (
        CheckConstraint("kind IN ('personal', 'team')", name="ck_spaces_kind"),
        CheckConstraint(
            "(kind = 'personal' AND owner_user_id IS NOT NULL) OR "
            "(kind = 'team' AND owner_user_id IS NULL)",
            name="ck_spaces_owner_kind",
        ),
        Index(
            "uq_spaces_personal_owner",
            "owner_user_id",
            unique=True,
            postgresql_where=text("kind = 'personal'"),
            sqlite_where=text("kind = 'personal'"),
        ),
    )

    space_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    kind: Mapped[str] = mapped_column(String(16))
    name: Mapped[str] = mapped_column(String(120))
    owner_user_id: Mapped[str | None] = mapped_column(
        ForeignKey("users.user_id", ondelete="CASCADE"), nullable=True, index=True
    )
    created_by_user_id: Mapped[str | None] = mapped_column(
        ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16), default="active")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC)
    )


class TeamMember(Base):
    __tablename__ = "team_members"
    __table_args__ = (
        CheckConstraint("role IN ('owner', 'admin', 'editor', 'viewer')", name="ck_team_members_role"),
        CheckConstraint("status IN ('active', 'removed')", name="ck_team_members_status"),
        Index("ix_team_members_user_status", "user_id", "status"),
    )

    space_id: Mapped[str] = mapped_column(
        ForeignKey("spaces.space_id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.user_id", ondelete="RESTRICT"), primary_key=True
    )
    role: Mapped[str] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16), default="active")
    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), onupdate=lambda: datetime.now(UTC)
    )


class TeamInvitation(Base):
    __tablename__ = "team_invitations"
    __table_args__ = (
        CheckConstraint("role IN ('owner', 'admin', 'editor', 'viewer')", name="ck_team_invitations_role"),
        CheckConstraint(
            "status IN ('pending', 'accepted', 'revoked', 'expired')",
            name="ck_team_invitations_status",
        ),
        Index(
            "uq_team_invitations_pending",
            "space_id", "invitee_user_id", unique=True,
            postgresql_where=text("status = 'pending'"),
            sqlite_where=text("status = 'pending'"),
        ),
        Index("ix_team_invitations_invitee_status_expiry", "invitee_user_id", "status", "expires_at"),
    )

    invitation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(ForeignKey("spaces.space_id", ondelete="CASCADE"))
    invitee_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id", ondelete="CASCADE"))
    invited_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.user_id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16), default="pending")
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
