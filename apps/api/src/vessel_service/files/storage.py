"""Aliyun OSS boundary. No bucket configuration or credential files are mutated.

All arguments are trusted server records, never client-selected object locations.
Versioned final storage is preferred; explicit unversioned reuse seals private keys.
"""

from __future__ import annotations

import hashlib
import importlib
import os
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path
from urllib.parse import quote
from uuid import uuid4

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class FilesSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="VESSEL_FILES_", extra="ignore")
    oss_config_file: Path | None = None
    oss_endpoint: str = ""
    oss_region: str = ""
    oss_temp_bucket: str = ""
    oss_final_bucket: str = ""
    oss_ram_role: str = ""
    oss_prefix: str = "vessel-files"
    oss_allow_unversioned: bool = False
    upload_url_seconds: int = Field(default=600, ge=1, le=600)
    download_url_seconds: int = Field(default=60, ge=1, le=60)
    max_file_bytes: int = Field(default=512 * 1024 * 1024, gt=0, le=512 * 1024 * 1024)
    multipart_threshold_bytes: int = Field(default=16 * 1024 * 1024, gt=0)
    part_size_bytes: int = Field(default=8 * 1024 * 1024, ge=100 * 1024)
    space_quota_bytes: int = Field(default=10 * 1024**3, gt=0)


class StorageError(RuntimeError):
    def __init__(self, code="FILE_STORAGE_UNAVAILABLE"):
        self.code = code
        super().__init__(code)


def boundary(method):
    @wraps(method)
    def wrapped(*args, **kwargs):
        try:
            return method(*args, **kwargs)
        except StorageError:
            raise
        except Exception:
            # SDK errors can contain signed URLs or credentials. Do not propagate them.
            raise StorageError() from None

    return wrapped


def _version(result):
    return (
        getattr(result, "versionid", None)
        or getattr(result, "version_id", None)
        or result.headers.get("x-oss-version-id")
    )


def _exact(version):
    return version and version != "null"


def _missing(error):
    return getattr(error, "status", None) == 404 or isinstance(error, KeyError)


