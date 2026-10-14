"""Cross-account behavior for Pages and Apps in personal and team spaces."""

import jwt


def _account(api, name):
    response = api("POST", "/v1/auth/register", json={
        "name": name, "email": f"{name}@example.test", "password": "vessel-test-2026",
    })
    assert response.status_code == 201, response.text
    return response.json()["access_token"], response.json()["user"]["user_id"]


def test_access_token_uses_vessel_scope(api_factory):
    token, _ = _account(api_factory(), "scope_owner")
    claims = jwt.decode(token, options={"verify_signature": False})
    assert claims["aud"] == "vessel-api"
    assert claims["scope"] == "vessel:session"


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _document(text="Team note"):
    return {"type": "doc", "schema_version": 1, "content": [{
        "type": "paragraph", "attrs": {"block_id": "first"},
        "content": [{"type": "text", "text": text}],
    }]}


def _team_with_members(api):
    owner, owner_id = _account(api, "owner")
    editor, editor_id = _account(api, "editor")
    viewer, viewer_id = _account(api, "viewer")
    outsider, _ = _account(api, "outsider")
    response = api("POST", "/v1/teams", headers=_headers(owner), json={"name": "Shared"})
    assert response.status_code == 201
    space_id = response.json()["space"]["space_id"]
    for token, user_id, role in ((editor, editor_id, "editor"), (viewer, viewer_id, "viewer")):
        invitation = api("POST", f"/v1/teams/{space_id}/invitations", headers=_headers(owner), json={
            "invitee_user_id": user_id, "role": role,
        })
        assert invitation.status_code == 201
        accepted = api("POST", f"/v1/team-invitations/{invitation.json()['invitation']['invitation_id']}/accept", headers=_headers(token))
        assert accepted.status_code == 200
    return space_id, (owner, owner_id), (editor, editor_id), (viewer, viewer_id), outsider


def test_team_pages_are_visible_by_role_and_revocation_is_immediate(api_factory):
    api = api_factory()
    space_id, (owner, _), (editor, editor_id), (viewer, _), outsider = _team_with_members(api)
    created = api("POST", f"/v1/spaces/{space_id}/pages", headers=_headers(owner), json={
        "title": "Shared note", "document": _document(),
    })
    assert created.status_code == 201, created.text
    page = created.json()["page"]
    assert page["space_id"] == space_id
    path = f"/v1/pages/{page['page_id']}"
    assert api("GET", path, headers=_headers(editor)).status_code == 200
    assert api("GET", path, headers=_headers(viewer)).status_code == 200
    assert api("GET", path, headers=_headers(outsider)).status_code == 404
    assert api("GET", f"/v1/spaces/{space_id}/pages", headers=_headers(outsider)).status_code == 404
    assert api("GET", "/v1/pages", headers=_headers(owner)).json()["pages"] == []
    assert api("PATCH", path, headers=_headers(viewer), json={"expected_revision": 1, "title": "Denied"}).status_code == 403
    updated = api("PATCH", path, headers=_headers(editor), json={"expected_revision": 1, "title": "Edited"})
    assert updated.status_code == 200
    assert updated.json()["page"]["title"] == "Edited"
    checkpoint = api("POST", f"{path}/versions/checkpoint", headers=_headers(editor), json={"expected_revision": 2})
    assert checkpoint.status_code == 201
    versions = api("GET", f"{path}/versions", headers=_headers(viewer))
    assert [version["revision"] for version in versions.json()["versions"]] == [2, 1]
    assert versions.json()["versions"][0]["actor_user_id"] == editor_id
    assert api("DELETE", f"/v1/teams/{space_id}/members/{editor_id}", headers=_headers(owner)).status_code == 204
    assert api("GET", path, headers=_headers(editor)).status_code == 404
    assert api("PATCH", path, headers=_headers(editor), json={"expected_revision": 2, "title": "Denied"}).status_code == 404


