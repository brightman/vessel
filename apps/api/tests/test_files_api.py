"""API behavior with real DB/auth and only OSS's network boundary replaced."""

import asyncio
import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import httpx
import pytest
from sqlalchemy.orm import sessionmaker
from vessel_service.auth.tokens import KeyRing
from vessel_service.database import create_database_engine
from vessel_service.main import create_app
from vessel_service.models import Base
from vessel_service.settings import Settings


class ObjectBoundary:
    def __init__(self):
        self.incoming = {}
        self.objects = {}
        self.published = 0
        self.fail_delete = False

    def start_upload(self, upload):
        return {
            "temp_key": upload["temp_key"],
            "final_key": upload["final_key"],
            "oss_upload_id": "multipart-id"
            if upload["transfer_mode"] == "multipart"
            else None,
        }

    def sign_parts(self, upload, numbers):
        return [
            {
                "part_number": n,
                "method": "PUT",
                "url": "https://oss.test/temp",
                "headers": {},
                "expires_at": (datetime.now(UTC) + timedelta(minutes=10)).isoformat(),
                "size_bytes": min(
                    upload["part_size_bytes"],
                    upload["size_bytes"] - (n - 1) * upload["part_size_bytes"],
                ),
            }
            for n in numbers
        ]

    def verify(self, upload, parts):
        data = self.incoming[upload["upload_id"]]
        if (
            hashlib.sha256(data).hexdigest() != upload["sha256"]
            or len(data) != upload["size_bytes"]
        ):
            from vessel_service.files.storage import StorageError

            raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        return {
            "size_bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "crc64": "42",
            "source_version_id": "source-version",
        }

    def publish(self, upload, verified):
        self.published += 1
        key = upload["final_key"]
        self.objects[key] = self.incoming[upload["upload_id"]]
        return {
            "bucket": "private-test",
            "object_key": key,
            "oss_version_id": "sealed-version",
        }

    def sign_download(self, version, filename):
        return {
            "url": "https://oss.test/private?versionId=" + version["oss_version_id"],
            "expires_at": (datetime.now(UTC) + timedelta(seconds=60)).isoformat(),
        }

    def cleanup_upload(self, upload):
        self.incoming.pop(upload["upload_id"], None)

    def delete_version(self, version):
        if self.fail_delete:
            raise RuntimeError("temporary storage failure")
        self.objects.pop(version["object_key"], None)


@pytest.fixture
def files_api(tmp_path):
    engine = create_database_engine(f"sqlite+pysqlite:///{tmp_path}/files.sqlite")
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    application = create_app(
        settings=Settings(
            environment="test", allow_registration=True, registration_email_verification_required=False, refresh_cookie_secure=False
        ),
        engine=engine,
        session_factory=sessions,
        keyring=KeyRing.for_test("files-test"),
    )
    Base.metadata.create_all(engine)
    boundary = ObjectBoundary()
    application.state.file_storage = boundary

    def request(method, path, **kwargs):
        kwargs["headers"] = dict(kwargs.get("headers", {}))
        if method in {"POST", "PATCH", "DELETE", "PUT"}:
            kwargs["headers"].setdefault("Idempotency-Key", str(uuid4()))

        async def send():
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=application), base_url="http://test"
            ) as client:
                return await client.request(method, path, **kwargs)

        return asyncio.run(send())

    def register(name):
        r = request(
            "POST",
            "/v1/auth/register",
            json={
                "name": name,
                "email": name + "@example.test",
                "password": "safe-test-password",
            },
        )
        assert r.status_code == 201, r.text
        headers = {"Authorization": "Bearer " + r.json()["access_token"]}
        spaces = request("GET", "/v1/spaces", headers=headers).json()["spaces"]
        return headers, spaces[0]["space_id"], r.json()["user"]["user_id"]

    return request, register, boundary, sessions


def create_upload(api, headers, space, parent, data=b"hello", **fields):
    payload = {
        "mode": "create",
        "parent_folder_id": parent,
        "name": "report.txt",
        "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "content_type": "text/plain",
    }
    payload.update(fields)
    response = api(
        "POST", f"/v1/spaces/{space}/file-uploads", headers=headers, json=payload
    )
    assert response.status_code == 201, response.text
    return response.json()["upload"]


