"""Persistent registration challenges and shared email-send budgets."""
from datetime import datetime
from sqlalchemy import CheckConstraint, DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column
from vessel_service.models.base import Base

class RegistrationEmailChallenge(Base):
    __tablename__ = "registration_email_challenges"
    __table_args__ = (CheckConstraint("attempts >= 0 AND attempts <= 5", name="ck_registration_email_attempts"),)
    challenge_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    email: Mapped[str] = mapped_column(String(320), index=True)
    code_digest: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

class RegistrationEmailLimit(Base):
    __tablename__ = "registration_email_limits"
    bucket_key: Mapped[str] = mapped_column(String(160), primary_key=True)
    hits: Mapped[int] = mapped_column(Integer)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
