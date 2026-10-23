import hashlib
import io
import sys
from types import SimpleNamespace

import pytest
from vessel_service.files.storage import FilesSettings, OSSStorage, StorageError


class RemoteBucket:
    def __init__(self, name, status="Enabled"):
        self.bucket_name = name
        self.status = status
        self.objects = {}
        self.calls = []
        self.serial = 0
        self.copy_hook = None

    def put(self, key, body):
        self.serial += 1
        version = str(self.serial) if self.status == "Enabled" else "null"
        self.objects.setdefault(key, {})[version] = body
        return version

    def get_bucket_versioning(self):
        return SimpleNamespace(status=self.status)

    def head_object(self, key, params=None):
        version = (params or {}).get("versionId") or list(self.objects[key])[-1]
        body = self.objects[key][version]
        return SimpleNamespace(
            headers={"x-oss-version-id": version},
            content_length=len(body),
            etag=hashlib.md5(body).hexdigest(),
            server_crc=123,
        )

    def get_object(self, key, params=None, headers=None):
        self.calls.append(("get", key, params, headers))
        head = self.head_object(key, params)
        return io.BytesIO(self.objects[key][head.headers["x-oss-version-id"]])

    def sign_url(self, method, key, expires, **kwargs):
        self.calls.append(("sign", method, key, expires, kwargs))
        return "https://mock.invalid/signed"

    def copy_object(self, bucket, key, target, headers=None, params=None):
        self.calls.append(("copy", bucket, key, target, headers, params))
        if self.copy_hook:
            self.copy_hook()
        source = BUCKETS[bucket]
        version = source.head_object(key, params).headers["x-oss-version-id"]
        result = self.put(target, source.objects[key][version])
        return SimpleNamespace(headers={"x-oss-version-id": result})

    def list_multipart_uploads(self, **kwargs):
        return SimpleNamespace(
            upload_list=[],
            prefix_list=[],
            next_upload_id_marker="",
            next_key_marker="",
            is_truncated=False,
        )

    def list_object_versions(self, **kwargs):
        return SimpleNamespace(
            versions=[
                SimpleNamespace(key=k, versionid=v)
                for k, versions in self.objects.items()
                for v in versions
            ],
            delete_marker=[],
            is_truncated=False,
        )

    def init_multipart_upload(self, key, headers=None):
        self.calls.append(("init", key, headers))
        return SimpleNamespace(upload_id="multipart-1")

    def list_parts(self, key, upload_id, **kwargs):
        self.calls.append(("list", key, upload_id))
        return SimpleNamespace(
            parts=[SimpleNamespace(part_number=1, etag="etag1", size=3)],
            is_truncated=False,
        )

    def complete_multipart_upload(self, key, upload_id, parts, headers=None):
        self.calls.append(("complete", key, upload_id, parts))
        v = self.put(key, b"abc")
        return SimpleNamespace(headers={"x-oss-version-id": v})

    def abort_multipart_upload(self, key, upload_id):
        self.calls.append(("abort", key, upload_id))

    def delete_object(self, key, params=None):
        self.calls.append(("delete", key, params))
        if params:
            self.objects.get(key, {}).pop(params["versionId"], None)
        else:
            self.objects.pop(key, None)


BUCKETS = {}


@pytest.fixture
def storage(monkeypatch):
    from oss2 import MultipartUploadIterator
    from oss2.models import PartInfo

    BUCKETS.clear()
    BUCKETS.update(stage=RemoteBucket("stage"), final=RemoteBucket("final"))
    sdk = SimpleNamespace(
        Bucket=lambda auth, endpoint, name, **kw: BUCKETS[name],
        ProviderAuthV4=lambda provider: provider,
        models=SimpleNamespace(PartInfo=PartInfo),
        MultipartUploadIterator=MultipartUploadIterator,
        credentials=SimpleNamespace(
            EnvironmentVariableCredentialsProvider=lambda: object(),
            EcsRamRoleCredentialsProvider=lambda role: object(),
        ),
    )
    monkeypatch.setitem(sys.modules, "oss2", sdk)
    return OSSStorage(
        FilesSettings(
            oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
            oss_region="cn-hangzhou",
            oss_temp_bucket="stage",
            oss_final_bucket="final",
        )
    )


