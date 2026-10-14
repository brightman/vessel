import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from vessel_service.auth.passwords import verify_password
from vessel_service.models import Base, Space
from vessel_service.bootstrap_admin import create_bootstrap_admin, create_local_user


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


def test_local_operator_can_provision_normal_user_with_personal_space(tmp_path) -> None:
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'provision.sqlite3'}")
    Base.metadata.create_all(engine)

    with Session(engine) as session:
        user = create_local_user(
            session, name="Team Member", email="MEMBER@EXAMPLE.TEST",
            password="strong-local-pass", platform_role="user",
        )
        spaces = session.query(Space).filter_by(owner_user_id=user.user_id).all()

    assert user.email == "member@example.test"
    assert user.roles == ["user"]
    assert len(spaces) == 1
    assert spaces[0].kind == "personal"
