"""Real HTTP + Aliyun OSS file E2E. Use only an isolated database/test prefix.

The API must allow controlled test registration and have configured OSS storage.
No credentials or signed URLs are printed. This creates and purges only its own files.
"""

import hashlib
import json
import sys
import time
from uuid import uuid4

import httpx


def main(base):
    client = httpx.Client(base_url=base, timeout=120)
    external = httpx.Client(timeout=120)
    run = str(uuid4())[:8]
    checks = []

    def api(method, path, headers=None, body=None, expected=200, key=None):
        auth = dict(headers or {})
        if method in ("POST", "PATCH", "DELETE"):
            auth["Idempotency-Key"] = key or str(uuid4())
        response = client.request(method, path, headers=auth, json=body)
        if response.status_code != expected:
            code = (
                response.json().get("detail", {})
                if response.headers.get("content-type", "").startswith(
                    "application/json"
                )
                else {}
            )
            raise RuntimeError(
                f"API {method} {path} status={response.status_code} error={code}"
            )
        return response.json() if response.status_code != 204 else None

    def register(name):
        result = api(
            "POST",
            "/v1/auth/register",
            body={
                "name": name,
                "email": f"{name}-{run}@example.test",
                "password": "vessel-e2e-password",
            },
            expected=201,
        )
        headers = {"Authorization": "Bearer " + result["access_token"]}
        space = api("GET", "/v1/spaces", headers)["spaces"][0]["space_id"]
        return headers, space, result["user"]["user_id"]

    def poll(path, headers, terminal):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = api("GET", path, headers)
            record = next(iter(result.values()))
            if record["status"] in terminal:
                return record
            time.sleep(0.25)
        raise RuntimeError("file job timed out")

    a, space, aid = register("owner")
    b, _, bid = register("editor")
    c, _, cid = register("viewer")
    d, _, _ = register("outsider")
    root = api("GET", f"/v1/spaces/{space}/folders/root", a)["folder"]
    folder = api(
        "POST",
        f"/v1/spaces/{space}/folders",
        a,
        {"name": "OSS-" + run, "parent_folder_id": root["item_id"]},
        201,
    )["folder"]
    fid = folder["item_id"]
    # Two conflicting moves must serialize on the PostgreSQL space row.
    from concurrent.futures import ThreadPoolExecutor

    left = api(
        "POST",
        f"/v1/spaces/{space}/folders",
        a,
        {"name": "left", "parent_folder_id": fid},
        201,
    )["folder"]
    right = api(
        "POST",
        f"/v1/spaces/{space}/folders",
        a,
        {"name": "right", "parent_folder_id": fid},
        201,
    )["folder"]
    preparations = []
    for source, target in [(left, right), (right, left)]:
        preview = api(
            "POST",
            f"/v1/file-items/{source['item_id']}/move/prepare",
            a,
            {
                "target_parent_folder_id": target["item_id"],
                "expected_metadata_version": source["metadata_version"],
            },
        )["move"]
        preparations.append(
            (
                source["item_id"],
                {
                    k: preview[k]
                    for k in (
                        "preview_id",
                        "preview_hash",
                        "expected_metadata_version",
                        "expected_acl_revision",
                    )
                },
            )
        )

    def move(prepared):
        source, body = prepared
        return client.post(
            f"/v1/file-items/{source}/move/commit",
            headers={**a, "Idempotency-Key": str(uuid4())},
            json=body,
        ).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(move, preparations)) == [200, 409]
    checks.append("PostgreSQL concurrent crossing moves serialize without cycles")

    def grant(uid, role):
        rev = api("GET", f"/v1/file-items/{fid}/grants", a)["acl_revision"]
        return api(
            "POST",
            f"/v1/file-items/{fid}/grants",
            a,
            {"grantee_user_id": uid, "role": role, "expected_acl_revision": rev},
            201,
        )

    bg = grant(bid, "editor")
    grant(cid, "viewer")
    assert api("GET", f"/v1/spaces/{space}/folders/root", b, expected=404)
    api("GET", f"/v1/file-items/{fid}", d, expected=404)
    checks.append("folder ACL and private root isolation")
    files = []
    single_instruction = None
    for name, data in [
        ("hello.txt", b"Vessel shared OSS file\n"),
        ("multipart.bin", b"0123456789abcdef" * (17 * 1024 * 1024 // 16)),
    ]:
        body = {
            "mode": "create",
            "parent_folder_id": fid,
            "name": name,
            "size_bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "content_type": "application/octet-stream",
        }
        upload = api("POST", f"/v1/spaces/{space}/file-uploads", b, body, 201)["upload"]
        instructions = api(
            "POST",
            f"/v1/file-uploads/{upload['upload_id']}/parts/sign",
            b,
            {"part_numbers": list(range(1, upload["part_count"] + 1))},
        )["instructions"]
        parts = []
        for instruction in instructions:
            offset = (instruction["part_number"] - 1) * upload["part_size_bytes"]
            chunk = data[offset : offset + instruction["size_bytes"]]
            put = external.put(
                instruction["url"], headers=instruction["headers"], content=chunk
            )
            if put.status_code != 200:
                raise RuntimeError(f"OSS PUT failed status={put.status_code}")
            parts.append(
                {"part_number": instruction["part_number"], "etag": put.headers["etag"]}
            )
        receipts = (
            {"parts": parts[::-1]} if upload["transfer_mode"] == "multipart" else {}
        )
        api(
            "POST", f"/v1/file-uploads/{upload['upload_id']}/complete", b, receipts, 202
        )
        ready = poll(
            upload["status_url"], b, {"ready", "failed", "conflict", "expired"}
        )
        if ready["status"] != "ready":
            raise RuntimeError("publish " + str(ready["failure_code"]))
        file_id = ready["file_id"]
        files.append(file_id)
        download = api("POST", f"/v1/files/{file_id}/download", c, {})["download"]
        got = external.get(download["url"])
        if (
            got.status_code != 200
            or hashlib.sha256(got.content).hexdigest() != body["sha256"]
        ):
            raise RuntimeError("Downloaded content differs")
        api(
            "PATCH",
            f"/v1/file-items/{file_id}",
            c,
            {"name": "denied", "expected_metadata_version": 1},
            403,
        )
        checks.append(name + " upload/download SHA256 " + str(len(data)) + " bytes")
        if upload["transfer_mode"] == "single":
            single_instruction = instructions[0]
    # Replay the still-valid upload capability after initial cleanup. Published bytes stay sealed.
    if single_instruction:
        replay = external.put(
            single_instruction["url"],
            headers=single_instruction["headers"],
            content=b"Vessel shared OSS file\n",
        )
        if replay.status_code not in (200, 409):
            raise RuntimeError(f"OSS replay unexpected status={replay.status_code}")
        download = api("POST", f"/v1/files/{files[0]}/download", c, {})["download"]
        assert (
            hashlib.sha256(external.get(download["url"]).content).hexdigest()
            == hashlib.sha256(b"Vessel shared OSS file\n").hexdigest()
        )
        checks.append("signed PUT replay cannot change published bytes")
    # Version update and restore preserve history and immutable source objects.
    file_id = files[0]
    current = api("GET", f"/v1/file-items/{file_id}", a)["item"]
    original_version = current["current_version_id"]
    changed = b"Vessel revised content\n"
    intent = api(
        "POST",
        f"/v1/spaces/{space}/file-uploads",
        b,
        {
            "mode": "new_version",
            "file_id": file_id,
            "expected_current_version_id": original_version,
            "expected_metadata_version": current["metadata_version"],
            "size_bytes": len(changed),
            "sha256": hashlib.sha256(changed).hexdigest(),
            "content_type": "text/plain",
        },
        201,
    )["upload"]
    instruction = api(
        "POST",
        f"/v1/file-uploads/{intent['upload_id']}/parts/sign",
        b,
        {"part_numbers": [1]},
    )["instructions"][0]
    put = external.put(
        instruction["url"], headers=instruction["headers"], content=changed
    )
    if put.status_code != 200:
        raise RuntimeError("version upload failed")
    api("POST", f"/v1/file-uploads/{intent['upload_id']}/complete", b, {}, 202)
    ready = poll(intent["status_url"], b, {"ready", "failed", "conflict"})
    assert ready["status"] == "ready"
    restored = api(
        "POST",
        f"/v1/files/{file_id}/versions/{original_version}/restore",
        b,
        {"expected_current_version_id": ready["version_id"]},
    )
    assert restored["version"]["version_id"] not in (
        original_version,
        ready["version_id"],
    )
    versions = api("GET", f"/v1/files/{file_id}/versions", c)["versions"]
    assert len(versions) == 3
    checks.append("file new version and restore preserve all three logical revisions")
    # Removing editor grant invalidates old user access token for this hierarchy.
    rev = api("GET", f"/v1/file-items/{fid}/grants", a)["acl_revision"]
    api(
        "DELETE",
        f"/v1/file-items/{fid}/grants/{bg['grant']['grant_id']}",
        a,
        {"expected_acl_revision": rev},
        204,
    )
    api("GET", f"/v1/file-items/{files[0]}", b, expected=404)
    checks.append("revoked editor old token denied")
    current = api("GET", f"/v1/file-items/{fid}", a)["item"]
    batch = api(
        "POST",
        f"/v1/file-items/{fid}/trash",
        a,
        {"expected_metadata_version": current["metadata_version"]},
    )["trash_batch"]
    api("POST", f"/v1/files/{files[0]}/download", c, {}, 404)
    preview = api("POST", f"/v1/file-trash/{batch['batch_id']}/restore/prepare", a, {})[
        "restore"
    ]
    body = {
        k: preview[k] for k in ("preview_id", "preview_hash", "expected_acl_revision")
    }
    restore_key = "restore-" + run
    restored = api(
        "POST", f"/v1/file-trash/{batch['batch_id']}/restore", a, body, key=restore_key
    )
    replay = api(
        "POST", f"/v1/file-trash/{batch['batch_id']}/restore", a, body, key=restore_key
    )
    assert restored == replay
    api("POST", f"/v1/files/{files[0]}/download", c, {})
    checks.append("trash/restore with sharing and stable idempotency replay")
    current = restored["item"]
    batch = api(
        "POST",
        f"/v1/file-items/{fid}/trash",
        a,
        {"expected_metadata_version": current["metadata_version"]},
    )["trash_batch"]
    purge_key = "purge-" + run
    body = {"expected_batch_version": batch["batch_version"]}
    job = api(
        "POST", f"/v1/file-trash/{batch['batch_id']}/purge", a, body, 202, key=purge_key
    )["purge"]
    result = poll(job["status_url"], a, {"succeeded", "failed"})
    if result["status"] != "succeeded":
        raise RuntimeError("purge " + str(result["failure_code"]))
    again = api(
        "POST", f"/v1/file-trash/{batch['batch_id']}/purge", a, body, 202, key=purge_key
    )
    assert again["purge"]["purge_id"] == job["purge_id"]
    checks.append("permanent recursive purge and stable idempotency replay")
    print(
        json.dumps(
            {"run": run, "checks": checks, "status": "passed"}, ensure_ascii=False
        )
    )


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Exception as exc:
        # Deliberately exclude transport exception messages containing signed URLs.
        if isinstance(exc, RuntimeError):
            print(str(exc), file=sys.stderr)
        else:
            print("E2E failure: " + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
