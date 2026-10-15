from pathlib import Path
from zipfile import ZipFile


def _zip(tmp_path: Path, contents: dict[str, bytes]) -> bytes:
    path = tmp_path / "gateway-release.zip"
    with ZipFile(path, "w") as output:
        for name, data in contents.items():
            output.writestr(name, data)
    return path.read_bytes()


def _published_release(api_factory, tmp_path):
    api = api_factory()
    registered = api("POST", "/v1/auth/register", json={
        "name": "gateway-owner", "email": "gateway-owner@example.test", "password": "vessel-test-2026",
    })
    assert registered.status_code == 201, registered.text
    headers = {"Authorization": f"Bearer {registered.json()['access_token']}"}
    refresh_cookie = {"vessel_refresh": registered.cookies["vessel_refresh"]}
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    app = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Gateway App", "manifest": {"tables": {"notes": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    }).json()["app"]
    release = api("POST", f"/v1/apps/{app['app_id']}/releases", headers=headers).json()["release"]
    uploaded = api("POST", f"/v1/apps/{app['app_id']}/releases/{release['release_id']}/upload", headers=headers, files={
        "file": ("release.zip", _zip(tmp_path, {
            "index.html": b"<h1>Gateway</h1>", "assets/app.js": b"console.log('gateway')",
        }), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    published = api("POST", f"/v1/apps/{app['app_id']}/releases/{release['release_id']}/publish", headers=headers)
    assert published.status_code == 200, published.text
    return api, app["app_id"], published.json()["release"]["version"], headers, refresh_cookie, space_id


def test_public_release_assets_are_versioned_and_missing_assets_do_not_fall_back(api_factory, tmp_path):
    api, app_id, version, _, _, _ = _published_release(api_factory, tmp_path)

    index = api("GET", f"/apps/{app_id}/releases/{version}/index.html")
    assert index.status_code == 200, index.text
    assert index.text == "<h1>Gateway</h1>"
    assert index.headers["x-content-type-options"] == "nosniff"
    assert api("GET", f"/apps/{app_id}/releases/{version}/missing.js").status_code == 404
    assert api("GET", f"/apps/{app_id}/releases/{version}/projects/next").text == "<h1>Gateway</h1>"


def test_h5_token_can_access_only_its_app_records(api_factory, tmp_path):
    api, app_id, version, headers, refresh_cookie, space_id = _published_release(api_factory, tmp_path)
    other = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Other App", "manifest": {"tables": {"notes": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    })
    assert other.status_code == 201, other.text

    session = api("POST", f"/v1/apps/{app_id}/h5/session", cookies=refresh_cookie, json={"release_version": version})
    assert session.status_code == 200, session.text
    h5_headers = {"Authorization": f"Bearer {session.json()['access_token']}"}
    own_record = api("POST", f"/v1/apps/{app_id}/tables/notes/records", headers=h5_headers, json={
        "values": {"title": "Allowed"},
    })
    assert own_record.status_code == 201, own_record.text
    cross_app = api("POST", f"/v1/apps/{other.json()['app']['app_id']}/tables/notes/records", headers=h5_headers, json={
        "values": {"title": "Denied"},
    })
    assert cross_app.status_code == 404
    assert cross_app.json()["detail"]["code"] == "APP_NOT_FOUND"
    assert api("POST", f"/v1/apps/{app_id}/releases", headers=h5_headers).status_code == 401


def test_draft_preview_requires_a_short_lived_ticket(api_factory, tmp_path):
    api, app_id, _, headers, _, _ = _published_release(api_factory, tmp_path)
    draft = api("POST", f"/v1/apps/{app_id}/releases", headers=headers).json()["release"]
    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{draft['release_id']}/upload", headers=headers, files={
        "file": ("draft.zip", _zip(tmp_path, {"index.html": b"<h1>Preview</h1>"}), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    preview_url = uploaded.json()["preview_url"]
    assert api("GET", preview_url).text == "<h1>Preview</h1>"
    assert api("GET", preview_url + "tampered").status_code == 401


def test_refresh_cookie_is_available_to_the_h5_session_endpoint(api_factory):
    api = api_factory()
    registered = api("POST", "/v1/auth/register", json={
        "name": "cookie-owner", "email": "cookie-owner@example.test", "password": "vessel-test-2026",
    })
    assert registered.status_code == 201, registered.text
    from http.cookies import SimpleCookie

    cookie = SimpleCookie()
    cookie.load(registered.headers["set-cookie"])
    assert cookie["vessel_refresh"]["path"] == "/"
