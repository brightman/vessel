import pytest
from fastapi import HTTPException
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from vessel_service.files.metadata import FileMetadata
from vessel_service.models import Space, TeamMember, User
from vessel_service.models.base import Base


@pytest.fixture
def env():
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        a = User(user_id="a", email="a@test", name="a")
        b = User(user_id="b", email="b@test", name="b")
        s.add_all([a, b])
        s.flush()
        s.add(
            Space(
                space_id="s",
                kind="personal",
                name="s",
                owner_user_id="a",
                created_by_user_id="a",
            )
        )
        s.flush()
        yield s, a, b


def code(exc, c):
    assert exc.value.detail["code"] == c


def test_private_root_and_nested_revocation(env):
    s, a, b = env
    owner = FileMetadata(s, a)
    guest = FileMetadata(s, b)
    root = owner.root("s")
    folder = owner.create_folder(
        "s", dict(name="Folder", parent_folder_id=root["item_id"])
    )
    child = owner.create_folder(
        "s", dict(name="Child", parent_folder_id=folder["item_id"])
    )
    with pytest.raises(HTTPException) as exc:
        guest.get(child["item_id"])
    code(exc, "FILE_ITEM_NOT_FOUND")
    grant = owner.add_grant(
        folder["item_id"],
        dict(grantee_user_id="b", role="editor", expected_acl_revision=1),
    )
    assert guest.permissions(child["item_id"])["can_write"]
    assert not guest.permissions(child["item_id"])["can_move"]
    with pytest.raises(HTTPException):
        guest.root("s")
    owner.revoke_grant(
        folder["item_id"], grant["grant"]["grant_id"], dict(expected_acl_revision=2)
    )
    with pytest.raises(HTTPException):
        guest.get(child["item_id"])


def test_name_move_and_batch_restore(env):
    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    f = svc.create_folder("s", dict(name="F", parent_folder_id=root["item_id"]))
    c = svc.create_folder("s", dict(name="C", parent_folder_id=f["item_id"]))
    with pytest.raises(HTTPException):
        svc.create_folder("s", dict(name="f", parent_folder_id=root["item_id"]))
    with pytest.raises(HTTPException):
        svc.prepare_move(
            f["item_id"],
            dict(target_parent_folder_id=c["item_id"], expected_metadata_version=1),
        )
    child_batch = svc.trash(c["item_id"], dict(expected_metadata_version=1))
    batch = svc.trash(f["item_id"], dict(expected_metadata_version=1))
    preview = svc.prepare_restore(batch["batch_id"], {})
    svc.commit_restore(
        batch["batch_id"],
        dict(
            preview_id=preview["preview_id"],
            preview_hash=preview["preview_hash"],
            expected_acl_revision=preview["expected_acl_revision"],
        ),
    )
    assert svc.get(f["item_id"])["status"] == "active"
    with pytest.raises(HTTPException):
        svc.get(c["item_id"])


def test_team_viewer_and_current_membership(env):
    s, a, b = env
    s.add(Space(space_id="t", kind="team", name="T", created_by_user_id="a"))
    s.add_all(
        [
            TeamMember(space_id="t", user_id="a", role="owner"),
            TeamMember(space_id="t", user_id="b", role="viewer"),
        ]
    )
    s.flush()
    root = FileMetadata(s, a).root("t")
    guest = FileMetadata(s, b)
    assert guest.get(root["item_id"])
    with pytest.raises(HTTPException) as exc:
        guest.create_folder("t", dict(name="x", parent_folder_id=root["item_id"]))
    assert exc.value.status_code == 403
    s.get(TeamMember, ("t", "b")).status = "removed"
    s.flush()
    with pytest.raises(HTTPException):
        guest.get(root["item_id"])


def test_additive_sharing_search_and_cursor(env):
    s, a, b = env
    owner = FileMetadata(s, a)
    guest = FileMetadata(s, b)
    root = owner.root("s")
    folder = owner.create_folder(
        "s", dict(name="Shared", parent_folder_id=root["item_id"])
    )
    first = owner.create_folder(
        "s", dict(name="First", parent_folder_id=folder["item_id"])
    )
    second = owner.create_folder(
        "s", dict(name="Second", parent_folder_id=folder["item_id"])
    )
    direct = owner.add_grant(
        first["item_id"],
        dict(grantee_user_id="b", role="viewer", expected_acl_revision=1),
    )
    inherited = owner.add_grant(
        folder["item_id"],
        dict(grantee_user_id="b", role="editor", expected_acl_revision=2),
    )
    assert guest.permissions(first["item_id"])["can_write"]
    assert len(guest.shared_with_me()["items"]) == 1
    page = guest.list_children(folder["item_id"], limit=1)
    assert page["next_cursor"]
    assert (
        guest.list_children(folder["item_id"], limit=1, cursor=page["next_cursor"])[
            "items"
        ][0]["item_id"]
        == second["item_id"]
    )
    with pytest.raises(HTTPException) as exc:
        guest.list_children(
            folder["item_id"], limit=1, cursor=page["next_cursor"] + "x"
        )
    code(exc, "CURSOR_INVALID")
    owner.revoke_grant(
        folder["item_id"], inherited["grant"]["grant_id"], dict(expected_acl_revision=3)
    )
    assert not guest.permissions(first["item_id"])["can_write"]
    assert [i["item_id"] for i in guest.search("s", dict(kind="folder"))["items"]] == [
        first["item_id"]
    ]