def test_team_page_directory_and_version_cannot_cross_space(api_factory):
    api = api_factory()
    space_id, (owner, _), (editor, _), (viewer, _), _ = _team_with_members(api)
    directory = api("POST", f"/v1/spaces/{space_id}/directories", headers=_headers(editor), json={"name": "Notes"})
    assert directory.status_code == 201, directory.text
    directory_id = directory.json()["directory"]["directory_id"]
    page = api("POST", f"/v1/spaces/{space_id}/pages", headers=_headers(owner), json={
        "title": "Shared", "directory_id": directory_id, "document": _document(),
    })
    assert page.status_code == 201
    page_id = page.json()["page"]["page_id"]
    assert api("GET", f"/v1/pages/{page_id}/versions", headers=_headers(viewer)).status_code == 200
    assert api("POST", f"/v1/pages/{page_id}/versions/checkpoint", headers=_headers(viewer), json={"expected_revision": 1}).status_code == 403
    assert api("POST", "/v1/pages", headers=_headers(owner), json={
        "title": "Private", "directory_id": directory_id, "document": _document(),
    }).status_code == 404
    assert api("GET", f"/v1/directories/{directory_id}", headers=_headers(viewer)).status_code == 200


def test_team_page_asset_is_shared_and_revoked(api_factory):
    from vessel_service.models import Page, PageAsset, PageDirectory

    for model in (Page, PageDirectory, PageAsset):
        foreign_key = next(iter(model.__table__.c.owner_user_id.foreign_keys))
        assert foreign_key.ondelete == "RESTRICT"
    api = api_factory()
    space_id, (owner, _), (editor, editor_id), (viewer, _), outsider = _team_with_members(api)
    page = api("POST", f"/v1/spaces/{space_id}/pages", headers=_headers(owner),
               json={"title": "Image", "document": _document()}).json()["page"]
    upload = api("POST", f"/v1/pages/{page['page_id']}/assets", headers={**_headers(editor), "Content-Type": "image/png"},
                 content=b"\x89PNG\r\n\x1a\n" + b"image-content")
    assert upload.status_code == 201, upload.text
    content_url = upload.json()["asset"]["content_url"]
    assert api("GET", content_url, headers=_headers(viewer)).status_code == 200
    assert api("GET", content_url, headers=_headers(outsider)).status_code == 404
    assert api("DELETE", f"/v1/teams/{space_id}/members/{editor_id}", headers=_headers(owner)).status_code == 204
    assert api("GET", content_url, headers=_headers(editor)).status_code == 404


def test_apps_manifest_records_and_roles(api_factory):
    api = api_factory()
    space_id, (owner, _), (editor, editor_id), (viewer, _), outsider = _team_with_members(api)
    manifest = {"tables": {"leads": {"fields": {
        "company": {"type": "text", "nullable": False},
        "score": {"type": "integer", "nullable": True},
    }}}}
    created = api("POST", f"/v1/spaces/{space_id}/apps", headers=_headers(owner), json={
        "name": "CRM", "manifest": manifest,
    })
    assert created.status_code == 201, created.text
    app_id = created.json()["app"]["app_id"]
    prefix = f"/v1/apps/{app_id}/tables/leads/records"
    assert api("GET", f"/v1/apps/{app_id}", headers=_headers(viewer)).status_code == 200
    assert api("GET", f"/v1/apps/{app_id}", headers=_headers(outsider)).status_code == 404
    assert api("POST", prefix, headers=_headers(viewer), json={"values": {"company": "Denied"}}).status_code == 403
    record = api("POST", prefix, headers=_headers(editor), json={"values": {"company": "Acme", "score": 7}})
    assert record.status_code == 201, record.text
    row = record.json()["record"]
    assert row["created_by"] == editor_id
    assert row["row_version"] == 1
    assert api("GET", f"{prefix}/{row['id']}", headers=_headers(viewer)).json()["record"]["values"]["company"] == "Acme"
    assert api("PATCH", f"{prefix}/{row['id']}", headers=_headers(viewer), json={"expected_row_version": 1, "values": {"score": 8}}).status_code == 403
    assert api("PATCH", f"{prefix}/{row['id']}", headers=_headers(editor), json={"expected_row_version": 1, "values": {"score": 8}}).json()["record"]["row_version"] == 2
    assert api("DELETE", f"/v1/teams/{space_id}/members/{editor_id}", headers=_headers(owner)).status_code == 204
    assert api("GET", f"{prefix}/{row['id']}", headers=_headers(editor)).status_code == 404


