import base64
import hashlib

from test_pages import authorized, register


PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
)


def _create_page(api, token: str) -> str:
    response = api(
        "POST",
        "/v1/pages",
        headers=authorized(token),
        json={
            "title": "Asset test",
            "document": {"type": "doc", "schema_version": 1, "content": []},
        },
    )
    assert response.status_code == 201
    return response.json()["page"]["page_id"]


def _set_asset_settings(monkeypatch, tmp_path, *, max_bytes: int = 5_242_880) -> None:
    monkeypatch.setenv("PAGES_ASSET_STORAGE_PATH", str(tmp_path / "private-assets"))
    monkeypatch.setenv("PAGES_MAX_ASSET_UPLOAD_BYTES", str(max_bytes))


def test_owner_can_upload_and_read_back_private_image_with_checksum(
    api_factory, monkeypatch, tmp_path
) -> None:
    _set_asset_settings(monkeypatch, tmp_path)
    api = api_factory()
    token = register(api, "asset-owner@example.test")
    page_id = _create_page(api, token)

    uploaded = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(token), "Content-Type": "image/png"},
        content=PNG_1X1,
    )

    assert uploaded.status_code == 201
    asset = uploaded.json()["asset"]
    assert asset["page_id"] == page_id
    assert asset["content_type"] == "image/png"
    assert asset["size_bytes"] == len(PNG_1X1)
    assert asset["sha256"] == hashlib.sha256(PNG_1X1).hexdigest()
    assert asset["content_url"] == f"/v1/assets/{asset['asset_id']}/content"

    fetched = api("GET", asset["content_url"], headers=authorized(token))

    assert fetched.status_code == 200
    assert fetched.content == PNG_1X1
    assert fetched.headers["content-type"] == "image/png"
    assert fetched.headers["x-content-type-options"] == "nosniff"
    assert fetched.headers["cache-control"] == "private, no-store"
    stored_files = list((tmp_path / "private-assets").rglob("*"))
    assert len([path for path in stored_files if path.is_file()]) == 1
    assert all("Asset test" not in str(path) for path in stored_files)


def test_user_cannot_upload_to_another_users_page(api_factory, monkeypatch, tmp_path) -> None:
    _set_asset_settings(monkeypatch, tmp_path)
    api = api_factory()
    owner_token = register(api, "asset-page-owner@example.test")
    other_token = register(api, "asset-page-other@example.test")
    page_id = _create_page(api, owner_token)

    response = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(other_token), "Content-Type": "image/png"},
        content=PNG_1X1,
    )

    assert response.status_code == 404
    assert response.json() == {"detail": {"code": "PAGE_NOT_FOUND"}}
    assert not list((tmp_path / "private-assets").rglob("*"))


def test_user_cannot_read_another_users_asset(api_factory, monkeypatch, tmp_path) -> None:
    _set_asset_settings(monkeypatch, tmp_path)
    api = api_factory()
    owner_token = register(api, "asset-read-owner@example.test")
    other_token = register(api, "asset-read-other@example.test")
    page_id = _create_page(api, owner_token)
    uploaded = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(owner_token), "Content-Type": "image/png"},
        content=PNG_1X1,
    )
    asset_id = uploaded.json()["asset"]["asset_id"]

    response = api(
        "GET", f"/v1/assets/{asset_id}/content", headers=authorized(other_token)
    )

    assert response.status_code == 404
    assert response.json() == {"detail": {"code": "ASSET_NOT_FOUND"}}


def test_upload_rejects_unapproved_media_types(api_factory, monkeypatch, tmp_path) -> None:
    _set_asset_settings(monkeypatch, tmp_path)
    api = api_factory()
    token = register(api, "asset-svg@example.test")
    page_id = _create_page(api, token)

    response = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(token), "Content-Type": "image/svg+xml"},
        content=b"<svg xmlns='http://www.w3.org/2000/svg'></svg>",
    )

    assert response.status_code == 415
    assert response.json() == {"detail": {"code": "ASSET_MEDIA_TYPE_NOT_ALLOWED"}}


def test_upload_rejects_content_that_does_not_match_declared_image_type(
    api_factory, monkeypatch, tmp_path
) -> None:
    _set_asset_settings(monkeypatch, tmp_path)
    api = api_factory()
    token = register(api, "asset-mismatch@example.test")
    page_id = _create_page(api, token)

    response = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(token), "Content-Type": "image/png"},
        content=b"this is not a png",
    )

    assert response.status_code == 415
    assert response.json() == {"detail": {"code": "ASSET_CONTENT_TYPE_MISMATCH"}}


def test_upload_enforces_configured_size_limit_while_reading_request(
    api_factory, monkeypatch, tmp_path
) -> None:
    _set_asset_settings(monkeypatch, tmp_path, max_bytes=1024)
    api = api_factory()
    token = register(api, "asset-size@example.test")
    page_id = _create_page(api, token)

    response = api(
        "POST",
        f"/v1/pages/{page_id}/assets",
        headers={**authorized(token), "Content-Type": "image/png"},
        content=b"\x89PNG\r\n\x1a\n" + b"x" * 1024,
    )

    assert response.status_code == 413
    assert response.json() == {"detail": {"code": "ASSET_TOO_LARGE"}}
    assert not list((tmp_path / "private-assets").rglob("*"))
