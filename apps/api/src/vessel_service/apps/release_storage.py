"""Private storage adapters for immutable App release archives and assets."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Protocol
from urllib.parse import quote

from vessel_service.apps.h5_release import ValidatedH5Package


class AppReleaseStorageError(RuntimeError):
    def __init__(self, code: str = "APP_RELEASE_STORAGE_UNAVAILABLE"):
        self.code = code
        super().__init__(code)


class AppReleaseStorage(Protocol):
    def put_draft(self, key: str, archive: bytes) -> None: ...
    def get_draft(self, key: str) -> bytes: ...
    def delete_draft(self, key: str) -> None: ...
    def publish_tree(self, prefix: str, package: ValidatedH5Package) -> None: ...
    def get_published(self, prefix: str, path: str) -> bytes | None: ...


def _key_path(key: str, *, prefix: bool = False) -> PurePosixPath:
    if not isinstance(key, str) or not key.startswith("vessel-apps/"):
        raise AppReleaseStorageError()
    normalized = key.rstrip("/") if prefix else key
    path = PurePosixPath(normalized)
    if (not normalized or path.is_absolute() or ".." in path.parts
            or any(not part or part == "." for part in path.parts)):
        raise AppReleaseStorageError()
    return path


def _asset_path(path: str) -> PurePosixPath:
    value = PurePosixPath(path)
    if (not path or value.is_absolute() or ".." in value.parts
            or any(not part or part == "." for part in value.parts)):
        raise AppReleaseStorageError()
    return value


class LocalAppReleaseStorage:
    """Filesystem storage used by development and test. Assets are never mounted."""

    def __init__(self, root: Path):
        self.root = Path(root)

    def _path(self, key: str, *, prefix: bool = False) -> Path:
        relative = _key_path(key, prefix=prefix)
        destination = (self.root / relative.as_posix()).resolve()
        root = self.root.resolve()
        if not destination.is_relative_to(root):
            raise AppReleaseStorageError()
        return destination

    def put_draft(self, key: str, archive: bytes) -> None:
        if not isinstance(archive, bytes):
            raise AppReleaseStorageError()
        destination = self._path(key)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.tmp")
        try:
            temporary.write_bytes(archive)
            temporary.replace(destination)
        except OSError as error:
            temporary.unlink(missing_ok=True)
            raise AppReleaseStorageError() from error

    def get_draft(self, key: str) -> bytes:
        try:
            return self._path(key).read_bytes()
        except FileNotFoundError as error:
            raise AppReleaseStorageError("APP_RELEASE_DRAFT_NOT_FOUND") from error
        except OSError as error:
            raise AppReleaseStorageError() from error

    def delete_draft(self, key: str) -> None:
        try:
            self._path(key).unlink(missing_ok=True)
        except OSError as error:
            raise AppReleaseStorageError() from error

    def publish_tree(self, prefix: str, package: ValidatedH5Package) -> None:
        destination_root = self._path(prefix, prefix=True)
        for source in sorted(candidate for candidate in package.root.rglob("*") if candidate.is_file()):
            relative = source.relative_to(package.root)
            destination = (destination_root / relative).resolve()
            if not destination.is_relative_to(destination_root.resolve()):
                raise AppReleaseStorageError()
            contents = source.read_bytes()
            destination.parent.mkdir(parents=True, exist_ok=True)
            try:
                with destination.open("xb") as target:
                    target.write(contents)
            except FileExistsError:
                try:
                    if destination.read_bytes() != contents:
                        raise AppReleaseStorageError("APP_RELEASE_STORAGE_CONFLICT")
                except OSError as error:
                    raise AppReleaseStorageError() from error
            except OSError as error:
                raise AppReleaseStorageError() from error

    def get_published(self, prefix: str, path: str) -> bytes | None:
        destination_root = self._path(prefix, prefix=True)
        relative = _asset_path(path)
        destination = (destination_root / relative).resolve()
        if not destination.is_relative_to(destination_root.resolve()):
            raise AppReleaseStorageError()
        try:
            return destination.read_bytes()
        except FileNotFoundError:
            return None
        except OSError as error:
            raise AppReleaseStorageError() from error


class OSSAppReleaseStorage:
    """Private OSS adapter. It accepts only server-derived Vessel release keys."""

    def __init__(self, settings):
        self.settings = settings
        self._sdk = None
        self._draft_bucket = None
        self._release_bucket = None

    def _connect(self) -> None:
        if self._sdk is not None:
            return
        try:
            import importlib
            import os
            from dotenv.parser import parse_stream

            values = {}
            config_path = self.settings.oss_config_file
            if config_path:
                allowed = {
                    "OSS_ENDPOINT", "OSS_REGION", "OSS_BUCKET", "OSS_BUCKET_NAME",
                    "OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET", "OSS_SESSION_TOKEN", "OSS_SECURITY_TOKEN",
                }
                with Path(config_path).open(encoding="utf-8") as stream:
                    for entry in parse_stream(stream):
                        if entry.key in allowed and not entry.error and entry.value is not None:
                            values[entry.key] = entry.value
            endpoint = self.settings.oss_endpoint or values.get("OSS_ENDPOINT", "")
            if endpoint and "://" not in endpoint:
                endpoint = "https://" + endpoint
            region = self.settings.oss_region or values.get("OSS_REGION", "")
            bucket = values.get("OSS_BUCKET") or values.get("OSS_BUCKET_NAME", "")
            draft_bucket = self.settings.oss_temp_bucket or bucket
            release_bucket = self.settings.oss_final_bucket or bucket
            if not all((endpoint, region, draft_bucket, release_bucket)) or not endpoint.startswith("https://"):
                raise AppReleaseStorageError()
            sdk = importlib.import_module("oss2")
            if self.settings.oss_ram_role:
                provider = sdk.credentials.EcsRamRoleCredentialsProvider(
                    "http://100.100.100.200/latest/meta-data/ram/security-credentials/" + quote(self.settings.oss_ram_role, safe="")
                )
            elif os.getenv("OSS_ACCESS_KEY_ID") and os.getenv("OSS_ACCESS_KEY_SECRET"):
                provider = sdk.credentials.EnvironmentVariableCredentialsProvider()
            elif values.get("OSS_ACCESS_KEY_ID") and values.get("OSS_ACCESS_KEY_SECRET"):
                provider = sdk.credentials.StaticCredentialsProvider(
                    values["OSS_ACCESS_KEY_ID"], values["OSS_ACCESS_KEY_SECRET"],
                    values.get("OSS_SESSION_TOKEN", values.get("OSS_SECURITY_TOKEN", "")),
                )
            else:
                provider = sdk.credentials.EnvironmentVariableCredentialsProvider()
            auth = sdk.ProviderAuthV4(provider)
            self._sdk = sdk
            self._draft_bucket = sdk.Bucket(auth, endpoint, draft_bucket, region=region)
            self._release_bucket = sdk.Bucket(auth, endpoint, release_bucket, region=region)
        except AppReleaseStorageError:
            raise
        except Exception as error:
            raise AppReleaseStorageError() from error

    def _check_release_bucket(self) -> str | None:
        self._connect()
        try:
            status = self._release_bucket.get_bucket_versioning().status
            if status != "Enabled" and not (self.settings.oss_allow_unversioned and status in (None, "")):
                raise AppReleaseStorageError()
            return status
        except AppReleaseStorageError:
            raise
        except Exception as error:
            raise AppReleaseStorageError() from error

    @staticmethod
    def _read(stream) -> bytes:
        try:
            return stream.read()
        finally:
            close = getattr(stream, "close", None)
            if close:
                close()

    @staticmethod
    def _missing(error: Exception) -> bool:
        return getattr(error, "status", None) == 404

    def put_draft(self, key: str, archive: bytes) -> None:
        _key_path(key)
        self._connect()
        try:
            self._draft_bucket.put_object(key, archive, headers={"x-oss-server-side-encryption": "AES256"})
        except Exception as error:
            raise AppReleaseStorageError() from error

    def get_draft(self, key: str) -> bytes:
        _key_path(key)
        self._connect()
        try:
            return self._read(self._draft_bucket.get_object(key))
        except Exception as error:
            if self._missing(error):
                raise AppReleaseStorageError("APP_RELEASE_DRAFT_NOT_FOUND") from error
            raise AppReleaseStorageError() from error

    def delete_draft(self, key: str) -> None:
        _key_path(key)
        self._connect()
        try:
            self._draft_bucket.delete_object(key)
        except Exception as error:
            raise AppReleaseStorageError() from error

    def publish_tree(self, prefix: str, package: ValidatedH5Package) -> None:
        _key_path(prefix, prefix=True)
        status = self._check_release_bucket()
        for source in sorted(candidate for candidate in package.root.rglob("*") if candidate.is_file()):
            key = prefix + source.relative_to(package.root).as_posix()
            contents = source.read_bytes()
            headers = {"x-oss-server-side-encryption": "AES256"}
            if status != "Enabled":
                headers["x-oss-forbid-overwrite"] = "true"
            try:
                self._release_bucket.put_object(key, contents, headers=headers)
            except Exception as error:
                try:
                    existing = self._read(self._release_bucket.get_object(key))
                except Exception as lookup_error:
                    if self._missing(lookup_error):
                        raise AppReleaseStorageError() from error
                    raise AppReleaseStorageError() from lookup_error
                if existing != contents:
                    raise AppReleaseStorageError("APP_RELEASE_STORAGE_CONFLICT") from error

    def get_published(self, prefix: str, path: str) -> bytes | None:
        _key_path(prefix, prefix=True)
        key = prefix + _asset_path(path).as_posix()
        self._connect()
        try:
            return self._read(self._release_bucket.get_object(key))
        except Exception as error:
            if self._missing(error):
                return None
            raise AppReleaseStorageError() from error
