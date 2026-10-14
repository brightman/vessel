def register(api, email: str) -> tuple[str, str]:
    response = api(
        "POST",
        "/v1/auth/register",
        json={"name": email.split("@")[0], "email": email, "password": "vessel-test-2026"},
    )
    assert response.status_code == 201
    return response.json()["access_token"], response.json()["user"]["user_id"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def team(api, token: str, name: str = "Research") -> str:
    response = api("POST", "/v1/teams", headers=auth(token), json={"name": name})
    assert response.status_code == 201, response.text
    return response.json()["space"]["space_id"]


def invite(api, token: str, space_id: str, user_id: str, role: str) -> str:
    response = api(
        "POST", f"/v1/teams/{space_id}/invitations", headers=auth(token),
        json={"invitee_user_id": user_id, "role": role},
    )
    assert response.status_code == 201, response.text
    return response.json()["invitation"]["invitation_id"]


def test_registration_creates_one_personal_space_and_team_owner(api_factory) -> None:
    api = api_factory()
    token, user_id = register(api, "owner@example.test")

    before = api("GET", "/v1/spaces", headers=auth(token))
    assert before.status_code == 200
    assert len(before.json()["spaces"]) == 1
    personal = before.json()["spaces"][0]
    assert personal["kind"] == "personal"
    assert personal["owner_user_id"] == user_id
    assert personal["role"] == "owner"

    space_id = team(api, token)
    after = api("GET", "/v1/spaces", headers=auth(token))
    assert {space["space_id"] for space in after.json()["spaces"]} == {
        personal["space_id"], space_id,
    }
    permissions = api("GET", f"/v1/spaces/{space_id}/permissions", headers=auth(token))
    assert permissions.json()["role"] == "owner"
    assert permissions.json()["can_manage_members"] is True


def test_invitation_acceptance_and_roles(api_factory) -> None:
    api = api_factory()
    owner, _ = register(api, "owner@example.test")
    editor, editor_id = register(api, "editor@example.test")
    viewer, viewer_id = register(api, "viewer@example.test")
    space_id = team(api, owner)
    editor_invite = invite(api, owner, space_id, editor_id, "editor")
    viewer_invite = invite(api, owner, space_id, viewer_id, "viewer")

    pending = api("GET", "/v1/team-invitations", headers=auth(editor))
    assert [item["invitation_id"] for item in pending.json()["invitations"]] == [editor_invite]
    forbidden_accept = api("POST", f"/v1/team-invitations/{editor_invite}/accept", headers=auth(viewer))
    assert forbidden_accept.status_code == 404
    assert api("POST", f"/v1/team-invitations/{editor_invite}/accept", headers=auth(editor)).status_code == 200
    assert api("POST", f"/v1/team-invitations/{viewer_invite}/accept", headers=auth(viewer)).status_code == 200

    editor_permission = api("GET", f"/v1/spaces/{space_id}/permissions", headers=auth(editor)).json()
    viewer_permission = api("GET", f"/v1/spaces/{space_id}/permissions", headers=auth(viewer)).json()
    assert editor_permission["can_write"] is True
    assert editor_permission["can_manage_members"] is False
    assert viewer_permission["can_read"] is True
    assert viewer_permission["can_write"] is False
    assert {item["user_id"] for item in api("GET", f"/v1/teams/{space_id}/members", headers=auth(viewer)).json()["members"]} == {
        editor_id, viewer_id, api("GET", "/v1/auth/me", headers=auth(owner)).json()["user"]["user_id"],
    }
    denied = api("POST", f"/v1/teams/{space_id}/invitations", headers=auth(viewer), json={"invitee_user_id": editor_id, "role": "editor"})
    assert denied.status_code == 403


def test_nonmember_cannot_enumerate_team_or_accept_other_invite(api_factory) -> None:
    api = api_factory()
    owner, _ = register(api, "owner@example.test")
    outsider, outsider_id = register(api, "outside@example.test")
    space_id = team(api, owner)

    assert api("GET", f"/v1/spaces/{space_id}/permissions", headers=auth(outsider)).status_code == 404
    assert api("GET", f"/v1/teams/{space_id}/members", headers=auth(outsider)).status_code == 404
    assert space_id not in {item["space_id"] for item in api("GET", "/v1/spaces", headers=auth(outsider)).json()["spaces"]}
    assert api("POST", f"/v1/teams/{space_id}/invitations", headers=auth(outsider), json={"invitee_user_id": outsider_id, "role": "editor"}).status_code == 404


def test_admin_cannot_manage_owner_and_last_owner_is_protected(api_factory) -> None:
    api = api_factory()
    owner, owner_id = register(api, "owner@example.test")
    admin, admin_id = register(api, "admin@example.test")
    space_id = team(api, owner)
    invitation = invite(api, owner, space_id, admin_id, "admin")
    assert api("POST", f"/v1/team-invitations/{invitation}/accept", headers=auth(admin)).status_code == 200

    remove_owner = api("DELETE", f"/v1/teams/{space_id}/members/{owner_id}", headers=auth(admin))
    assert remove_owner.status_code == 403
    downgrade_owner = api("PATCH", f"/v1/teams/{space_id}/members/{owner_id}", headers=auth(owner), json={"role": "viewer"})
    assert downgrade_owner.status_code == 409
    promote_admin = api("PATCH", f"/v1/teams/{space_id}/members/{admin_id}", headers=auth(admin), json={"role": "owner"})
    assert promote_admin.status_code == 403


def test_member_removal_revokes_access_and_duplicate_invite_conflicts(api_factory) -> None:
    api = api_factory()
    owner, _ = register(api, "owner@example.test")
    editor, editor_id = register(api, "editor@example.test")
    space_id = team(api, owner)
    invitation = invite(api, owner, space_id, editor_id, "editor")
    duplicate = api("POST", f"/v1/teams/{space_id}/invitations", headers=auth(owner), json={"invitee_user_id": editor_id, "role": "editor"})
    assert duplicate.status_code == 409
    assert api("POST", f"/v1/team-invitations/{invitation}/accept", headers=auth(editor)).status_code == 200
    removed = api("DELETE", f"/v1/teams/{space_id}/members/{editor_id}", headers=auth(owner))
    assert removed.status_code == 204
    assert api("GET", f"/v1/spaces/{space_id}/permissions", headers=auth(editor)).status_code == 404
    assert space_id not in {item["space_id"] for item in api("GET", "/v1/spaces", headers=auth(editor)).json()["spaces"]}


def test_team_manager_can_revoke_pending_invitation(api_factory) -> None:
    api = api_factory()
    owner, _ = register(api, "owner@example.test")
    viewer, viewer_id = register(api, "viewer@example.test")
    space_id = team(api, owner)
    invitation_id = invite(api, owner, space_id, viewer_id, "viewer")

    listed = api("GET", f"/v1/teams/{space_id}/invitations", headers=auth(owner))
    assert listed.status_code == 200
    assert [item["invitation_id"] for item in listed.json()["invitations"]] == [invitation_id]
    assert api("GET", f"/v1/teams/{space_id}/invitations", headers=auth(viewer)).status_code == 404

    revoked = api(
        "DELETE", f"/v1/teams/{space_id}/invitations/{invitation_id}", headers=auth(owner)
    )
    assert revoked.status_code == 204
    assert api("POST", f"/v1/team-invitations/{invitation_id}/accept", headers=auth(viewer)).status_code == 409
    assert api("GET", "/v1/team-invitations", headers=auth(viewer)).json()["invitations"] == []
    assert invite(api, owner, space_id, viewer_id, "editor") != invitation_id
from sqlalchemy import create_engine, text




def test_disabled_owner_does_not_count_for_last_owner_protection(api_factory, tmp_path) -> None:
    api = api_factory()
    owner, owner_id = register(api, "owner@example.test")
    second, second_id = register(api, "second@example.test")
    space_id = team(api, owner)
    invitation_id = invite(api, owner, space_id, second_id, "owner")
    assert api("POST", f"/v1/team-invitations/{invitation_id}/accept", headers=auth(second)).status_code == 200

    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'pages-test.sqlite3'}")
    with engine.begin() as connection:
        connection.execute(
            text("UPDATE users SET status = 'disabled' WHERE user_id = :user_id"),
            {"user_id": second_id},
        )
    engine.dispose()

    assert api("GET", "/v1/auth/me", headers=auth(second)).status_code == 401
    downgrade = api(
        "PATCH", f"/v1/teams/{space_id}/members/{owner_id}",
        headers=auth(owner), json={"role": "editor"},
    )
    remove = api("DELETE", f"/v1/teams/{space_id}/members/{owner_id}", headers=auth(owner))
    assert downgrade.status_code == 409
    assert remove.status_code == 409
    remove_disabled = api(
        "DELETE", f"/v1/teams/{space_id}/members/{second_id}", headers=auth(owner)
    )
    assert remove_disabled.status_code == 204