def upload(**kwargs):
    return dict(
        upload_id="id",
        space_id="space",
        temp_key="vessel-test/uploads/id",
        final_key="vessel-test/files/version",
        size_bytes=3,
        sha256=hashlib.sha256(b"abc").hexdigest(),
        content_type="text/plain",
        transfer_mode="single",
        part_count=1,
        part_size_bytes=8,
        **kwargs,
    )


def test_missing_config_is_lazy():
    s = OSSStorage(FilesSettings(_env_file=None))
    with pytest.raises(StorageError, match="FILE_STORAGE_UNAVAILABLE"):
        s.start_upload(upload())


def test_signed_put_cannot_omit_overwrite_header(storage):
    BUCKETS["stage"].status = None
    instruction = storage.sign_parts(upload(), [1])[0]
    assert instruction["headers"]["x-oss-forbid-overwrite"] == "true"
    call = BUCKETS["stage"].calls[-1]
    assert call[4]["headers"] == instruction["headers"]
    assert "content-length" in call[4]["additional_headers"]
    assert instruction["size_bytes"] == 3
    assert instruction["headers"]["x-oss-server-side-encryption"] == "AES256"


def test_versioned_staging_verify_and_copy_use_same_exact_version(storage):
    u = upload()
    source = BUCKETS["stage"].put(u["temp_key"], b"abc")
    verified = storage.verify(u, [])
    BUCKETS["stage"].put(u["temp_key"], b"bad")
    published = storage.publish(u, verified)
    assert verified["source_version_id"] == source
    assert BUCKETS["stage"].calls[-1][2] == {"versionId": source}
    assert (
        BUCKETS["final"].objects[u["final_key"]][published["oss_version_id"]] == b"abc"
    )
    assert BUCKETS["final"].calls[0][-1] == {"versionId": source}
    assert BUCKETS["final"].calls[0][4]["x-oss-server-side-encryption"] == "AES256"


def test_verify_rejects_sha256_mismatch(storage):
    u = upload()
    BUCKETS["stage"].put(u["temp_key"], b"bad")
    with pytest.raises(StorageError, match="UPLOAD_CHECKSUM_MISMATCH"):
        storage.verify(u, [])


def test_unversioned_source_race_reverified_before_publish(storage):
    u = upload()
    BUCKETS["stage"].status = None
    BUCKETS["stage"].put(u["temp_key"], b"abc")
    verified = storage.verify(u, [])
    BUCKETS["final"].copy_hook = lambda: BUCKETS["stage"].put(u["temp_key"], b"bad")
    with pytest.raises(StorageError, match="UPLOAD_CHECKSUM_MISMATCH"):
        storage.publish(u, verified)


def test_final_bucket_must_be_enabled(storage):
    BUCKETS["final"].status = "Suspended"
    with pytest.raises(StorageError, match="FILE_STORAGE_UNAVAILABLE"):
        storage.start_upload(upload())


def test_download_and_delete_are_exact_version(storage):
    version = {"bucket": "final", "object_key": "private/key", "oss_version_id": "42"}
    storage.sign_download(version, "中文\r\nreport.pdf")
    call = BUCKETS["final"].calls[-1]
    assert call[4]["params"]["versionId"] == "42"
    assert "\r" not in call[4]["params"]["response-content-disposition"]
    storage.delete_version(version)
    assert BUCKETS["final"].calls[-1] == ("delete", "private/key", {"versionId": "42"})


def test_missing_exact_download_version_denied(storage):
    with pytest.raises(StorageError):
        storage.sign_download(
            {"bucket": "final", "object_key": "key", "oss_version_id": "null"}, "file"
        )


