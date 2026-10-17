"""Local file transfer through short-lived OSS capabilities."""

import hashlib
import mimetypes
import os
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

import httpx

from .config import CliError


TERMINAL = {"ready", "failed", "expired", "cancelled", "conflict"}


def _signed_client(client):
    return getattr(client, "signed_http", None) or httpx.Client(timeout=60, follow_redirects=False, trust_env=False)


def _url(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise CliError("SIGNED_URL_INVALID")
    return value


def _digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(4 * 1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
    except OSError as exc:
        raise CliError("INPUT_READ_FAILED") from exc
    return size, digest.hexdigest()


def upload_file(client, space_id: str, parent_folder_id: str, path: Path, name: str | None, *, sleep=time.sleep):
    size, digest = _digest(path)
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    upload = client.request("POST", f"/v1/spaces/{space_id}/file-uploads", body={
        "mode": "create", "parent_folder_id": parent_folder_id, "name": name or path.name,
        "size_bytes": size, "sha256": digest, "content_type": content_type,
    }, idempotent=True)["upload"]
    upload_id = upload["upload_id"]
    count, part_size = upload["part_count"], upload["part_size_bytes"]
    receipts = []
    signed = _signed_client(client)
    owns_signed = signed is not getattr(client, "signed_http", None)
    try:
        try:
            with path.open("rb") as source:
                for first in range(1, count + 1, 20):
                    numbers = list(range(first, min(count + 1, first + 20)))
                    instructions = client.request("POST", f"/v1/file-uploads/{upload_id}/parts/sign", body={"part_numbers": numbers})["instructions"]
                    by_number = {item["part_number"]: item for item in instructions}
                    for number in numbers:
                        instruction = by_number.get(number)
                        if not instruction or instruction.get("method") != "PUT":
                            raise CliError("UPLOAD_SIGNING_INVALID")
                        source.seek((number - 1) * part_size)
                        chunk = source.read(min(part_size, size - (number - 1) * part_size))
                        if "size_bytes" in instruction and len(chunk) != instruction["size_bytes"]:
                            raise CliError("UPLOAD_PART_SIZE_MISMATCH")
                        try:
                            response = signed.put(_url(instruction["url"]), content=chunk, headers=instruction.get("headers", {}))
                        except httpx.HTTPError as exc:
                            raise CliError("OSS_UPLOAD_FAILED") from exc
                        if response.status_code != 200:
                            raise CliError("OSS_UPLOAD_FAILED", status=response.status_code)
                        etag = response.headers.get("ETag")
                        if upload["transfer_mode"] == "multipart" and not etag:
                            raise CliError("OSS_ETAG_MISSING")
                        receipts.append({"part_number": number, "etag": etag or ""})
        except Exception:
            try:
                client.request("POST", f"/v1/file-uploads/{upload_id}/cancel", idempotent=True)
            except Exception:
                pass
            raise
        client.request("POST", f"/v1/file-uploads/{upload_id}/complete", body={
            "parts": receipts if upload["transfer_mode"] == "multipart" else []
        }, idempotent=True)
        for _ in range(120):
            state = client.request("GET", f"/v1/file-uploads/{upload_id}")["upload"]
            if state["status"] in TERMINAL:
                if state["status"] != "ready":
                    raise CliError(state.get("failure_code") or f"UPLOAD_{state['status'].upper()}")
                return {"upload": state}
            sleep(1)
        raise CliError("UPLOAD_STATUS_TIMEOUT")
    except OSError as exc:
        raise CliError("FILE_IO_ERROR") from exc
    finally:
        if owns_signed:
            signed.close()


def download_file(client, file_id: str, destination: Path, version_id: str | None):
    details = client.request("POST", f"/v1/files/{file_id}/download", body={"version_id": version_id})["download"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    signed = _signed_client(client)
    owns_signed = signed is not getattr(client, "signed_http", None)
    temp = None
    try:
        with tempfile.NamedTemporaryFile("wb", prefix=".vessel-download-", dir=destination.parent, delete=False) as output:
            temp = Path(output.name)
            digest = hashlib.sha256()
            size = 0
            try:
                with signed.stream("GET", _url(details["url"])) as response:
                    if response.status_code != 200:
                        raise CliError("OSS_DOWNLOAD_FAILED", status=response.status_code)
                    for chunk in response.iter_bytes(chunk_size=4 * 1024 * 1024):
                        output.write(chunk)
                        digest.update(chunk)
                        size += len(chunk)
            except httpx.HTTPError as exc:
                raise CliError("OSS_DOWNLOAD_FAILED") from exc
        if size != details["size_bytes"] or digest.hexdigest() != details["sha256"]:
            raise CliError("DOWNLOAD_CHECKSUM_MISMATCH")
        os.replace(temp, destination)
        temp = None
        return {"file_id": details["file_id"], "version_id": details.get("version_id"),
                "path": str(destination), "size_bytes": size, "sha256": digest.hexdigest()}
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)
        if owns_signed:
            signed.close()
