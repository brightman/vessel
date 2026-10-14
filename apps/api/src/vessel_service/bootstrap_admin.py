"""Create the first local/production administrator from an interactive prompt."""

import getpass
import re
import sys
from datetime import UTC, datetime
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.auth.passwords import hash_password
from vessel_service.database import create_database_engine
from vessel_service.models import User, UserCredential
from vessel_service.settings import Settings


def create_bootstrap_admin(
    session: Session, *, name: str, email: str, password: str
) -> User:
    normalized_email = email.strip().lower()
    normalized_name = name.strip()
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", normalized_email):
        raise ValueError("Enter a valid email address")
    if not normalized_name or len(normalized_name) > 120:
        raise ValueError("Administrator name must be between 1 and 120 characters")
    if len(password) < 8 or len(password) > 256:
        raise ValueError("Administrator password must be between 8 and 256 characters")
    if session.scalar(select(User.user_id).where(User.email == normalized_email)):
        raise ValueError("An account with this email already exists; refusing to replace it")

    user = User(
        user_id=str(uuid4()),
        email=normalized_email,
        name=normalized_name,
        roles=["admin"],
        status="active",
        created_at=datetime.now(UTC),
    )
    user.credential = UserCredential(password_hash=hash_password(password))
    session.add(user)
    try:
        session.commit()
    except IntegrityError as error:
        session.rollback()
        raise ValueError("An account with this email already exists") from error
    session.refresh(user)
    return user


def main() -> int:
    settings = Settings()
    if not settings.database_url:
        print("PAGES_DATABASE_URL must point to the Vessel database.", file=sys.stderr)
        return 2
    name = input("Administrator name: ")
    email = input("Administrator email: ")
    password = getpass.getpass("Administrator password: ")
    engine = create_database_engine(settings.database_url)
    sessions: sessionmaker[Session] = sessionmaker(bind=engine, expire_on_commit=False)
    try:
        with sessions() as session:
            user = create_bootstrap_admin(session, name=name, email=email, password=password)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except SQLAlchemyError:
        print("Could not create administrator. Check that migrations are applied and the database is available.", file=sys.stderr)
        return 1
    finally:
        engine.dispose()
    print(f"Created Pages administrator {user.email}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
