from pathlib import Path
from zipfile import ZipFile

import pytest


def test_app_release_origin_requires_a_host_distinct_from_the_api():
    from vessel_service.settings import Settings

    with pytest.raises(ValueError, match="must use a host distinct"):
        Settings(
            environment="production",
            database_url="postgresql+psycopg://vessel@db.test/vessel",
            issuer_url="https://api.example.test",
            app_release_origin="https://api.example.test",
            signing_keys_file=Path("/private/keyring.json"),
            h5_preview_secret="preview-secret",
        )


def test_release_origin_normalizes_default_ports_and_requires_https_in_production():
    from vessel_service.settings import Settings

    settings = Settings(
        environment="production",
        database_url="postgresql+psycopg://vessel@db.test/vessel",
        issuer_url="https://api.example.test",
        app_release_origin="https://apps.example.test:443",
        signing_keys_file=Path("/private/keyring.json"),
        h5_preview_secret="preview-secret",
    )
    assert settings.app_release_origin == "https://apps.example.test"
    with pytest.raises(ValueError, match="must use https in production"):
        Settings(
            environment="production",
            database_url="postgresql+psycopg://vessel@db.test/vessel",
            issuer_url="https://api.example.test",
            app_release_origin="http://apps.example.test",
            signing_keys_file=Path("/private/keyring.json"),
            h5_preview_secret="preview-secret",
        )


def test_release_zone_derives_a_distinct_origin_for_each_app_and_preserves_port():
    from vessel_service.settings import Settings

    settings = Settings(
        environment="test",
        issuer_url="https://api.example.test",
        app_release_origin="https://apps.example.test:8443",
    )

    assert settings.app_release_origin_for("b8a53a5f-8353-4eef-b7ae-3fbcf70f8e56") == (
        "https://b8a53a5f-8353-4eef-b7ae-3fbcf70f8e56.apps.example.test:8443"
    )


def test_release_zone_rejects_an_ip_address_that_cannot_have_app_subdomains():
    from vessel_service.settings import Settings

    with pytest.raises(ValueError, match="DNS hostname"):
        Settings(
            environment="test",
            issuer_url="http://api.127.0.0.1.nip.io:52014",
            app_release_origin="http://127.0.0.1:52014",
        )


def test_unconfigured_release_origin_does_not_add_cors_to_record_apis(api_factory):
    api = api_factory(app_release_origin=None)

    response = api("GET", "/v1/apps/not-an-app/tables/notes/records")

    assert response.status_code == 401
    assert "access-control-allow-origin" not in response.headers


def test_release_mutations_fail_before_changing_state_when_release_origin_is_unconfigured(api_factory):
    api = api_factory(app_release_origin=None)
    registered = api("POST", "/v1/auth/register", json={
        "name": "origin-owner", "email": "origin-owner@example.test", "password": "vessel-test-2026",
    })
    assert registered.status_code == 201, registered.text
    headers = {"Authorization": f"Bearer {registered.json()['access_token']}"}
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    created = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Origin App", "manifest": {"tables": {"notes": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    })
    assert created.status_code == 201, created.text
    app_id = created.json()["app"]["app_id"]

    blocked = api("POST", f"/v1/apps/{app_id}/releases", headers=headers)
    assert blocked.status_code == 503
    assert blocked.json()["detail"]["code"] == "APP_RELEASE_ORIGIN_NOT_CONFIGURED"

    configured = api_factory()
    releases = configured("GET", f"/v1/apps/{app_id}/releases", headers=headers)
    assert releases.status_code == 200, releases.text
    assert releases.json()["releases"] == []


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
    release_origin = f"https://{app_id}.apps.test"

    issuer_index = api("GET", f"/apps/{app_id}/releases/{version}/index.html")
    assert issuer_index.status_code == 404
    index = api("GET", f"{release_origin}/apps/{app_id}/releases/{version}/index.html")
    assert index.status_code == 200, index.text
    assert index.text == "<h1>Gateway</h1>"
    assert index.headers["x-content-type-options"] == "nosniff"
    assert api("GET", f"{release_origin}/apps/{app_id}/releases/{version}/missing.js").status_code == 404
    fallback = api("GET", f"{release_origin}/apps/{app_id}/releases/{version}/projects/next")
    assert fallback.text == "<h1>Gateway</h1>"
    assert fallback.headers["content-type"].startswith("text/html")


