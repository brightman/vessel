"""Validation for static App H5 release archives.

The validator only expands a ZIP into a temporary directory after enforcing
bounded paths and static asset rules. Call ``cleanup_h5_package`` after the
validated tree has been copied into private release storage.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile, ZipInfo

MAX_ZIP_BYTES = 50 * 1024 * 1024
MAX_EXTRACTED_BYTES = 200 * 1024 * 1024
MAX_FILES = 2_000
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_DEPTH = 10
ALLOWED_EXTENSIONS = {
    ".html", ".css", ".js", ".json", ".svg", ".png", ".jpg", ".jpeg",
    ".gif", ".webp", ".ico", ".woff", ".woff2", ".ttf",
}
FORBIDDEN_NAMES = {".env", ".env.local", ".env.production", "id_rsa", "credentials.json"}
FORBIDDEN_EXTENSIONS = {".py", ".sh", ".sql", ".exe", ".dll", ".so", ".dylib", ".pem", ".key", ".db", ".sqlite"}
SECRET_MARKERS = (
    b"SUPABASE_SERVICE_ROLE_KEY", b"SUPABASE_SECRET_KEY", b"OSS_ACCESS_KEY_SECRET",
    b"AWS_SECRET_ACCESS_KEY", b"OPENAI_API_KEY", b"-----BEGIN PRIVATE KEY-----",
)
_ALLOWED_OPERATIONS = {"create", "read", "update", "delete"}


@dataclass(frozen=True)
class ValidatedH5Package:
    root: Path
    entry_file: str
    file_count: int
    total_size_bytes: int
    checksum_sha256: str


class H5PackageValidator:
    def __init__(self, *, max_zip_bytes: int = MAX_ZIP_BYTES):
        self.max_zip_bytes = max_zip_bytes

    def validate(self, zip_path: Path, app_id: str, manifest: dict) -> ValidatedH5Package:
        zip_path = Path(zip_path)
        if not zip_path.is_file() or zip_path.stat().st_size > self.max_zip_bytes:
            raise ValueError("H5_PACKAGE_TOO_LARGE")
        root = Path(tempfile.mkdtemp(prefix="vessel-h5-"))
        try:
            file_count, total_size = self._extract(zip_path, root)
            entry_file = self._find_entry(root)
            self._check_entry_references(root, entry_file)
            self._check_app_contract(root, app_id, manifest)
            return ValidatedH5Package(
                root=root,
                entry_file=entry_file,
                file_count=file_count,
                total_size_bytes=total_size,
                checksum_sha256=self._checksum(root),
            )
        except Exception:
            shutil.rmtree(root, ignore_errors=True)
            raise

    def _extract(self, zip_path: Path, root: Path) -> tuple[int, int]:
        try:
            archive = ZipFile(zip_path)
        except BadZipFile as error:
            raise ValueError("H5_PACKAGE_INVALID") from error
        with archive:
            try:
                file_count, total_size, seen_paths = 0, 0, set()
                for info in archive.infolist():
                    relative = self._safe_path(info)
                    if info.is_dir():
                        continue
                    if relative in seen_paths:
                        raise ValueError("H5_DUPLICATE_PATH")
                    seen_paths.add(relative)
                    file_count += 1
                    if file_count > MAX_FILES:
                        raise ValueError("H5_FILE_COUNT_EXCEEDED")
                    if info.file_size > MAX_FILE_BYTES:
                        raise ValueError("H5_FILE_TOO_LARGE")
                    target = (root / relative).resolve()
                    if not target.is_relative_to(root.resolve()):
                        raise ValueError("H5_PATH_TRAVERSAL")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    member_size = 0
                    with archive.open(info) as source, target.open("wb") as destination:
                        while chunk := source.read(1024 * 1024):
                            member_size += len(chunk)
                            if member_size > MAX_FILE_BYTES:
                                raise ValueError("H5_FILE_TOO_LARGE")
                            if total_size + member_size > MAX_EXTRACTED_BYTES:
                                raise ValueError("H5_EXTRACTED_SIZE_EXCEEDED")
                            destination.write(chunk)
                    total_size += member_size
                return file_count, total_size
            except BadZipFile as error:
                raise ValueError("H5_PACKAGE_INVALID") from error

    @staticmethod
    def _safe_path(info: ZipInfo) -> str:
        name = info.filename.replace("\\", "/")
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or ".." in path.parts or len(path.parts) > MAX_DEPTH
                or any("\x00" in part for part in path.parts)):
            raise ValueError("H5_PATH_TRAVERSAL")
        if stat.S_ISLNK((info.external_attr >> 16) & 0xFFFF):
            raise ValueError("H5_SYMLINK_NOT_ALLOWED")
        if not info.is_dir():
            filename = Path(path.name)
            extension = filename.suffix.lower()
            if (filename.name.lower() in FORBIDDEN_NAMES or extension in FORBIDDEN_EXTENSIONS
                    or (extension and extension not in ALLOWED_EXTENSIONS)):
                raise ValueError("H5_FILE_TYPE_NOT_ALLOWED")
        return path.as_posix()

    @staticmethod
    def _find_entry(root: Path) -> str:
        if (root / "index.html").is_file():
            return "index.html"
        if (root / "dist" / "index.html").is_file():
            return "dist/index.html"
        raise ValueError("H5_ENTRY_NOT_FOUND")

    @staticmethod
    def _check_entry_references(root: Path, entry_file: str) -> None:
        try:
            contents = (root / entry_file).read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("H5_ENTRY_INVALID") from error
        if "file://" in contents:
            raise ValueError("H5_LOCAL_FILE_REFERENCE")

    @staticmethod
    def _check_app_contract(root: Path, app_id: str, manifest: dict) -> None:
        contract_path = root / "vessel-app.json"
        if not contract_path.exists():
            return
        try:
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("H5_APP_MANIFEST_INVALID") from error
        if not isinstance(contract, dict) or contract.get("app_id") != app_id:
            raise ValueError("H5_APP_ID_MISMATCH")
        tables = manifest.get("tables") if isinstance(manifest, dict) else None
        if not isinstance(tables, dict):
            raise ValueError("H5_APP_MANIFEST_INVALID")
        required_tables = contract.get("required_tables", [])
        if not isinstance(required_tables, list) or any(not isinstance(name, str) or name not in tables for name in required_tables):
            raise ValueError("H5_MANIFEST_TABLE_MISSING")
        required_operations = contract.get("required_operations", {})
        if not isinstance(required_operations, dict):
            raise ValueError("H5_APP_MANIFEST_INVALID")
        for table_name, operations in required_operations.items():
            if (not isinstance(table_name, str) or table_name not in tables
                    or not isinstance(operations, list)
                    or any(operation not in _ALLOWED_OPERATIONS for operation in operations)):
                raise ValueError("H5_MANIFEST_OPERATION_MISSING")

    @staticmethod
    def _checksum(root: Path) -> str:
        digest = hashlib.sha256()
        for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
            relative = path.relative_to(root).as_posix().encode()
            contents = path.read_bytes()
            if any(marker in contents for marker in SECRET_MARKERS):
                raise ValueError("H5_SECRET_DETECTED")
            digest.update(relative + b"\0" + hashlib.sha256(contents).digest())
        return digest.hexdigest()


def cleanup_h5_package(package: ValidatedH5Package | None) -> None:
    if package is not None:
        shutil.rmtree(package.root, ignore_errors=True)