def finish(api, headers, boundary, upload, data=b"hello"):
    boundary.incoming[upload["upload_id"]] = data
    response = api(
        "POST",
        f"/v1/file-uploads/{upload['upload_id']}/complete",
        headers=headers,
        json={},
    )
    assert response.status_code in {200, 202}, response.text
    return api(
        "GET", f"/v1/file-uploads/{upload['upload_id']}", headers=headers
    ).json()["upload"]


def test_file_upload_ready_duplicate_complete_and_download(files_api):
    api, register, storage, _ = files_api
    h, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=h)
    assert root.status_code == 200, root.text
    upload = create_upload(api, h, space, root.json()["folder"]["item_id"])
    ready = finish(api, h, storage, upload)
    assert ready["status"] == "ready", ready
    again = api(
        "POST", f"/v1/file-uploads/{upload['upload_id']}/complete", headers=h, json={}
    )
    assert again.status_code == 200, again.text
    assert storage.published == 1
    download = api("POST", f"/v1/files/{ready['file_id']}/download", headers=h, json={})
    assert download.status_code == 200, download.text
    assert download.json()["download"]["sha256"] == hashlib.sha256(b"hello").hexdigest()
    assert "versionId=sealed-version" in download.json()["download"]["url"]


def test_file_direct_share_does_not_expose_owner_root(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    b, _, bid = register("b")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    ready = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    file_id = ready["file_id"]
    assert api("GET", f"/v1/file-items/{file_id}", headers=b).status_code == 404
    grants = api("GET", f"/v1/file-items/{file_id}/grants", headers=a).json()
    grant = api(
        "POST",
        f"/v1/file-items/{file_id}/grants",
        headers=a,
        json={
            "grantee_user_id": bid,
            "role": "viewer",
            "expected_acl_revision": grants["acl_revision"],
        },
    )
    assert grant.status_code == 201, grant.text
    assert (
        api("POST", f"/v1/files/{file_id}/download", headers=b, json={}).status_code
        == 200
    )
    assert api("GET", f"/v1/spaces/{space}/folders/root", headers=b).status_code == 404
    assert (
        api(
            "PATCH",
            f"/v1/file-items/{file_id}",
            headers=b,
            json={"name": "new", "expected_metadata_version": 1},
        ).status_code
        == 403
    )
    assert (
        api("GET", "/v1/shared-files", headers=b).json()["items"][0]["item_id"]
        == file_id
    )


def test_checksum_failure_never_creates_file(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    upload = create_upload(api, a, space, root["item_id"])
    failed = finish(api, a, storage, upload, b"wrong")
    assert failed["status"] == "failed"
    assert failed["failure_code"] == "UPLOAD_CHECKSUM_MISMATCH"
    assert storage.published == 0
    assert (
        api("GET", f"/v1/folders/{root['item_id']}/children", headers=a).json()["items"]
        == []
    )


def test_version_compare_rejects_second_concurrent_upload(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    first = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    item = api("GET", f"/v1/file-items/{first['file_id']}", headers=a).json()["item"]
    payload = {
        "mode": "new_version",
        "file_id": first["file_id"],
        "expected_current_version_id": first["version_id"],
        "expected_metadata_version": item["metadata_version"],
        "size_bytes": 5,
        "sha256": hashlib.sha256(b"world").hexdigest(),
        "content_type": "text/plain",
    }
    left = api(
        "POST", f"/v1/spaces/{space}/file-uploads", headers=a, json=payload
    ).json()["upload"]
    right = api(
        "POST", f"/v1/spaces/{space}/file-uploads", headers=a, json=payload
    ).json()["upload"]
    assert finish(api, a, storage, left, b"world")["status"] == "ready"
    conflict = finish(api, a, storage, right, b"world")
    assert conflict["status"] == "conflict"
    current = api("GET", f"/v1/file-items/{first['file_id']}", headers=a).json()["item"]
    assert current["current_version_id"] != first["version_id"]
    versions = api("GET", f"/v1/files/{first['file_id']}/versions", headers=a).json()[
        "versions"
    ]
    assert len(versions) == 2


def test_idempotency_payload_mismatch(files_api):
    api, register, _, _ = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    headers = {**a, "Idempotency-Key": "folder-key"}
    payload = {"name": "first", "parent_folder_id": root["item_id"]}
    one = api("POST", f"/v1/spaces/{space}/folders", headers=headers, json=payload)
    two = api("POST", f"/v1/spaces/{space}/folders", headers=headers, json=payload)
    assert one.status_code == two.status_code == 201
    assert one.json() == two.json()
    three = api(
        "POST",
        f"/v1/spaces/{space}/folders",
        headers=headers,
        json={**payload, "name": "different"},
    )
    assert three.status_code == 409


def test_cancel_during_publish_reclaims_late_final_object(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    upload = create_upload(api, a, space, root["item_id"])

    def publishing(record, verified):
        data = storage.incoming[record["upload_id"]]
        cancelled = api(
            "POST", f"/v1/file-uploads/{record['upload_id']}/cancel", headers=a, json={}
        )
        assert cancelled.status_code == 200, cancelled.text
        storage.objects[record["final_key"]] = data
        return {
            "bucket": "private-test",
            "object_key": record["final_key"],
            "oss_version_id": "sealed-version",
        }

    storage.publish = publishing
    cancelled = finish(api, a, storage, upload)
    assert cancelled["status"] == "cancelled"
    assert storage.objects == {}


def test_trash_restore_shared_file_and_purge(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    b, _, bid = register("b")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    ready = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    fid = ready["file_id"]
    acl = api("GET", f"/v1/file-items/{fid}/grants", headers=a).json()["acl_revision"]
    assert (
        api(
            "POST",
            f"/v1/file-items/{fid}/grants",
            headers=a,
            json={
                "grantee_user_id": bid,
                "role": "viewer",
                "expected_acl_revision": acl,
            },
        ).status_code
        == 201
    )
    item = api("GET", f"/v1/file-items/{fid}", headers=a).json()["item"]
    trashed = api(
        "POST",
        f"/v1/file-items/{fid}/trash",
        headers=a,
        json={"expected_metadata_version": item["metadata_version"]},
    )
    assert trashed.status_code == 200, trashed.text
    batch = trashed.json()["trash_batch"]
    assert (
        api("POST", f"/v1/files/{fid}/download", headers=b, json={}).status_code == 404
    )
    preview = api(
        "POST",
        f"/v1/file-trash/{batch['batch_id']}/restore/prepare",
        headers=a,
        json={},
    )
    assert preview.status_code == 200, preview.text
    p = preview.json()["restore"]
    restored = api(
        "POST",
        f"/v1/file-trash/{batch['batch_id']}/restore",
        headers=a,
        json={k: p[k] for k in ("preview_id", "preview_hash", "expected_acl_revision")},
    )
    assert restored.status_code == 200, restored.text
    assert (
        api("POST", f"/v1/files/{fid}/download", headers=b, json={}).status_code == 200
    )
    item = restored.json()["item"]
    batch = api(
        "POST",
        f"/v1/file-items/{fid}/trash",
        headers=a,
        json={"expected_metadata_version": item["metadata_version"]},
    ).json()["trash_batch"]
    purged = api(
        "POST",
        f"/v1/file-trash/{batch['batch_id']}/purge",
        headers=a,
        json={"expected_batch_version": batch["batch_version"]},
    )
    assert purged.status_code == 202, purged.text
    status = api("GET", purged.json()["purge"]["status_url"], headers=a)
    assert status.json()["purge"]["status"] == "succeeded", status.text
    assert storage.objects == {}


def test_duplicate_purge_worker_does_not_debit_other_file_quota(files_api):
    api, register, storage, sessions = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    first = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    finish(
        api, a, storage, create_upload(api, a, space, root["item_id"], name="keep.txt")
    )
    item = api("GET", f"/v1/file-items/{first['file_id']}", headers=a).json()["item"]
    batch = api(
        "POST",
        f"/v1/file-items/{first['file_id']}/trash",
        headers=a,
        json={"expected_metadata_version": item["metadata_version"]},
    ).json()["trash_batch"]
    original = storage.delete_version
    reentered = False

    def overlap(version):
        nonlocal reentered
        if not reentered:
            reentered = True
            from sqlalchemy import select
            from vessel_service.files.jobs import process_purge
            from vessel_service.files.models import DrivePurgeJob

            with sessions() as session:
                pid = session.scalar(
                    select(DrivePurgeJob.purge_id).where(
                        DrivePurgeJob.batch_id == batch["batch_id"]
                    )
                )
            process_purge(sessions, storage, pid)
        original(version)

    storage.delete_version = overlap
    response = api(
        "POST",
        f"/v1/file-trash/{batch['batch_id']}/purge",
        headers=a,
        json={"expected_batch_version": batch["batch_version"]},
    )
    assert response.status_code == 202, response.text
    from vessel_service.files.models import DriveQuotaUsage

    with sessions() as session:
        assert session.get(DriveQuotaUsage, space).committed_bytes == 5


def test_superseded_worker_cannot_publish_or_ack_new_worker_lease(files_api):
    api, register, storage, sessions = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    upload = create_upload(api, a, space, root["item_id"])
    original = storage.verify

    def verifying(record, parts):
        result = original(record, parts)
        from sqlalchemy import select
        from vessel_service.files.models import DriveOutbox

        with sessions() as session:
            task = session.scalar(
                select(DriveOutbox).where(
                    DriveOutbox.business_key == "upload:" + record["upload_id"]
                )
            )
            task.attempts += 1
            task.lease_until = datetime.now(UTC) + timedelta(minutes=30)
            session.commit()
        return result

    storage.verify = verifying
    state = finish(api, a, storage, upload)
    assert storage.published == 0
    assert state["status"] == "verifying"
    from sqlalchemy import select
    from vessel_service.files.models import DriveOutbox

    with sessions() as session:
        task = session.scalar(
            select(DriveOutbox).where(
                DriveOutbox.business_key == "upload:" + upload["upload_id"]
            )
        )
        assert task.status == "running"
        assert task.attempts == 2


def test_stale_publisher_still_registers_orphan_for_cleanup(files_api):
    api, register, storage, sessions = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    upload = create_upload(api, a, space, root["item_id"])

    def publishing(record, verified):
        data = storage.incoming[record["upload_id"]]
        from sqlalchemy import select
        from vessel_service.files.models import DriveOutbox

        with sessions() as session:
            task = session.scalar(
                select(DriveOutbox).where(
                    DriveOutbox.business_key == "upload:" + record["upload_id"]
                )
            )
            task.attempts += 1
            session.commit()
        assert (
            api(
                "POST",
                f"/v1/file-uploads/{record['upload_id']}/cancel",
                headers=a,
                json={},
            ).status_code
            == 200
        )
        storage.objects[record["final_key"]] = data
        return {
            "bucket": "private-test",
            "object_key": record["final_key"],
            "oss_version_id": "sealed-version",
        }

    storage.publish = publishing
    assert finish(api, a, storage, upload)["status"] == "cancelled"
    assert storage.objects == {}


def test_purge_storage_failure_is_durable_and_worker_retries(files_api):
    api, register, storage, sessions = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    ready = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    item = api("GET", f"/v1/file-items/{ready['file_id']}", headers=a).json()["item"]
    batch = api(
        "POST",
        f"/v1/file-items/{item['item_id']}/trash",
        headers=a,
        json={"expected_metadata_version": item["metadata_version"]},
    ).json()["trash_batch"]
    storage.fail_delete = True
    purge = api(
        "POST",
        f"/v1/file-trash/{batch['batch_id']}/purge",
        headers=a,
        json={"expected_batch_version": batch["batch_version"]},
    )
    assert purge.status_code == 202, purge.text
    path = purge.json()["purge"]["status_url"]
    assert api("GET", path, headers=a).json()["purge"]["status"] == "failed"
    from sqlalchemy import select
    from vessel_service.files.jobs import process_jobs
    from vessel_service.files.models import DriveOutbox, DriveQuotaUsage

    with sessions() as session:
        task = session.scalar(select(DriveOutbox).where(DriveOutbox.kind == "purge"))
        assert task.status == "failed"
        task.available_at = datetime.now(UTC) - timedelta(seconds=1)
        assert session.get(DriveQuotaUsage, space).committed_bytes == 5
        late = list(
            session.scalars(
                select(DriveOutbox).where(
                    DriveOutbox.business_key.like("cleanup-late:%")
                )
            )
        )
        assert len(late) == 1
        assert late[0].status == "pending"
        session.commit()
    storage.fail_delete = False
    process_jobs(sessions, storage)
    assert api("GET", path, headers=a).json()["purge"]["status"] == "succeeded"
    with sessions() as session:
        assert session.get(DriveQuotaUsage, space).committed_bytes == 0


def test_version_restore_creates_revision_without_double_billing(files_api):
    api, register, storage, sessions = files_api
    a, space, _ = register("a")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    first = finish(api, a, storage, create_upload(api, a, space, root["item_id"]))
    item = api("GET", f"/v1/file-items/{first['file_id']}", headers=a).json()["item"]
    payload = {
        "mode": "new_version",
        "file_id": first["file_id"],
        "expected_current_version_id": first["version_id"],
        "expected_metadata_version": item["metadata_version"],
        "size_bytes": 5,
        "sha256": hashlib.sha256(b"world").hexdigest(),
        "content_type": "text/plain",
    }
    upload = api(
        "POST", f"/v1/spaces/{space}/file-uploads", headers=a, json=payload
    ).json()["upload"]
    new = finish(api, a, storage, upload, b"world")
    restored = api(
        "POST",
        f"/v1/files/{first['file_id']}/versions/{first['version_id']}/restore",
        headers=a,
        json={"expected_current_version_id": new["version_id"]},
    )
    assert restored.status_code == 200, restored.text
    assert restored.json()["file"]["sha256"] == hashlib.sha256(b"hello").hexdigest()
    assert restored.json()["version"]["version_id"] != first["version_id"]
    assert (
        len(
            api("GET", f"/v1/files/{first['file_id']}/versions", headers=a).json()[
                "versions"
            ]
        )
        == 3
    )
    from vessel_service.files.models import DriveQuotaUsage

    with sessions() as session:
        assert session.get(DriveQuotaUsage, space).committed_bytes == 10


def test_revoked_shared_editor_cannot_publish_inflight_upload(files_api):
    api, register, storage, _ = files_api
    a, space, _ = register("a")
    b, _, bid = register("b")
    root = api("GET", f"/v1/spaces/{space}/folders/root", headers=a).json()["folder"]
    folder = api(
        "POST",
        f"/v1/spaces/{space}/folders",
        headers=a,
        json={"name": "shared", "parent_folder_id": root["item_id"]},
    ).json()["folder"]
    grant = api(
        "POST",
        f"/v1/file-items/{folder['item_id']}/grants",
        headers=a,
        json={"grantee_user_id": bid, "role": "editor", "expected_acl_revision": 1},
    ).json()
    upload = create_upload(api, b, space, folder["item_id"])
    original = storage.publish

    def publishing(record, verified):
        result = original(record, verified)
        revoked = api(
            "DELETE",
            f"/v1/file-items/{folder['item_id']}/grants/{grant['grant']['grant_id']}",
            headers=a,
            json={"expected_acl_revision": grant["acl_revision"]},
        )
        assert revoked.status_code == 204
        return result

    storage.publish = publishing
    storage.incoming[upload["upload_id"]] = b"hello"
    response = api(
        "POST", f"/v1/file-uploads/{upload['upload_id']}/complete", headers=b, json={}
    )
    assert response.status_code == 202
    state = api("GET", f"/v1/file-uploads/{upload['upload_id']}", headers=a).json()[
        "upload"
    ]
    assert state["status"] == "failed"
    assert state["failure_code"] == "FILE_PERMISSION_REVOKED"
    assert (
        api("GET", f"/v1/folders/{folder['item_id']}/children", headers=a).json()[
            "items"
        ]
        == []
    )
    assert storage.objects == {}
