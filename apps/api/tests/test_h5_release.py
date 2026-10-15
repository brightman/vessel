from pathlib import Path
from zipfile import ZipFile

import pytest


def make_zip(tmp_path: Path, contents: dict[str, bytes]) -> Path:
    archive = tmp_path / "release.zip"
    with ZipFile(archive, "w") as output:
        for name, data in contents.items():
            output.writestr(name, data)
    return archive


def test_h5_validator_accepts_static_archive_and_rejects_path_escape(tmp_path):
    from vessel_service.apps.h5_release import H5PackageValidator, cleanup_h5_package

    archive = make_zip(tmp_path, {
        "index.html": b"<script src='assets/app.js'></script>",
        "assets/app.js": b"console.log('ok')",
    })
    package = H5PackageValidator().validate(archive, "app-id", {"tables": {"notes": {"fields": {}}}})
    try:
        assert package.entry_file == "index.html"
        assert package.file_count == 2
    finally:
        cleanup_h5_package(package)

    unsafe = make_zip(tmp_path, {"../outside.js": b"x", "index.html": b"ok"})
    with pytest.raises(ValueError, match="H5_PATH_TRAVERSAL"):
        H5PackageValidator().validate(unsafe, "app-id", {"tables": {}})


def test_local_release_storage_keeps_drafts_private_and_publishes_immutable_tree(tmp_path):
    from vessel_service.apps.h5_release import H5PackageValidator, cleanup_h5_package
    from vessel_service.apps.release_storage import AppReleaseStorageError, LocalAppReleaseStorage

    archive = make_zip(tmp_path, {"index.html": b"<h1>First</h1>"})
    storage = LocalAppReleaseStorage(tmp_path / "release-store")
    draft_key = "vessel-apps/app-id/drafts/release-id.zip"
    prefix = "vessel-apps/app-id/releases/1/"
    storage.put_draft(draft_key, archive.read_bytes())
    assert storage.get_draft(draft_key) == archive.read_bytes()

    package = H5PackageValidator().validate(archive, "app-id", {"tables": {}})
    try:
        storage.publish_tree(prefix, package)
        assert storage.get_published(prefix, "index.html") == b"<h1>First</h1>"
    finally:
        cleanup_h5_package(package)

    changed = make_zip(tmp_path, {"index.html": b"<h1>Changed</h1>"})
    package = H5PackageValidator().validate(changed, "app-id", {"tables": {}})
    try:
        with pytest.raises(AppReleaseStorageError, match="APP_RELEASE_STORAGE_CONFLICT"):
            storage.publish_tree(prefix, package)
    finally:
        cleanup_h5_package(package)


def _manager_app(api_factory, storage=None):
    kwargs = {} if storage is None else {
        "configure_application": lambda application: setattr(application.state, "app_release_storage", storage),
    }
    api = api_factory(**kwargs)
    registered = api("POST", "/v1/auth/register", json={
        "name": "release-owner", "email": "release-owner@example.test", "password": "vessel-test-2026",
    })
    assert registered.status_code == 201, registered.text
    headers = {"Authorization": f"Bearer {registered.json()['access_token']}"}
    space_id = api("GET", "/v1/spaces", headers=headers).json()["spaces"][0]["space_id"]
    created = api("POST", f"/v1/spaces/{space_id}/apps", headers=headers, json={
        "name": "Published App", "manifest": {"tables": {"notes": {"fields": {
            "title": {"type": "text", "nullable": False},
        }}}},
    })
    assert created.status_code == 201, created.text
    return api, created.json()["app"]["app_id"], headers


