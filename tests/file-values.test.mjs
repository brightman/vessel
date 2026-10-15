import { test } from "node:test";
import assert from "node:assert/strict";
import { createSha256 } from "../apps/web/src/files/hash.ts";
import { putSignedParts } from "../apps/web/src/files/upload-transport.ts";

test("incremental SHA-256 hashes chunks as one byte stream", () => {
  const hash = createSha256();
  hash.update(new TextEncoder().encode("a"));
  hash.update(new TextEncoder().encode("bc"));
  assert.equal(hash.digestHex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("multipart signs at most 20 parts and sends signed bytes without Vessel authorization", async () => {
  const batches = [];
  const calls = [];
  const data = new Blob(["abcdefghijklmnopqrstu"]);
  const receipts = await putSignedParts(data, { transfer_mode: "multipart", part_count: 21, part_size_bytes: 1 }, async numbers => {
    batches.push(numbers);
    return numbers.map(number => ({ part_number: number, method: "PUT", url: `https://oss.example.test/${number}`, headers: { "x-oss-forbid-overwrite": "true" }, size_bytes: 1, expires_at: "2099-01-01T00:00:00Z" }));
  }, async (url, options) => {
    calls.push({ url, options, body: await options.body.text() });
    return new Response(null, { status: 200, headers: { ETag: '"etag-' + url.split("/").at(-1) + '"' } });
  }, () => {}, new AbortController().signal);
  assert.deepEqual(batches.map(batch => batch.length), [20, 1]);
  assert.equal(calls.length, 21);
  assert.equal(calls[0].body, "a");
  assert.deepEqual(calls[0].options.headers, { "x-oss-forbid-overwrite": "true" });
  assert.equal(calls[0].options.credentials, "omit");
  assert.deepEqual(receipts[0], { part_number: 1, etag: '"etag-1"' });
});