def test_app_validation_and_manifest_version(api_factory):
    api = api_factory()
    owner, _ = _account(api, "schema_owner")
    space_id = api("GET", "/v1/spaces", headers=_headers(owner)).json()["spaces"][0]["space_id"]
    app = api("POST", f"/v1/spaces/{space_id}/apps", headers=_headers(owner), json={
        "name": "Typed", "manifest": {"tables": {"items": {"fields": {"count": {"type": "integer", "nullable": False}}}}},
    })
    assert app.status_code == 201, app.text
    app_id = app.json()["app"]["app_id"]
    prefix = f"/v1/apps/{app_id}/tables/items/records"
    assert api("POST", prefix, headers=_headers(owner), json={"values": {"count": True}}).status_code == 422
    assert api("POST", prefix, headers=_headers(owner), json={"values": {"count": 2_147_483_648}}).status_code == 422
    assert api("POST", prefix, headers=_headers(owner), json={"values": {"count": 1, "owner_id": "hack"}}).status_code == 422
    record = api("POST", prefix, headers=_headers(owner), json={"values": {"count": 1}})
    assert record.status_code == 201
    row_id = record.json()["record"]["id"]
    assert api("PATCH", f"{prefix}/{row_id}", headers=_headers(owner), json={"expected_row_version": 5, "values": {"count": 2}}).status_code == 409
    changed = api("PUT", f"/v1/apps/{app_id}/manifest", headers=_headers(owner), json={
        "expected_version": 1,
        "manifest": {"tables": {"items": {"fields": {
            "count": {"type": "integer", "nullable": False},
            "comment": {"type": "text", "nullable": True},
        }}}},
    })
    assert changed.status_code == 200, changed.text
    assert changed.json()["app"]["manifest_version"] == 2
    assert api("PUT", f"/v1/apps/{app_id}/manifest", headers=_headers(owner), json={
        "expected_version": 1, "manifest": changed.json()["app"]["manifest"],
    }).status_code == 409

    numeric_app = api("POST", f"/v1/spaces/{space_id}/apps", headers=_headers(owner), json={
        "name": "Numeric", "manifest": {"tables": {"items": {"fields": {
            "amount": {"type": "numeric", "nullable": False},
        }}}},
    }).json()["app"]
    numeric_records = f"/v1/apps/{numeric_app['app_id']}/tables/items/records"
    assert api("POST", numeric_records, headers=_headers(owner), json={
        "values": {"amount": "1e1000"},
    }).status_code == 422
    amount = api("POST", numeric_records, headers=_headers(owner), json={
        "values": {"amount": "1.25"},
    })
    assert amount.status_code == 201
    result = api("POST", f"{numeric_records}/query", headers=_headers(owner), json={
        "filter": {"field": "amount", "op": "gte", "value": "1"},
    })
    assert result.status_code == 200
    assert [row["id"] for row in result.json()["records"]] == [amount.json()["record"]["id"]]


def test_legacy_agent_endpoints_are_not_exposed(api_factory):
    api = api_factory()
    owner, _ = _account(api, "agent_owner")
    page = api("POST", "/v1/pages", headers=_headers(owner), json={"title": "Local", "document": _document()})
    page_id = page.json()["page"]["page_id"]
    assert api("GET", f"/v1/pages/{page_id}/agent/status", headers=_headers(owner)).status_code == 404
    assert api("GET", f"/v1/pages/{page_id}/proposals", headers=_headers(owner)).status_code == 404
    assert api("POST", "/mcp", headers=_headers(owner), json={"jsonrpc": "2.0", "method": "initialize", "id": 1}).status_code == 404