def test_release_draft_never_becomes_current_until_explicit_publish(api_factory, tmp_path):
    from vessel_service.apps.release_storage import LocalAppReleaseStorage

    api, app_id, headers = _manager_app(api_factory, LocalAppReleaseStorage(tmp_path / "release-store"))
    draft = api("POST", f"/v1/apps/{app_id}/releases", headers=headers)
    assert draft.status_code == 201, draft.text
    release_id = draft.json()["release"]["release_id"]

    archive = make_zip(tmp_path, {"index.html": b"<h1>Draft</h1>"})
    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/upload", headers=headers, files={
        "file": ("release.zip", archive.read_bytes(), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    assert uploaded.json()["release"]["status"] == "draft"
    assert uploaded.json()["release"]["is_current"] is False

    published = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/publish", headers=headers)
    assert published.status_code == 200, published.text
    assert published.json()["release"]["status"] == "published"
    assert published.json()["release"]["is_current"] is True


def test_test_application_uses_private_local_release_storage(api_factory, tmp_path):
    api, app_id, headers = _manager_app(api_factory)
    release_id = api("POST", f"/v1/apps/{app_id}/releases", headers=headers).json()["release"]["release_id"]
    archive = make_zip(tmp_path, {"index.html": b"<h1>Default storage</h1>"})
    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/upload", headers=headers, files={
        "file": ("release.zip", archive.read_bytes(), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text


def test_invalid_release_upload_is_not_publishable(api_factory, tmp_path):
    from vessel_service.apps.release_storage import LocalAppReleaseStorage

    api, app_id, headers = _manager_app(api_factory, LocalAppReleaseStorage(tmp_path / "release-store"))
    release_id = api("POST", f"/v1/apps/{app_id}/releases", headers=headers).json()["release"]["release_id"]
    unsafe = make_zip(tmp_path, {"../outside.js": b"x", "index.html": b"ok"})
    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/upload", headers=headers, files={
        "file": ("unsafe.zip", unsafe.read_bytes(), "application/zip"),
    })
    assert uploaded.status_code == 200, uploaded.text
    assert uploaded.json()["release"]["status"] == "validation_failed"
    assert uploaded.json()["release"]["validation_error_code"] == "H5_PATH_TRAVERSAL"
    rejected = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/publish", headers=headers)
    assert rejected.status_code == 409
    assert rejected.json()["detail"]["code"] == "APP_RELEASE_NOT_PUBLISHABLE"


def test_release_rollback_switches_only_current_pointer(api_factory, tmp_path):
    from vessel_service.apps.release_storage import LocalAppReleaseStorage

    api, app_id, headers = _manager_app(api_factory, LocalAppReleaseStorage(tmp_path / "release-store"))
    releases = []
    for content in (b"<h1>First</h1>", b"<h1>Second</h1>"):
        release_id = api("POST", f"/v1/apps/{app_id}/releases", headers=headers).json()["release"]["release_id"]
        archive = make_zip(tmp_path, {"index.html": content})
        uploaded = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/upload", headers=headers, files={
            "file": ("release.zip", archive.read_bytes(), "application/zip"),
        })
        assert uploaded.status_code == 200, uploaded.text
        published = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/publish", headers=headers)
        assert published.status_code == 200, published.text
        releases.append(published.json()["release"])

    rolled_back = api("POST", f"/v1/apps/{app_id}/releases/{releases[0]['release_id']}/rollback", headers=headers)
    assert rolled_back.status_code == 200, rolled_back.text
    assert rolled_back.json()["release"]["version"] == 1
    history = api("GET", f"/v1/apps/{app_id}/releases", headers=headers).json()["releases"]
    assert [release["version"] for release in history if release["is_current"]] == [1]
    assert {release["status"] for release in history} == {"published"}


def test_create_draft_flushes_release_before_its_audit_event():
    from vessel_service.apps.releases import create_draft
    from vessel_service.models import User, VesselApp, VesselAppAuditEvent, VesselAppRelease

    class OrderedSession:
        def __init__(self):
            self.release_added = False
            self.flushed = False
            self.scalar_calls = 0

        def scalar(self, _statement):
            self.scalar_calls += 1
            return "app-id" if self.scalar_calls == 1 else None

        def add(self, item):
            if isinstance(item, VesselAppRelease):
                self.release_added = True
            if isinstance(item, VesselAppAuditEvent):
                assert self.release_added
                assert self.flushed, "the release row must exist before its audit row"

        def flush(self):
            assert self.release_added
            self.flushed = True

        def commit(self):
            assert self.flushed

    app = VesselApp(app_id="app-id", space_id="space-id", name="Release test", manifest_json={"tables": {}},
                    manifest_version=1, settings_version=1, status="active", description="", created_by="user-id", updated_by="user-id")
    actor = User(user_id="user-id", name="Release owner", email="release-ordering@example.test", status="active", roles=[])
    release = create_draft(OrderedSession(), app, actor)
    assert release.app_id == app.app_id