def test_h5_launch_ticket_cannot_mint_a_session_for_another_app(api_factory, tmp_path):
    api, app_id, version, headers, _, space_id = _published_release(api_factory, tmp_path)
    release_id = api("GET", f"/v1/apps/{app_id}/releases", headers=headers).json()["releases"][0]["release_id"]
    other = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Other App", "manifest": {"tables": {"notes": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    })
    assert other.status_code == 201, other.text
    other_id = other.json()["app"]["app_id"]
    other_release = api("POST", f"/v1/apps/{other_id}/releases", headers=headers).json()["release"]
    uploaded = api("POST", f"/v1/apps/{other_id}/releases/{other_release['release_id']}/upload", headers=headers, files={
        "file": ("other.zip", _zip(tmp_path, {"index.html": b"<h1>Other</h1>"}), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    published_other = api("POST", f"/v1/apps/{other_id}/releases/{other_release['release_id']}/publish", headers=headers)
    assert published_other.status_code == 200, published_other.text
    app_origin = f"https://{app_id}.apps.test"
    other_origin = f"https://{other_id}.apps.test"

    direct_session = api("POST", f"{app_origin}/apps/{app_id}/releases/{version}/h5/session")
    assert direct_session.status_code == 401
    launched = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/launch", headers=headers)
    assert launched.status_code == 200, launched.text
    assert launched.json()["launch_url"].startswith(f"{app_origin}/apps/")
    initial = api("GET", launched.json()["launch_url"])
    assert initial.status_code == 307
    assert "ticket=" not in initial.headers["location"]
    from http.cookies import SimpleCookie
    cookie = SimpleCookie(); cookie.load(initial.headers["set-cookie"])
    launch_cookie = {"vessel_app_h5_launch": cookie["vessel_app_h5_launch"].value}
    session = api("POST", f"{app_origin}/apps/{app_id}/releases/{version}/h5/session", cookies=launch_cookie)
    assert session.status_code == 200, session.text
    assert "access-control-allow-origin" not in session.headers
    cross_origin_mint = api("POST", f"{app_origin}/apps/{app_id}/releases/{version}/h5/session", cookies=launch_cookie, headers={
        "Origin": other_origin,
    })
    assert cross_origin_mint.status_code == 403
    assert cross_origin_mint.json()["detail"]["code"] == "APP_H5_SESSION_ORIGIN_INVALID"
    cross_mint = api("POST", f"{other_origin}/apps/"
                     f"{other_id}/releases/{published_other.json()['release']['version']}/h5/session", cookies=launch_cookie)
    assert cross_mint.status_code == 401
    assert cross_mint.json()["detail"]["code"] == "APP_H5_LAUNCH_INVALID"
    h5_headers = {"Authorization": f"Bearer {session.json()['access_token']}"}
    records_path = f"/v1/apps/{app_id}/tables/notes/records"
    preflight = api("OPTIONS", records_path, headers={
        "Origin": app_origin,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization,content-type",
    })
    assert preflight.status_code == 204
    assert preflight.headers["access-control-allow-origin"] == app_origin
    cross_app_preflight = api("OPTIONS", f"/v1/apps/{other_id}/tables/notes/records", headers={
        "Origin": app_origin,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization,content-type",
    })
    assert cross_app_preflight.status_code == 405
    assert "access-control-allow-origin" not in cross_app_preflight.headers
    own_record = api("POST", f"/v1/apps/{app_id}/tables/notes/records", headers=h5_headers, json={
        "values": {"title": "Allowed"},
    })
    assert own_record.status_code == 201, own_record.text
    browser_record = api("GET", records_path, headers={**h5_headers, "Origin": app_origin})
    assert browser_record.status_code == 200, browser_record.text
    assert browser_record.headers["access-control-allow-origin"] == app_origin
    cross_app = api("POST", f"/v1/apps/{other_id}/tables/notes/records", headers=h5_headers, json={
        "values": {"title": "Denied"},
    })
    assert cross_app.status_code == 404
    assert cross_app.json()["detail"]["code"] == "APP_NOT_FOUND"
    assert api("POST", f"/v1/apps/{app_id}/releases", headers=h5_headers).status_code == 401


def test_draft_preview_uses_a_short_lived_http_only_ticket_for_the_full_bundle(api_factory, tmp_path):
    api, app_id, _, headers, _, _ = _published_release(api_factory, tmp_path)
    app_origin = f"https://{app_id}.apps.test"
    draft = api("POST", f"/v1/apps/{app_id}/releases", headers=headers).json()["release"]
    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{draft['release_id']}/upload", headers=headers, files={
        "file": ("draft.zip", _zip(tmp_path, {
            "index.html": b"<link rel='stylesheet' href='assets/app.css'><script src='assets/app.js'></script><h1>Preview</h1>",
            "assets/app.js": b"console.log('preview')",
            "assets/app.css": b"h1 { color: green; }",
        }), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    preview_url = uploaded.json()["preview_url"]
    assert preview_url.startswith(f"{app_origin}/")
    initial = api("GET", preview_url)
    assert initial.status_code == 307
    assert "ticket=" not in initial.headers["location"]
    assert "HttpOnly" in initial.headers["set-cookie"]
    from http.cookies import SimpleCookie
    cookie = SimpleCookie(); cookie.load(initial.headers["set-cookie"])
    preview_cookie = {"vessel_app_preview": cookie["vessel_app_preview"].value}
    preview = api("GET", initial.headers["location"], cookies=preview_cookie)
    assert preview.status_code == 200
    assert "Preview" in preview.text
    assert preview.headers["referrer-policy"] == "no-referrer"
    asset = api("GET", initial.headers["location"].replace("index.html", "assets/app.js"), cookies=preview_cookie)
    assert asset.status_code == 200
    assert asset.text == "console.log('preview')"
    assert api("GET", initial.headers["location"].replace("index.html", "assets/app.js")).status_code == 401
    assert api("GET", preview_url + "tampered").status_code == 401


def test_release_origin_cannot_refresh_a_full_vessel_session(api_factory, tmp_path):
    api, app_id, _, _, refresh_cookie, _ = _published_release(api_factory, tmp_path)
    blocked = api("POST", "/v1/auth/refresh", cookies=refresh_cookie, headers={"Origin": f"https://{app_id}.apps.test"})
    assert blocked.status_code == 403
    assert blocked.json()["detail"]["code"] == "AUTH_ORIGIN_INVALID"


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
