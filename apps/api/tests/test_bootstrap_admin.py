import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from pages_service.auth.passwords import verify_password
from pages_service.models import Base
from pages_service.bootstrap_admin import create_bootstrap_admin


def test_bootstrap_admin_creates_a_hashed_admin_account(tmp_path) -> None:
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'bootstrap.sqlite3'}")
    Base.metadata.create_all(engine)

    with Session(engine) as session:
        user = create_bootstrap_admin(
            session, name="Pages Admin", email=" ADMIN@EXAMPLE.TEST ", password="strong-local-pass"
        )

        assert user.email == "admin@example.test"
        assert user.roles == ["admin"]
        assert user.status == "active"
        assert user.credential.password_hash != "strong-local-pass"
        assert verify_password(user.credential.password_hash, "strong-local-pass")


def test_bootstrap_admin_refuses_to_replace_an_existing_account(tmp_path) -> None:
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'bootstrap.sqlite3'}")
    Base.metadata.create_all(engine)

    with Session(engine) as session:
        create_bootstrap_admin(
            session, name="Pages Admin", email="admin@example.test", password="strong-local-pass"
        )
        with pytest.raises(ValueError, match="already exists"):
            create_bootstrap_admin(
                session, name="Replacement", email="admin@example.test", password="other-pass-123"
            )
