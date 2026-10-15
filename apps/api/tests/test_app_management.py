"""Contracts for Vessel App settings, releases, and audit metadata."""


def test_app_management_schema_has_independent_settings_and_release_versions():
    import vessel_service.models as models

    assert "settings_version" in models.VesselApp.__table__.c
    assert "description" in models.VesselApp.__table__.c
    assert "archived_at" in models.VesselApp.__table__.c
    assert hasattr(models, "VesselAppRelease")
    assert hasattr(models, "VesselAppAuditEvent")


def _account(api, name):
    response = api("POST", "/v1/auth/register", json={
        "name": name, "email": f"{name}@example.test", "password": "vessel-test-2026",
    })
    assert response.status_code == 201, response.text
    body = response.json()
    return body["access_token"], body["user"]["user_id"]


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _managed_team_app(api_factory):
    api = api_factory()
    owner, _ = _account(api, "management-owner")
    admin, admin_id = _account(api, "management-admin")
    editor, _ = _account(api, "management-editor")
    viewer, _ = _account(api, "management-viewer")
    team = api("POST", "/v1/teams", headers=_headers(owner), json={"name": "Managed Apps"})
    assert team.status_code == 201, team.text
    space_id = team.json()["space"]["space_id"]
    for token, user_id, role in ((admin, admin_id, "admin"),):
        invited = api("POST", f"/v1/teams/{space_id}/invitations", headers=_headers(owner), json={
            "invitee_user_id": user_id, "role": role,
        })
        assert invited.status_code == 201, invited.text
        accepted = api("POST", f"/v1/team-invitations/{invited.json()['invitation']['invitation_id']}/accept", headers=_headers(token))
        assert accepted.status_code == 200, accepted.text
    for token, name, role in ((editor, "management-editor", "editor"), (viewer, "management-viewer", "viewer")):
        user_id = api("GET", "/v1/auth/me", headers=_headers(token)).json()["user"]["user_id"]
        invited = api("POST", f"/v1/teams/{space_id}/invitations", headers=_headers(owner), json={
            "invitee_user_id": user_id, "role": role,
        })
        assert invited.status_code == 201, invited.text
        accepted = api("POST", f"/v1/team-invitations/{invited.json()['invitation']['invitation_id']}/accept", headers=_headers(token))
        assert accepted.status_code == 200, accepted.text
    created = api("POST", f"/v1/spaces/{space_id}/apps", headers=_headers(owner), json={
        "name": "Roadmap", "manifest": {"tables": {"items": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    })
    assert created.status_code == 201, created.text
    return api, created.json()["app"]["app_id"], _headers(owner), _headers(admin), _headers(editor), _headers(viewer)


def test_only_owner_or_admin_can_change_app_settings_or_manifest(api_factory):
    api, app_id, owner_headers, admin_headers, editor_headers, viewer_headers = _managed_team_app(api_factory)

    denied = api("PATCH", f"/v1/apps/{app_id}", headers=editor_headers, json={
        "expected_settings_version": 1, "name": "Edited by editor",
    })
    assert denied.status_code == 403
    assert denied.json()["detail"]["code"] == "APP_MANAGER_REQUIRED"

    changed = api("PATCH", f"/v1/apps/{app_id}", headers=owner_headers, json={
        "expected_settings_version": 1, "name": "Roadmap", "description": "Quarterly priorities",
    })
    assert changed.status_code == 200, changed.text
    assert changed.json()["app"]["description"] == "Quarterly priorities"
    assert changed.json()["app"]["settings_version"] == 2

    stale = api("POST", f"/v1/apps/{app_id}/archive", headers=admin_headers, json={"expected_settings_version": 1})
    assert stale.status_code == 409
    assert stale.json()["detail"]["code"] == "APP_SETTINGS_VERSION_CONFLICT"

    manifest = {"tables": {"items": {"fields": {
        "title": {"type": "text", "nullable": False},
        "summary": {"type": "text", "nullable": True},
    }}}}
    assert api("PUT", f"/v1/apps/{app_id}/manifest", headers=viewer_headers, json={
        "expected_version": 1, "manifest": manifest,
    }).json()["detail"]["code"] == "APP_MANAGER_REQUIRED"
    allowed = api("PUT", f"/v1/apps/{app_id}/manifest", headers=admin_headers, json={
        "expected_version": 1, "manifest": manifest,
    })
    assert allowed.status_code == 200, allowed.text

    archived = api("POST", f"/v1/apps/{app_id}/archive", headers=admin_headers, json={"expected_settings_version": 2})
    assert archived.status_code == 200, archived.text
    assert archived.json()["app"]["status"] == "archived"
    assert api("GET", f"/v1/apps/{app_id}", headers=editor_headers).status_code == 404
    restored = api("POST", f"/v1/apps/{app_id}/restore", headers=owner_headers, json={"expected_settings_version": 3})
    assert restored.status_code == 200, restored.text
    assert restored.json()["app"]["status"] == "active"


def test_app_audit_events_are_keyset_paged_and_manager_only(api_factory):
    api, app_id, owner_headers, _, _, viewer_headers = _managed_team_app(api_factory)
    changed = api("PATCH", f"/v1/apps/{app_id}", headers=owner_headers, json={
        "expected_settings_version": 1, "description": "Audit this mutation",
    })
    assert changed.status_code == 200
    archived = api("POST", f"/v1/apps/{app_id}/archive", headers=owner_headers, json={
        "expected_settings_version": 2,
    })
    assert archived.status_code == 200

    visible = api("GET", f"/v1/apps/{app_id}/audit-events?limit=1", headers=owner_headers)
    assert visible.status_code == 200, visible.text
    assert visible.json()["events"][0]["action"] == "app.archived"
    assert visible.json()["next_cursor"]

    next_page = api("GET", f"/v1/apps/{app_id}/audit-events", headers=owner_headers, params={
        "limit": 1, "cursor": visible.json()["next_cursor"],
    })
    assert next_page.status_code == 200, next_page.text
    assert next_page.json()["events"][0]["action"] == "app.updated"
    assert next_page.json()["next_cursor"] is None

    malformed = api("GET", f"/v1/apps/{app_id}/audit-events", headers=owner_headers, params={"cursor": "not-a-cursor"})
    assert malformed.status_code == 422
    assert malformed.json()["detail"]["code"] == "APP_CURSOR_INVALID"

    denied = api("GET", f"/v1/apps/{app_id}/audit-events", headers=viewer_headers)
    assert denied.status_code == 403
    assert denied.json()["detail"]["code"] == "APP_MANAGER_REQUIRED"