def test_multipart_client_only_signs_upload_part(storage):
    u = upload()
    u["transfer_mode"] = "multipart"
    started = storage.start_upload(u)
    u.update(started)
    assert BUCKETS["stage"].calls[-1][2]["x-oss-server-side-encryption"] == "AES256"
    instruction = storage.sign_parts(u, [1])[0]
    assert BUCKETS["stage"].calls[-1][4]["params"] == {
        "uploadId": "multipart-1",
        "partNumber": "1",
    }
    result = storage.verify(u, [{"part_number": 1, "etag": "etag1"}])
    assert result["sha256"] == u["sha256"]
    assert any(c[0] == "complete" for c in BUCKETS["stage"].calls)


def test_multipart_receipt_and_size_are_checked(storage):
    u = upload()
    u.update(transfer_mode="multipart", oss_upload_id="multipart-1")
    with pytest.raises(StorageError, match="UPLOAD_CHECKSUM_MISMATCH"):
        storage.verify(u, [{"part_number": 1, "etag": "forged"}])
    assert not any(c[0] == "complete" for c in BUCKETS["stage"].calls)


def test_cleanup_uses_exact_staging_version(storage):
    u = upload(source_version_id="33")
    storage.cleanup_upload(u)
    assert BUCKETS["stage"].calls[-1] == ("delete", u["temp_key"], {"versionId": "33"})


def test_sign_rejects_invalid_part_number(storage):
    with pytest.raises(StorageError):
        storage.sign_parts(upload(), [2])


def test_real_sdk_can_sign_required_headers_without_network(monkeypatch):
    import oss2

    monkeypatch.setenv("OSS_ACCESS_KEY_ID", "test-id")
    monkeypatch.setenv("OSS_ACCESS_KEY_SECRET", "test-secret")
    monkeypatch.setattr(
        oss2.Bucket,
        "get_bucket_versioning",
        lambda self: SimpleNamespace(status="Enabled"),
    )
    s = OSSStorage(
        FilesSettings(
            oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
            oss_region="cn-hangzhou",
            oss_temp_bucket="stage",
            oss_final_bucket="final",
        )
    )
    instruction = s.sign_parts(upload(), [1])[0]
    assert "x-oss-signature=" in instruction["url"]
    assert "content-length" in instruction["url"]


def test_publication_retry_adopts_verified_private_version(storage):
    u = upload()
    BUCKETS["stage"].put(u["temp_key"], b"abc")
    verified = storage.verify(u, [])
    first = storage.publish(u, verified)
    second = storage.publish(u, verified)
    assert first == second
    assert len([c for c in BUCKETS["final"].calls if c[0] == "copy"]) == 1


def test_cleanup_late_replay_versions_never_touches_prefix_neighbor(storage):
    u = upload()
    bucket = BUCKETS["stage"]
    first = bucket.put(u["temp_key"], b"abc")
    second = bucket.put(u["temp_key"], b"bad")
    neighbor = u["temp_key"] + "-other"
    bucket.put(neighbor, b"protected")
    bucket.list_object_versions = lambda **kw: SimpleNamespace(
        versions=[
            SimpleNamespace(key=k, versionid=v)
            for k, versions in bucket.objects.items()
            for v in versions
        ],
        delete_marker=[],
        is_truncated=False,
    )
    storage.cleanup_upload(u)
    assert not bucket.objects[u["temp_key"]]
    assert bucket.objects[neighbor]


def test_unversioned_final_explicit_opt_in_sealed_and_reconciled(storage):
    storage.settings.oss_allow_unversioned = True
    storage.settings.oss_prefix = "vessel-test"
    BUCKETS["stage"].status = None
    BUCKETS["final"].status = None
    u = upload()
    BUCKETS["stage"].put(u["temp_key"], b"abc")
    verified = storage.verify(u, [])
    result = storage.publish(u, verified)
    assert result["oss_version_id"] == "null"
    assert BUCKETS["final"].calls[0][4]["x-oss-forbid-overwrite"] == "true"
    assert storage.publish(u, verified) == result
    storage.sign_download(result, "file.txt")
    assert "versionId" not in BUCKETS["final"].calls[-1][4]["params"]
    storage.delete_version(result)
    assert BUCKETS["final"].calls[-1] == ("delete", u["final_key"], None)