def test_cross_space_parent_and_stale_move_preview(env):
    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    s.add(
        Space(
            space_id="other",
            kind="personal",
            name="other",
            owner_user_id="b",
            created_by_user_id="b",
        )
    )
    s.flush()
    other = FileMetadata(s, b).root("other")
    with pytest.raises(HTTPException) as exc:
        svc.create_folder("s", dict(name="bad", parent_folder_id=other["item_id"]))
    code(exc, "FOLDER_NOT_FOUND")
    source = svc.create_folder(
        "s", dict(name="source", parent_folder_id=root["item_id"])
    )
    target = svc.create_folder(
        "s", dict(name="target", parent_folder_id=root["item_id"])
    )
    p = svc.prepare_move(
        source["item_id"],
        dict(target_parent_folder_id=target["item_id"], expected_metadata_version=1),
    )
    svc.add_grant(
        target["item_id"],
        dict(grantee_user_id="b", role="viewer", expected_acl_revision=1),
    )
    with pytest.raises(HTTPException) as exc:
        svc.commit_move(
            source["item_id"],
            dict(
                preview_id=p["preview_id"],
                preview_hash=p["preview_hash"],
                expected_acl_revision=1,
                expected_metadata_version=1,
            ),
        )
    code(exc, "FILE_OPERATION_PREVIEW_CONFLICT")


def test_root_mutations_name_validation_and_depth(env):
    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    with pytest.raises(HTTPException):
        svc.rename(root["item_id"], dict(name="x", expected_metadata_version=1))
    with pytest.raises(HTTPException):
        svc.trash(root["item_id"], dict(expected_metadata_version=1))
    for name in ("..", "a/b", "a\\b", " ", "x\x00"):
        with pytest.raises(HTTPException) as exc:
            svc.create_folder("s", dict(name=name, parent_folder_id=root["item_id"]))
        code(exc, "FILE_NAME_INVALID")
    parent = root
    for i in range(32):
        parent = svc.create_folder(
            "s", dict(name=str(i), parent_folder_id=parent["item_id"])
        )
    with pytest.raises(HTTPException):
        svc.create_folder(
            "s", dict(name="too deep", parent_folder_id=parent["item_id"])
        )


def test_expiring_grants_move_and_restore_previews_are_json_safe(env):
    from datetime import UTC, datetime, timedelta

    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    source = svc.create_folder(
        "s", dict(name="source", parent_folder_id=root["item_id"])
    )
    target = svc.create_folder(
        "s", dict(name="target", parent_folder_id=root["item_id"])
    )
    svc.add_grant(
        target["item_id"],
        dict(
            grantee_user_id="b",
            role="viewer",
            expires_at=datetime.now(UTC) + timedelta(days=1),
            expected_acl_revision=1,
        ),
    )
    preview = svc.prepare_move(
        source["item_id"],
        dict(target_parent_folder_id=target["item_id"], expected_metadata_version=1),
    )
    assert preview["permission_changes"]["gained"][0]["expires_at"]
    moved = svc.commit_move(
        source["item_id"],
        dict(
            preview_id=preview["preview_id"],
            preview_hash=preview["preview_hash"],
            expected_metadata_version=1,
            expected_acl_revision=2,
        ),
    )
    batch = svc.trash(
        source["item_id"], dict(expected_metadata_version=moved["metadata_version"])
    )
    preview = svc.prepare_restore(batch["batch_id"], {})
    assert preview["permission_changes"]["gained"]