class OSSStorage:
    def __init__(self, settings: FilesSettings | None = None):
        self.settings = settings or FilesSettings()
        self._sdk = None
        self._buckets = {}

    def _config_values(self):
        if not self.settings.oss_config_file:
            return {}
        from dotenv.parser import parse_stream

        allowed = {
            "OSS_ENDPOINT",
            "OSS_REGION",
            "OSS_BUCKET",
            "OSS_BUCKET_NAME",
            "OSS_ACCESS_KEY_ID",
            "OSS_ACCESS_KEY_SECRET",
            "OSS_SESSION_TOKEN",
            "OSS_SECURITY_TOKEN",
        }
        values = {}
        with self.settings.oss_config_file.open(encoding="utf-8") as stream:
            for entry in parse_stream(stream):
                if entry.key in allowed:
                    if entry.error or entry.value is None:
                        raise StorageError()
                    values[entry.key] = entry.value
        return values

    def _connect(self):
        if self._sdk is not None:
            return
        s = self.settings
        config = self._config_values()
        for field, key in [
            ("oss_endpoint", "OSS_ENDPOINT"),
            ("oss_region", "OSS_REGION"),
        ]:
            if not getattr(s, field):
                value = config.get(key, "")
                if field == "oss_endpoint" and value and "://" not in value:
                    value = "https://" + value
                setattr(s, field, value)
        bucket = config.get("OSS_BUCKET") or config.get("OSS_BUCKET_NAME", "")
        s.oss_temp_bucket = s.oss_temp_bucket or bucket
        s.oss_final_bucket = s.oss_final_bucket or bucket
        if not all(
            (s.oss_endpoint, s.oss_region, s.oss_temp_bucket, s.oss_final_bucket)
        ) or not s.oss_endpoint.startswith("https://"):
            raise StorageError()
        sdk = importlib.import_module("oss2")
        if s.oss_ram_role:
            provider = sdk.credentials.EcsRamRoleCredentialsProvider(
                "http://100.100.100.200/latest/meta-data/ram/security-credentials/"
                + quote(s.oss_ram_role, safe="")
            )
        elif os.getenv("OSS_ACCESS_KEY_ID") and os.getenv("OSS_ACCESS_KEY_SECRET"):
            provider = sdk.credentials.EnvironmentVariableCredentialsProvider()
        elif config.get("OSS_ACCESS_KEY_ID") or config.get("OSS_ACCESS_KEY_SECRET"):
            if not config.get("OSS_ACCESS_KEY_ID") or not config.get(
                "OSS_ACCESS_KEY_SECRET"
            ):
                raise StorageError()
            provider = sdk.credentials.StaticCredentialsProvider(
                config["OSS_ACCESS_KEY_ID"],
                config["OSS_ACCESS_KEY_SECRET"],
                config.get("OSS_SESSION_TOKEN", config.get("OSS_SECURITY_TOKEN", "")),
            )
        else:
            provider = sdk.credentials.EnvironmentVariableCredentialsProvider()
        auth = sdk.ProviderAuthV4(provider)
        buckets = {
            name: sdk.Bucket(auth, s.oss_endpoint, name, region=s.oss_region)
            for name in {s.oss_temp_bucket, s.oss_final_bucket}
        }
        self._sdk, self._buckets = sdk, buckets

    def _check(self):
        self._connect()
        s = self.settings
        final = self._buckets[s.oss_final_bucket]
        final_status = final.get_bucket_versioning().status
        if final_status != "Enabled" and not (
            s.oss_allow_unversioned and final_status in (None, "")
        ):
            raise StorageError()
        temp = self._buckets[s.oss_temp_bucket]
        status = temp.get_bucket_versioning().status
        # Suspended retains null versions and is not a stable staging model.
        if status not in (None, "", "Enabled"):
            raise StorageError()
        return temp, final, status == "Enabled"

    def _keys(self, upload):
        temp = upload.get("temp_key")
        final = upload.get("final_key")
        if not temp or not final or temp == final:
            raise StorageError()
        return temp, final

    def _ttl(self, upload):
        ttl = self.settings.upload_url_seconds
        expiry = upload.get("expires_at")
        if expiry:
            if isinstance(expiry, str):
                expiry = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
            if expiry.tzinfo is None:
                expiry = expiry.replace(tzinfo=timezone.utc)
            ttl = min(ttl, int((expiry - datetime.now(timezone.utc)).total_seconds()))
        if ttl <= 0:
            raise StorageError("UPLOAD_STATE_CONFLICT")
        return ttl

    @boundary
    def start_upload(self, upload: dict) -> dict:
        temp, _, versioned = self._check()
        prefix = self.settings.oss_prefix.strip("/")
        result = {
            "temp_key": upload.get("temp_key") or f"{prefix}/uploads/{uuid4()}",
            "final_key": upload.get("final_key") or f"{prefix}/files/{uuid4()}",
            "oss_upload_id": upload.get("oss_upload_id"),
        }
        self._keys(result)
        if upload["transfer_mode"] == "multipart" and not result["oss_upload_id"]:
            headers = {
                "Content-Type": upload["content_type"],
                "x-oss-server-side-encryption": "AES256",
            }
            if not versioned:
                headers["x-oss-forbid-overwrite"] = "true"
            result["oss_upload_id"] = temp.init_multipart_upload(
                result["temp_key"], headers=headers
            ).upload_id
        return result

    @boundary
    def sign_parts(self, upload: dict, numbers: list[int]) -> list[dict]:
        temp, _, versioned = self._check()
        key, _ = self._keys(upload)
        count = upload["part_count"]
        if (
            not numbers
            or len(numbers) > 20
            or len(set(numbers)) != len(numbers)
            or any(type(n) is not int or n < 1 or n > count for n in numbers)
        ):
            raise StorageError("FILE_QUERY_INVALID")
        single = upload["transfer_mode"] == "single"
        if single and numbers != [1]:
            raise StorageError("FILE_QUERY_INVALID")
        ttl = self._ttl(upload)
        result = []
        for number in numbers:
            size = (
                upload["size_bytes"]
                if single
                else min(
                    upload["part_size_bytes"],
                    upload["size_bytes"] - (number - 1) * upload["part_size_bytes"],
                )
            )
            headers = {"Content-Length": str(size)}
            params = {}
            if single:
                headers["x-oss-server-side-encryption"] = "AES256"
                headers["Content-Type"] = upload["content_type"]
                if not versioned:
                    headers["x-oss-forbid-overwrite"] = "true"
            else:
                if not upload.get("oss_upload_id"):
                    raise StorageError()
                params = {
                    "uploadId": upload["oss_upload_id"],
                    "partNumber": str(number),
                }
            url = temp.sign_url(
                "PUT",
                key,
                ttl,
                headers=headers,
                params=params,
                additional_headers=[h.lower() for h in headers],
            )
            result.append(
                {
                    "part_number": number,
                    "method": "PUT",
                    "url": url,
                    "headers": headers,
                    "expires_at": datetime.now(timezone.utc) + timedelta(seconds=ttl),
                    "size_bytes": size,
                }
            )
        return result

    def _read_verified(self, bucket, key, upload, source_version=None):
        params = {"versionId": source_version} if _exact(source_version) else None
        head = bucket.head_object(key, params=params)
        version = source_version or _version(head)
        params = {"versionId": version} if _exact(version) else None
        headers = None if params else {"If-Match": head.etag}
        if head.content_length != upload["size_bytes"]:
            raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        stream = bucket.get_object(key, params=params, headers=headers)
        digest, size = hashlib.sha256(), 0
        try:
            while chunk := stream.read(1024 * 1024):
                size += len(chunk)
                if size > upload["size_bytes"]:
                    raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
                digest.update(chunk)
        finally:
            close = getattr(stream, "close", None)
            if close:
                close()
        if (
            size != upload["size_bytes"]
            or digest.hexdigest() != upload["sha256"].lower()
        ):
            raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        return {
            "size_bytes": size,
            "sha256": digest.hexdigest(),
            "crc64": str(
                getattr(head, "server_crc", None)
                or head.headers.get("x-oss-hash-crc64ecma", "")
            ),
            "source_version_id": version,
            "source_etag": head.etag,
        }

    def _complete(self, temp, key, upload, parts, versioned):
        expected = upload["part_count"]
        if len(parts) != expected or [p["part_number"] for p in parts] != list(
            range(1, expected + 1)
        ):
            raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        remote, marker = [], ""
        while True:
            result = temp.list_parts(
                key, upload["oss_upload_id"], marker=marker, max_parts=1000
            )
            remote.extend(result.parts)
            if not result.is_truncated:
                break
            marker = result.next_marker
        if len(remote) != expected:
            raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        for receipt, actual in zip(parts, remote):
            size = min(
                upload["part_size_bytes"],
                upload["size_bytes"]
                - (actual.part_number - 1) * upload["part_size_bytes"],
            )
            if (
                actual.part_number != receipt["part_number"]
                or actual.etag.strip('"') != receipt["etag"].strip('"')
                or actual.size != size
            ):
                raise StorageError("UPLOAD_CHECKSUM_MISMATCH")
        infos = [self._sdk.models.PartInfo(p.part_number, p.etag) for p in remote]
        headers = {} if versioned else {"x-oss-forbid-overwrite": "true"}
        return _version(
            temp.complete_multipart_upload(
                key, upload["oss_upload_id"], infos, headers=headers
            )
        )

    @boundary
    def verify(self, upload: dict, parts: list[dict]) -> dict:
        temp, _, versioned = self._check()
        key, _ = self._keys(upload)
        source_version = upload.get("source_version_id")
        if upload["transfer_mode"] == "multipart" and not source_version:
            try:
                source_version = self._complete(temp, key, upload, parts, versioned)
            except Exception as error:
                # A lost Complete response leaves no upload session; retry validates the object.
                if getattr(error, "code", None) != "NoSuchUpload":
                    raise
        verified = self._read_verified(temp, key, upload, source_version)
        if versioned and not _exact(verified["source_version_id"]):
            raise StorageError()
        return verified

    @boundary
    def publish(self, upload: dict, verified: dict) -> dict:
        temp, final, versioned = self._check()
        key, target = self._keys(upload)
        # Stable private key allows recovery after a Copy response or DB commit is lost.
        try:
            existing = final.head_object(target)
        except Exception as error:
            if not _missing(error):
                raise
        else:
            version = _version(existing)
            if not _exact(version) and not self.settings.oss_allow_unversioned:
                raise StorageError()
            self._guard_final(target, version)
            self._read_verified(final, target, upload, version)
            return {
                "bucket": self.settings.oss_final_bucket,
                "object_key": target,
                "oss_version_id": version,
            }
        source_version = verified.get("source_version_id")
        if versioned and not _exact(source_version):
            raise StorageError()
        params = {"versionId": source_version} if _exact(source_version) else None
        headers = {
            "x-oss-metadata-directive": "COPY",
            "x-oss-server-side-encryption": "AES256",
        }
        final_status = final.get_bucket_versioning().status
        if final_status != "Enabled":
            self._guard_final(target, "null")
            headers["x-oss-forbid-overwrite"] = "true"
        if not params:
            headers["x-oss-copy-source-if-match"] = verified["source_etag"]
        copied = final.copy_object(
            self.settings.oss_temp_bucket, key, target, params=params, headers=headers
        )
        version = _version(copied)
        if not _exact(version) and final_status == "Enabled":
            raise StorageError()
        version = version or "null"
        # Required also for unversioned staging: seal destination first, then validate it.
        self._read_verified(final, target, upload, version)
        if final.get_bucket_versioning().status != final_status:
            raise StorageError()
        return {
            "bucket": self.settings.oss_final_bucket,
            "object_key": target,
            "oss_version_id": version,
        }

    def _guard_final(self, key, version):
        if not _exact(version):
            prefix = self.settings.oss_prefix.strip("/") + "/files/"
            if (
                not self.settings.oss_allow_unversioned
                or not key.startswith(prefix)
                or key == prefix
            ):
                raise StorageError()

    def _final_version(self, version):
        self._connect()
        if version["bucket"] != self.settings.oss_final_bucket:
            raise StorageError()
        self._guard_final(version["object_key"], version.get("oss_version_id"))
        params = (
            {"versionId": version["oss_version_id"]}
            if _exact(version.get("oss_version_id"))
            else {}
        )
        return self._buckets[version["bucket"]], params

    @boundary
    def sign_download(self, version: dict, filename: str) -> dict:
        bucket, params = self._final_version(version)
        safe = "".join(c for c in filename if ord(c) >= 32 and ord(c) != 127)
        params["response-content-disposition"] = (
            "attachment; filename=\"download\"; filename*=UTF-8''"
            + quote(safe, safe="")
        )
        ttl = self.settings.download_url_seconds
        return {
            "url": bucket.sign_url("GET", version["object_key"], ttl, params=params),
            "expires_at": datetime.now(timezone.utc) + timedelta(seconds=ttl),
        }

    @boundary
    def cleanup_upload(self, upload: dict):
        self._connect()
        temp = self._buckets[self.settings.oss_temp_bucket]
        key, _ = self._keys(upload)
        if upload.get("oss_upload_id"):
            try:
                temp.abort_multipart_upload(key, upload["oss_upload_id"])
            except Exception as error:
                if getattr(error, "code", None) != "NoSuchUpload":
                    raise
        for session in self._sdk.MultipartUploadIterator(temp, prefix=key):
            if (
                session.key == key
                and session.upload_id
                and session.upload_id != upload.get("oss_upload_id")
            ):
                try:
                    temp.abort_multipart_upload(key, session.upload_id)
                except Exception as error:
                    if getattr(error, "code", None) != "NoSuchUpload":
                        raise
        version = upload.get("source_version_id")
        if _exact(version):
            temp.delete_object(key, params={"versionId": version})
        elif temp.get_bucket_versioning().status in (None, ""):
            temp.delete_object(key)
        if temp.get_bucket_versioning().status == "Enabled":
            marker, version_marker = "", ""
            while True:
                result = temp.list_object_versions(
                    prefix=key,
                    key_marker=marker,
                    versionid_marker=version_marker,
                    max_keys=1000,
                )
                for entry in result.versions + result.delete_marker:
                    if entry.key == key:
                        temp.delete_object(key, params={"versionId": entry.versionid})
                if not result.is_truncated:
                    break
                marker, version_marker = (
                    result.next_key_marker,
                    result.next_versionid_marker,
                )
        # Repeat cleanup after signed capabilities expire to remove late arrivals.

    @boundary
    def publication_versions(self, upload: dict) -> list[dict]:
        """Read exact private publication versions for terminal-job reconciliation."""
        self._connect()
        _, key = self._keys(upload)
        prefix = self.settings.oss_prefix.strip("/") + "/files/"
        if not key.startswith(prefix) or key == prefix:
            raise StorageError()
        bucket_name = self.settings.oss_final_bucket
        bucket = self._buckets[bucket_name]
        status = bucket.get_bucket_versioning().status

        def reference(version):
            return {"bucket": bucket_name, "object_key": key, "oss_version_id": version}

        if status == "Enabled":
            versions = []
            marker, version_marker = "", ""
            while True:
                page = bucket.list_object_versions(
                    prefix=key,
                    key_marker=marker,
                    versionid_marker=version_marker,
                    max_keys=1000,
                )
                versions.extend(
                    reference(entry.versionid)
                    for entry in page.versions
                    if entry.key == key
                )
                if not page.is_truncated:
                    return versions
                marker, version_marker = (
                    page.next_key_marker,
                    page.next_versionid_marker,
                )
        if status not in (None, "") or not self.settings.oss_allow_unversioned:
            raise StorageError()
        try:
            bucket.head_object(key)
        except Exception as error:
            if _missing(error):
                return []
            raise
        return [reference("null")]

    @boundary
    def delete_version(self, version: dict):
        bucket, params = self._final_version(version)
        bucket.delete_object(version["object_key"], params=params or None)