def test_unversioned_final_cannot_sign_or_delete_foreign_keys(storage):
    storage.settings.oss_allow_unversioned = True
    with pytest.raises(StorageError):
        storage.sign_download(
            {
                "bucket": "final",
                "object_key": "existing-agent/file",
                "oss_version_id": "null",
            },
            "file",
        )


def test_reuse_config_file_without_environment_mutation(storage, tmp_path, monkeypatch):
    import os

    config = tmp_path / ".env"
    config.write_text(
        "OSS_ENDPOINT=oss-cn-beijing.aliyuncs.com\nOSS_REGION=cn-beijing\nOSS_BUCKET_NAME=stage\nOSS_ACCESS_KEY_ID=dummy\nOSS_ACCESS_KEY_SECRET=dummy-secret\nUNRELATED_TOKEN=ignored\n"
    )
    sdk = sys.modules["oss2"]
    sdk.credentials.StaticCredentialsProvider = lambda key, secret, token: (
        SimpleNamespace(key=key, secret=secret)
    )
    before = dict(os.environ)
    s = OSSStorage(FilesSettings(oss_config_file=config, oss_final_bucket="final"))
    s.start_upload(upload())
    assert s.settings.oss_endpoint == "https://oss-cn-beijing.aliyuncs.com"
    assert s.settings.oss_temp_bucket == "stage"
    assert s.settings.oss_final_bucket == "final"
    assert os.environ == before
    assert "dummy-secret" not in repr(s.settings)


@pytest.mark.parametrize(
    "body",
    [
        "OSS_ACCESS_KEY_ID=partial\n",
        "OSS_ENDPOINT=http://unsafe.invalid\nOSS_REGION=r\nOSS_BUCKET=b\nOSS_ACCESS_KEY_ID=x\nOSS_ACCESS_KEY_SECRET=y\n",
    ],
)
def test_invalid_config_is_sanitized(tmp_path, body):
    config = tmp_path / ".env"
    config.write_text(body)
    with pytest.raises(StorageError, match="FILE_STORAGE_UNAVAILABLE"):
        OSSStorage(FilesSettings(oss_config_file=config)).start_upload(upload())


def test_explicit_settings_override_config_file(storage, tmp_path):
    config = tmp_path / ".env"
    config.write_text(
        "OSS_ENDPOINT=wrong.invalid\nOSS_REGION=wrong\nOSS_BUCKET=wrong\n"
    )
    storage.settings.oss_config_file = config
    storage.start_upload(upload())
    assert storage.settings.oss_region == "cn-hangzhou"
    assert storage.settings.oss_temp_bucket == "stage"


def test_unversioned_final_existing_different_content_never_overwritten(storage):
    storage.settings.oss_allow_unversioned = True
    storage.settings.oss_prefix = "vessel-test"
    BUCKETS["stage"].status = None
    BUCKETS["final"].status = None
    u = upload()
    BUCKETS["stage"].put(u["temp_key"], b"abc")
    verified = storage.verify(u, [])
    BUCKETS["final"].put(u["final_key"], b"bad")
    with pytest.raises(StorageError, match="UPLOAD_CHECKSUM_MISMATCH"):
        storage.publish(u, verified)
    assert BUCKETS["final"].objects[u["final_key"]]["null"] == b"bad"
    assert not any(c[0] == "copy" for c in BUCKETS["final"].calls)


def test_unversioned_ready_key_is_unaffected_by_upload_replay(storage):
    storage.settings.oss_allow_unversioned = True
    storage.settings.oss_prefix = "vessel-test"
    BUCKETS["stage"].status = None
    BUCKETS["final"].status = None
    u = upload()
    BUCKETS["stage"].put(u["temp_key"], b"abc")
    result = storage.publish(u, storage.verify(u, []))
    BUCKETS["stage"].put(u["temp_key"], b"bad")
    storage.sign_download(result, "file")
    call = BUCKETS["final"].calls[-1]
    assert call[2] == result["object_key"]
    assert BUCKETS["final"].objects[call[2]]["null"] == b"abc"