def test_inherited_grant_cannot_be_edited_at_child_and_expiry(env):
    from datetime import UTC, datetime, timedelta

    from vessel_service.files.models import DriveGrant

    s, a, b = env
    owner = FileMetadata(s, a)
    guest = FileMetadata(s, b)
    root = owner.root("s")
    folder = owner.create_folder("s", dict(name="f", parent_folder_id=root["item_id"]))
    child = owner.create_folder("s", dict(name="c", parent_folder_id=folder["item_id"]))
    grant = owner.add_grant(
        folder["item_id"],
        dict(grantee_user_id="b", role="editor", expected_acl_revision=1),
    )
    with pytest.raises(HTTPException) as exc:
        owner.revoke_grant(
            child["item_id"], grant["grant"]["grant_id"], dict(expected_acl_revision=2)
        )
    code(exc, "INHERITED_PERMISSION")
    s.get(DriveGrant, grant["grant"]["grant_id"]).expires_at = datetime.now(
        UTC
    ) - timedelta(seconds=1)
    s.flush()
    with pytest.raises(HTTPException):
        guest.get(child["item_id"])
    assert not guest.shared_with_me()["items"]


def test_move_preserves_direct_grant_and_removes_inherited_source(env):
    s, a, b = env
    owner = FileMetadata(s, a)
    guest = FileMetadata(s, b)
    root = owner.root("s")
    folder = owner.create_folder("s", dict(name="f", parent_folder_id=root["item_id"]))
    child = owner.create_folder("s", dict(name="c", parent_folder_id=folder["item_id"]))
    owner.add_grant(
        folder["item_id"],
        dict(grantee_user_id="b", role="editor", expected_acl_revision=1),
    )
    owner.add_grant(
        child["item_id"],
        dict(grantee_user_id="b", role="viewer", expected_acl_revision=2),
    )
    preview = owner.prepare_move(
        child["item_id"],
        dict(target_parent_folder_id=root["item_id"], expected_metadata_version=1),
    )
    assert len(preview["permission_changes"]["lost"]) == 1
    owner.commit_move(
        child["item_id"],
        dict(
            preview_id=preview["preview_id"],
            preview_hash=preview["preview_hash"],
            expected_metadata_version=1,
            expected_acl_revision=3,
        ),
    )
    caps = guest.permissions(child["item_id"])
    assert caps["can_read"] and not caps["can_write"]
    with pytest.raises(HTTPException):
        guest.get(root["item_id"])


def test_restore_conflict_requires_explicit_target_name(env):
    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    old = svc.create_folder("s", dict(name="same", parent_folder_id=root["item_id"]))
    batch = svc.trash(old["item_id"], dict(expected_metadata_version=1))
    svc.create_folder("s", dict(name="same", parent_folder_id=root["item_id"]))
    with pytest.raises(HTTPException) as exc:
        svc.prepare_restore(batch["batch_id"], {})
    code(exc, "ITEM_NAME_CONFLICT")
    preview = svc.prepare_restore(batch["batch_id"], dict(name="restored"))
    result = svc.commit_restore(
        batch["batch_id"],
        dict(
            preview_id=preview["preview_id"],
            preview_hash=preview["preview_hash"],
            expected_acl_revision=2,
        ),
    )
    assert result["item"]["name"] == "restored"


def test_restore_depth_excludes_previously_trashed_descendant(env):
    s, a, b = env
    svc = FileMetadata(s, a)
    root = svc.root("s")
    source = svc.create_folder(
        "s", dict(name="source", parent_folder_id=root["item_id"])
    )
    excluded = svc.create_folder(
        "s", dict(name="excluded", parent_folder_id=source["item_id"])
    )
    svc.create_folder("s", dict(name="deep", parent_folder_id=excluded["item_id"]))
    svc.trash(excluded["item_id"], dict(expected_metadata_version=1))
    batch = svc.trash(source["item_id"], dict(expected_metadata_version=1))
    target = root
    for i in range(31):
        target = svc.create_folder(
            "s", dict(name="target" + str(i), parent_folder_id=target["item_id"])
        )
    preview = svc.prepare_restore(
        batch["batch_id"], dict(target_parent_folder_id=target["item_id"])
    )
    result = svc.commit_restore(
        batch["batch_id"],
        dict(
            preview_id=preview["preview_id"],
            preview_hash=preview["preview_hash"],
            expected_acl_revision=3,
        ),
    )
    assert result["item"]["status"] == "active"
    with pytest.raises(HTTPException):
        svc.get(excluded["item_id"])


def test_disabled_actor_and_audit_request_id(env):
    from sqlalchemy import update
    from vessel_service.files.models import DriveAuditEvent

    s, a, b = env
    svc = FileMetadata(s, a, request_id="request-test")
    root = svc.root("s")
    item = svc.create_folder(
        "s", dict(name="audited", parent_folder_id=root["item_id"])
    )
    event = s.query(DriveAuditEvent).filter_by(item_id=item["item_id"]).one()
    assert event.request_id == "request-test"
    s.execute(
        update(User)
        .where(User.user_id == "a")
        .values(status="disabled")
        .execution_options(synchronize_session=False)
    )
    with pytest.raises(HTTPException):
        svc.get(item["item_id"])
