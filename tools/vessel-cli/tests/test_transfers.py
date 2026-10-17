import hashlib

import httpx
import pytest

from vessel_cli.config import CliError
from vessel_cli.transfers import upload_file, download_file


class FakeClient:
    environment = "local"
    def __init__(self, data):
        self.data = data
        self.calls = []
        self.signed_http = httpx.Client(transport=httpx.MockTransport(self._signed))
    def _signed(self, request):
        self.calls.append(("SIGNED", request.url.host, request.headers.get("authorization"), request.content))
        if request.method == "PUT":
            return httpx.Response(200, headers={"ETag": '"part-etag"'})
        return httpx.Response(200, content=self.data)
    def request(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if path.endswith("/file-uploads"):
            return {"upload": {"upload_id": "up-1", "transfer_mode": "single", "part_count": 1, "part_size_bytes": 8000000}}
        if path.endswith("/parts/sign"):
            return {"instructions": [{"part_number": 1, "url": "https://oss.example/upload?secret=signed", "method": "PUT", "headers": {"x-oss-test": "yes"}}]}
        if path.endswith("/complete"):
            return {"upload": {"upload_id": "up-1", "status": "verifying"}}
        if path == "/v1/file-uploads/up-1":
            return {"upload": {"upload_id": "up-1", "status": "ready", "file_id": "file-1"}}
        if path.endswith("/download"):
            return {"download": {"url": "https://oss.example/download?secret=signed", "size_bytes": len(self.data), "sha256": hashlib.sha256(self.data).hexdigest(), "file_id": "file-1"}}
        raise AssertionError(path)


def test_signed_upload_and_download_never_return_url(tmp_path):
    source = tmp_path / "source.bin"
    source.write_bytes(b"hello vessel")
    client = FakeClient(source.read_bytes())
    uploaded = upload_file(client, "space-1", "folder-1", source, None, sleep=lambda _: None)
    assert uploaded == {"upload": {"upload_id": "up-1", "status": "ready", "file_id": "file-1"}}
    assert "signed" not in str(uploaded)
    assert client.calls[2][2] is None  # OSS request has no Vessel Authorization header.
    dest = tmp_path / "out.bin"
    result = download_file(client, "file-1", dest, None)
    assert result["path"] == str(dest)
    assert dest.read_bytes() == source.read_bytes()
    assert "secret=signed" not in str(result)


def test_download_checksum_failure_leaves_existing_file(tmp_path):
    client = FakeClient(b"wrong")
    original_request = client.request
    def bad_request(method, path, **kwargs):
        value = original_request(method, path, **kwargs)
        if path.endswith("/download"):
            value["download"]["sha256"] = "0" * 64
        return value
    client.request = bad_request
    dest = tmp_path / "keep.bin"
    dest.write_bytes(b"old")
    with pytest.raises(CliError, match="DOWNLOAD_CHECKSUM_MISMATCH"):
        download_file(client, "file-1", dest, None)
    assert dest.read_bytes() == b"old"
