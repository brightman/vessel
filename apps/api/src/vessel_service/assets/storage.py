import hashlib
import os
import re
import tempfile
from pathlib import Path, PurePosixPath


class LocalAssetStorage:
    """Private local storage used only by development and test environments."""

    _key_pattern = re.compile(r"^[a-f0-9]{32}/[a-f0-9]{32}/[0-9a-f-]{36}$")

    def __init__(self, root: Path) -> None:
        self.root = root.expanduser().resolve()

    @staticmethod
    def make_key(owner_id: str, note_id: str, asset_id: str) -> str:
        owner_segment = hashlib.sha256(owner_id.encode("utf-8")).hexdigest()[:32]
        note_segment = hashlib.sha256(note_id.encode("utf-8")).hexdigest()[:32]
        return f"{owner_segment}/{note_segment}/{asset_id}"

    def _path(self, object_key: str) -> Path:
        if not self._key_pattern.fullmatch(object_key):
            raise ValueError("Invalid private asset object key")
        relative = PurePosixPath(object_key)
        path = (self.root / Path(*relative.parts)).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError("Asset path escapes storage root")
        return path

    def write(self, object_key: str, data: bytes) -> None:
        path = self._path(object_key)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.parent.is_symlink() or not path.parent.resolve().is_relative_to(self.root):
            raise ValueError("Asset path escapes storage root")
        temporary_path: str | None = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".upload-", delete=False) as temporary:
                temporary_path = temporary.name
                os.chmod(temporary_path, 0o600)
                temporary.write(data)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary_path, path)
        except Exception:
            if temporary_path:
                Path(temporary_path).unlink(missing_ok=True)
            raise

    def read(self, object_key: str) -> bytes:
        return self._path(object_key).read_bytes()

    def delete(self, object_key: str) -> None:
        path = self._path(object_key)
        path.unlink(missing_ok=True)
        parent = path.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
            owner_dir = parent.parent
            if owner_dir.exists() and not any(owner_dir.iterdir()):
                owner_dir.rmdir()