def test_app_query_bulk_pagination_and_soft_delete(api_factory):
    api = api_factory()
    token, _ = _account(api, "query_owner")
    headers = _headers(token)
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    app = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Query", "manifest": {"tables": {"leads": {"fields": {
            "name": {"type": "text", "nullable": False}, "score": {"type": "integer", "nullable": False},
        }}}},
    }).json()["app"]
    prefix = f"/v1/apps/{app['app_id']}/tables/leads/records"
    bulk = api("POST", f"{prefix}/bulk", headers=headers, json={"records": [
        {"values": {"name": "A", "score": 2}}, {"values": {"name": "B", "score": 7}},
        {"values": {"name": "C", "score": 9}},
    ]})
    assert bulk.status_code == 201, bulk.text
    first = api("GET", f"{prefix}?limit=2", headers=headers).json()
    second = api("GET", f"{prefix}?limit=2&cursor={first['next_cursor']}", headers=headers).json()
    assert [row["values"]["name"] for row in first["records"] + second["records"]] == ["A", "B", "C"]
    assert api("DELETE", f"{prefix}/{bulk.json()['records'][0]['id']}", headers=headers,
               json={"expected_row_version": 1}).status_code == 204
    remaining = api("GET", f"{prefix}?limit=2&cursor={first['next_cursor']}", headers=headers)
    assert [row["values"]["name"] for row in remaining.json()["records"]] == ["C"]
    queried = api("POST", f"{prefix}/query", headers=headers, json={
        "filter": {"field": "score", "op": "gte", "value": 7},
        "sort": [{"field": "score", "direction": "desc"}],
    })
    assert queried.status_code == 200, queried.text
    assert [row["values"]["name"] for row in queried.json()["records"]] == ["C", "B"]
    sorted_first = api("POST", f"{prefix}/query", headers=headers, json={
        "sort": [{"field": "score", "direction": "desc"}], "limit": 1,
    }).json()
    sorted_second = api("POST", f"{prefix}/query", headers=headers, json={
        "sort": [{"field": "score", "direction": "desc"}], "limit": 1,
        "cursor": sorted_first["next_cursor"],
    }).json()
    assert [row["values"]["name"] for row in sorted_first["records"] + sorted_second["records"]] == ["C", "B"]
    row_id = bulk.json()["records"][1]["id"]
    deleted = api("DELETE", f"{prefix}/{row_id}", headers=headers, json={"expected_row_version": 1})
    assert deleted.status_code == 204, deleted.text
    assert api("GET", f"{prefix}/{row_id}", headers=headers).status_code == 404
    restored = api("POST", f"{prefix}/{row_id}/restore", headers=headers, json={"expected_row_version": 2})
    assert restored.status_code == 200, restored.text
    assert restored.json()["record"]["row_version"] == 3


def test_app_query_rejects_bad_filter_and_cursor(api_factory):
    api = api_factory()
    token, _ = _account(api, "bad_query_owner")
    headers = _headers(token)
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    app_id = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Query", "manifest": {"tables": {"items": {"fields": {"count": {"type": "integer", "nullable": False}}}}},
    }).json()["app"]["app_id"]
    prefix = f"/v1/apps/{app_id}/tables/items/records"
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": ["count"]}).status_code == 422
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": {"and": [1]}}).status_code == 422
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": {
        "and": [{"and": [{"field": "count", "op": "eq", "value": 1}]}],
    }}).status_code == 422
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": {"field": ["count"], "op": "eq", "value": 1}}).status_code == 422
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": {"field": "count", "op": ["eq"], "value": 1}}).status_code == 422
    assert api("POST", f"{prefix}/query", headers=headers, json={"filter": {"field": "secret", "op": "eq", "value": 1}}).status_code == 422
    assert api("GET", f"{prefix}?cursor=not-a-cursor", headers=headers).status_code == 422


def test_app_manifest_rejects_malformed_field_type(api_factory):
    api = api_factory()
    token, _ = _account(api, "bad_manifest_owner")
    headers = _headers(token)
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    response = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Bad", "manifest": {"tables": {"items": {"fields": {
            "count": {"type": ["integer"], "nullable": False},
        }}}},
    })
    assert response.status_code == 422
    assert response.json() == {"detail": {"code": "APP_MANIFEST_INVALID"}}