def test_publication_versions_lists_exact_key_without_mutation(storage):
    storage.settings.oss_prefix = "vessel-test"
    u = upload()
    bucket = BUCKETS["final"]
    first = bucket.put(u["final_key"], b"abc")
    second = bucket.put(u["final_key"], b"abc")
    bucket.put(u["final_key"] + "-neighbor", b"protected")
    snapshot = {key: dict(versions) for key, versions in bucket.objects.items()}
    result = storage.publication_versions(u)
    assert result == [
        {"bucket": "final", "object_key": u["final_key"], "oss_version_id": first},
        {"bucket": "final", "object_key": u["final_key"], "oss_version_id": second},
    ]
    assert bucket.objects == snapshot
    assert not any(
        c[0] in ("copy", "delete", "abort", "complete") for c in bucket.calls
    )


def test_publication_versions_unversioned_missing_then_present(storage):
    storage.settings.oss_allow_unversioned = True
    storage.settings.oss_prefix = "vessel-test"
    BUCKETS["final"].status = None
    u = upload()
    assert storage.publication_versions(u) == []
    BUCKETS["final"].put(u["final_key"], b"abc")
    assert storage.publication_versions(u) == [
        {"bucket": "final", "object_key": u["final_key"], "oss_version_id": "null"}
    ]


def test_publication_versions_rejects_foreign_final_key(storage):
    u = upload()
    u["final_key"] = "agent-existing/private"
    with pytest.raises(StorageError):
        storage.publication_versions(u)
    assert BUCKETS["final"].calls == []


def test_publication_versions_paginates_and_excludes_delete_markers(storage):
    storage.settings.oss_prefix = "vessel-test"
    u = upload()
    bucket = BUCKETS["final"]
    calls = []

    def notes(**kwargs):
        calls.append(kwargs)
        if not kwargs["key_marker"]:
            return SimpleNamespace(
                versions=[SimpleNamespace(key=u["final_key"], versionid="1")],
                delete_marker=[
                    SimpleNamespace(key=u["final_key"], versionid="deleted")
                ],
                is_truncated=True,
                next_key_marker=u["final_key"],
                next_versionid_marker="1",
            )
        return SimpleNamespace(
            versions=[SimpleNamespace(key=u["final_key"], versionid="2")],
            delete_marker=[],
            is_truncated=False,
        )

    bucket.list_object_versions = notes
    assert [v["oss_version_id"] for v in storage.publication_versions(u)] == ["1", "2"]
    assert calls[1]["key_marker"] == u["final_key"]
    assert calls[1]["versionid_marker"] == "1"


def test_cleanup_discovers_unrecorded_multipart_sessions_exact_key(storage):
    u = upload(oss_upload_id="saved")
    bucket = BUCKETS["stage"]
    bucket.list_multipart_uploads = lambda **kw: SimpleNamespace(
        upload_list=[
            SimpleNamespace(key=u["temp_key"], upload_id="saved"),
            SimpleNamespace(key=u["temp_key"], upload_id="lost"),
            SimpleNamespace(key=u["temp_key"] + "-neighbor", upload_id="protected"),
        ],
        prefix_list=[],
        next_upload_id_marker="",
        next_key_marker="",
        is_truncated=False,
    )
    storage.cleanup_upload(u)
    assert bucket.calls.count(("abort", u["temp_key"], "saved")) == 1
    assert ("abort", u["temp_key"], "lost") in bucket.calls
    assert not any(c[0] == "abort" and c[2] == "protected" for c in bucket.calls)


def test_settings_hard_file_limit_and_default_namespace():
    from pydantic import ValidationError

    assert FilesSettings().oss_prefix == "vessel-files"
    with pytest.raises(ValidationError):
        FilesSettings(max_file_bytes=512 * 1024**2 + 1)
