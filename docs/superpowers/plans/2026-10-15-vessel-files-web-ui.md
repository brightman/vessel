# Vessel Files Web UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add complete Files management to the existing Vessel console using the already implemented `/v1` Files API.

**Architecture:** Keep the current React/Vite shell and same-origin Bearer client. Add a file-domain client and focused views for directory navigation, item details, uploads, sharing, moves, and trash. Browser file bytes go directly to OSS using short-lived signed instructions; metadata and permission checks stay on the Vessel API. No backend schema change is planned.

**Tech Stack:** React 19, TypeScript, Vite, Playwright, FastAPI, PostgreSQL, Aliyun OSS, Web Worker with incremental SHA-256.

## Global Constraints

- Follow [approved design](../specs/2026-10-15-vessel-files-web-ui-design.md) and [Files API contract](../../api-contract-files.md). Never treat Page directories/assets as Files folders.
- Preserve existing dirty worktree changes, including `0009_shared_files`, Files backend sources, documentation, and `var/`; stage only this feature's files and intentional shared-file hunks.
- Team files use effective member roles. Personal shared items use `GET /v1/file-items/{id}/permissions`; receiving a share never gives source-space root access.
- Every persistent Files mutation sends a fresh `Idempotency-Key`; a retry of that same intent reuses the key. `parts/sign` and `download` are freshly authorized signing calls, not persistent mutations.
- Never persist access tokens, file bytes, file names, signed URLs, OSS headers, or Page/Files content. Only the selected space ID is kept in `localStorage`; upload IDs may be kept in user-scoped `sessionStorage` and cleared on logout.
- `expected_metadata_version`, `expected_current_version_id`, and `expected_acl_revision` come from fresh API responses. A 409 triggers a deliberate reload/preview; no automatic overwrite.
- Files worker must run for asynchronous publish, expiry, and purge. Browser OSS PUT requires an approved test Origin CORS rule and `ETag` exposure; do not change a shared Bucket configuration implicitly.
- Follow the user-supplied development rules for the originating `baizhi-apps-worktree`: focused then affected core tests, together at most 100 cases, followed by a real E2E. A failed or unexecuted browser/OSS E2E blocks a completion claim. Vessel itself has no `AGENTS.md` at this plan's date.

## File map

| File | Responsibility |
| --- | --- |
| `apps/web/src/api.ts` | Export the existing authenticated `request<T>(path, init?, retry?)` function and add an optional `requestId` to `ApiError` from `X-Request-ID`; do not add OSS requests here. |
| `apps/web/src/App.tsx` | Add Files navigation, reset view on space/user change, and clear upload ID index after successful logout. |
| `apps/web/src/files/types.ts` | Types matching `Item`, `Permissions`, `Upload`, `FileVersion`, `Grant`, `TrashBatch`, previews, and purge jobs in the API contract. |
| `apps/web/src/files/api.ts` | Typed Files HTTP calls, UUID idempotency keys and exact request bodies; OSS instructions remain transient values. |
| `apps/web/src/files/Files.tsx` | Current-space, shared-with-me, and trash view state; selection, breadcrumbs, search and cursor lifecycle. |
| `apps/web/src/files/Directory.tsx` | Lazy folder tree, item table, keyboard selection, and item action entry points. |
| `apps/web/src/files/Details.tsx` | Item metadata, effective capabilities, versions, direct/inherited grants and audit view. |
| `apps/web/src/files/Actions.tsx` | Rename, destination picker, move preview/commit, trash and restore dialogs. |
| `apps/web/src/files/Trash.tsx` | Batch list, restore preview, explicit purge and purge job status. |
| `apps/web/src/files/hash.ts` | Pure incremental SHA-256 wrapper around `@noble/hashes` for bounded chunk updates and deterministic unit tests. |
| `apps/web/src/files/upload-worker.ts` | Chunked incremental SHA-256 over a browser `File`; no all-file ArrayBuffer. |
| `apps/web/src/files/upload.ts` | Browser OSS PUT transport, sign batching, receipts, complete, polling and cancel. |
| `apps/web/src/files/Transfers.tsx` | Multi-file queue, stage/progress/error display and user-scoped upload ID recovery. |
| `apps/web/src/files/files.css` | Desktop three-column layout, responsive drawer/sheet and accessible status styling. |
| `tests/file-values.test.mjs` | Pure hash and injected transport tests; browser `Worker` and DOM interactions remain in Playwright. |
| `package.json`, `package-lock.json` | Pin the incremental SHA-256 package used by the browser worker. |
| `tests/e2e/files-console.spec.mjs` | Real console interactions against isolated PostgreSQL and test OSS prefix. |
| `README.md` | Local Files console setup, worker and CORS prerequisites, supported limits. |

---

### Task 1: Files client and read-only navigation

**Files:** Modify `apps/web/src/api.ts`, `apps/web/src/App.tsx`; create `apps/web/src/files/types.ts`, `apps/web/src/files/api.ts`, `apps/web/src/files/Files.tsx`, `apps/web/src/files/Directory.tsx`, `apps/web/src/files/files.css`, `tests/e2e/files-console.spec.mjs`.

**Interfaces:** `fileRequest<T>(method: string, path: string, body?: unknown, key?: string): Promise<T>` calls exported `request<T>(path, init)` and JSON-encodes only defined bodies; `getRoot(spaceId)`, `listItems(spaceId, folderId, cursor?)`, `listShared(cursor?)`, `searchItems(spaceId, filter, cursor?)`, `getItem(itemId)`, and `getItemPermissions(itemId)` return contract-shaped wrapped payloads, such as `{folder: FileItem}` and `{permissions: FilePermissions}`. `Files` receives `{space, user, onError}` from `App` and does not require source-space membership to open `shared-files` results.

- [ ] **Step 1: Write a failing browser scenario.** Register a user, enter Files, create a folder through the API, then assert the current-space root table and breadcrumb show the folder. Use API setup, not an unrelated mocked table. In the same test, grant a folder named “Shared research” from a second user's personal space and assert it appears under “共享给我” without source root or sibling navigation.

```js
await page.getByRole("button", { name: "Files" }).click();
await expect(page.getByRole("heading", { name: "我的文件" })).toBeVisible();
await expect(page.getByRole("row", { name: /Research/ })).toBeVisible();
await page.getByRole("button", { name: "共享给我" }).click();
await expect(page.getByRole("row", { name: /Shared research/ })).toBeVisible();
await expect(page.getByText("Private sibling")).toHaveCount(0);
```

- [ ] **Step 2: Run only that browser test against an isolated database.** Start an isolated PostgreSQL and API at `127.0.0.1:52013` with registration enabled; never point this test at the user's `52003` database. Run `VESSEL_E2E_ORIGIN=http://127.0.0.1:52013 npx playwright test tests/e2e/files-console.spec.mjs --grep 'root and shared navigation' --reporter=line`; expected RED because Files navigation does not exist.
- [ ] **Step 3: Implement types/client and Files shell.** Export `request` from `api.ts`; add `Files` to `View` and navigation in `App.tsx`. Root uses `GET /v1/spaces/{id}/folders/root` followed by `GET /v1/spaces/{id}/file-items?parent_folder_id=...`; shared folder children use `GET /v1/folders/{id}/children`. `listShared` calls `/v1/shared-files`. Add server-side name search via `POST /v1/spaces/{id}/file-items/search` with `name_contains` and/or `kind`, and show no search box in the shared entry because that endpoint is space-scoped. Lazy-load folder children and show `next_cursor` as “加载更多” in root, folders, shared, and search. Use a cursor only with the same folder/filter/space. Reset selection, cursor, and previous rows when location changes. Breadcrumbs stop at the shared entry. Apply names as text, never `innerHTML`.

```ts
import { request } from "../api";
export async function fileRequest<T>(method: string, path: string, body?: unknown, key?: string): Promise<T> {
  const headers = new Headers();
  if (key) headers.set("Idempotency-Key", key);
  return request<T>(path, {method, headers, ...(body === undefined ? {} : {body: JSON.stringify(body)})});
}
export type FileItem = { item_id: string; space_id: string; kind: "file" | "folder"; folder_id?: string; parent_folder_id: string | null; name: string; metadata_version: number; status: string; created_by_user_id: string; updated_by_user_id: string; created_at: string; updated_at: string; current_version_id?: string | null; size_bytes?: number | null; sha256?: string | null; content_type?: string | null };
export type FilePermissions = { item_id: string; can_read: boolean; can_write: boolean; can_create_children: boolean; can_move: boolean; can_trash: boolean; can_restore: boolean; can_manage_sharing: boolean; can_purge: boolean; permission_sources: Array<{type: string; role: string; source_item_id: string; grant_id?: string}> };
export type FileVersion = { version_id: string; file_id: string; ordinal: number; size_bytes: number; sha256: string; crc64: string | null; content_type: string; created_at: string; created_by_user_id: string; source: "upload" | "restore"; restored_from_version_id: string | null };
export type Grant = { grant_id: string; item_id: string; grantee_user_id: string; role: "viewer" | "editor"; expires_at: string | null; created_by_user_id: string; created_at: string; inherited: boolean; source_item_id: string };
export type Download = { file_id: string; version_id: string; name: string; size_bytes: number; sha256: string; content_type: string; url: string; expires_at: string };
export type MovePreview = { preview_id: string; preview_hash: string; item_id: string; target_parent_folder_id: string; name: string; expected_metadata_version: number; expected_acl_revision: number; target_metadata_version: number; batch_version: number | null; permission_changes: {lost: Grant[]; gained: Grant[]}; expires_at: string };
export type RestorePreview = MovePreview;
export type TrashBatch = { batch_id: string; space_id: string; root_item_id: string; original_parent_folder_id: string; status: "trashed" | "restored" | "purging" | "purged"; batch_version: number; trashed_at: string; retention_until: string };
export type PurgeJob = { purge_id: string; space_id: string; batch_id: string; status: "pending" | "running" | "succeeded" | "failed"; failure_code: string | null; created_at: string; updated_at: string; status_url: string };
export const listShared = (cursor?: string) => request<{ items: FileItem[]; next_cursor: string | null }>(`/v1/shared-files${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`);
export const getItemPermissions = (itemId: string) => request<{ permissions: FilePermissions }>(`/v1/file-items/${encodeURIComponent(itemId)}/permissions`);
```

- [ ] **Step 4: Run green checks.** Re-run the one browser test, `npm run build:web`, and `git diff --check`; inspect desktop and 390 px layout, with the folder tree as a narrow-screen drawer. Keep this task's browser test count in the shared cap.
- [ ] **Step 5: Commit only Task 1 files.** `git add apps/web/src/api.ts apps/web/src/App.tsx apps/web/src/files/types.ts apps/web/src/files/api.ts apps/web/src/files/Files.tsx apps/web/src/files/Directory.tsx apps/web/src/files/files.css tests/e2e/files-console.spec.mjs && git commit -m "feat: add Files navigation and read-only browsing"`.

### Task 2: Item detail, metadata, sharing, versions and audit

**Files:** Create `apps/web/src/files/Details.tsx`; modify `apps/web/src/files/api.ts`, `Files.tsx`, `Directory.tsx`, `tests/e2e/files-console.spec.mjs`.

**Interfaces:** `getItemPermissions(itemId)` returns `{permissions: FilePermissions}`; `FilePermissions` includes `can_read`, `can_write`, `can_create_children`, `can_move`, `can_trash`, `can_restore`, `can_manage_sharing`, `can_purge`, and `permission_sources`. `Details` receives the selected `FileItem`, its fresh capabilities, source-space kind when known, and callbacks for reload. File version API uses `/v1/files/{id}/versions`, `/download`, and `/versions/{versionId}/restore`; grants use `/v1/file-items/{id}/grants`.

- [ ] **Step 1: Extend the browser scenario so it fails on capabilities.** In the isolated test environment, create a file fixture using the real upload intent/sign/complete API with server-side test HTTP to OSS and wait for the worker to publish; browser CORS is tested separately in Task 3. Sign in as a personal shared Viewer, select that file and assert Download/versions are visible while write/sharing actions are absent; sign in as the Owner and assert direct grant add/edit/revoke controls. Include a team Viewer to ensure role-based buttons do not appear, and assert a team Owner/Admin sees audit while an Editor does not.

```js
await page.getByRole("row", { name: /Shared report/ }).click();
await expect(page.getByRole("button", { name: "下载" })).toBeVisible();
await expect(page.getByRole("button", { name: "重命名" })).toHaveCount(0);
await expect(page.getByRole("button", { name: "共享设置" })).toHaveCount(0);
```

- [ ] **Step 2: Run only the new test; observe RED.** `VESSEL_E2E_ORIGIN=http://127.0.0.1:52013 npx playwright test tests/e2e/files-console.spec.mjs --grep 'item capabilities' --reporter=line`.
- [ ] **Step 3: Implement the detail drawer.** Fetch permissions when selection changes, show metadata and bounded version/grant pagination, use the freshly read `current_version_id` as `expected_current_version_id` for historical restore, and require confirmation. Download by POSTing `{}` or `{version_id}`, then immediately open the returned attachment URL without storing it. For personal Owner grant mutations, pass latest `acl_revision`, a new idempotency key, and only the target's user ID/role/optional expiry; treat the direct grant list as Owner-only. Mark inherited grants read-only with source item ID. Show audit only when the selected space role is Owner/Admin; fetch `/v1/spaces/{id}/file-audit` with cursor. On 409 retain form values and offer explicit reload; on 403/404 close the protected panel and clear signed actions.

```ts
export const restoreVersion = (fileId: string, versionId: string, expected: string, key: string) => fileRequest("POST", `/v1/files/${fileId}/versions/${versionId}/restore`, { expected_current_version_id: expected }, key);
export const downloadFile = (fileId: string, versionId?: string) => fileRequest<{download: Download}>("POST", `/v1/files/${fileId}/download`, versionId ? {version_id: versionId} : {});
```

- [ ] **Step 4: Run the focused browser test and build.** Confirm direct grant edit/revoke updates the ACL revision; inherited grants remain read-only, and history paging/download/restore work after a second version exists. Confirm keyboard focus returns from the drawer, mobile detail fills the screen, and role controls remain absent for Viewers. `npm run build:web` must exit 0.
- [ ] **Step 5: Commit Task 2 files.** Stage only the Files client/detail/view/test files and commit `feat: add Files detail versions and personal sharing`.

### Task 3: Direct OSS upload transport and transfer queue

**Files:** Create `apps/web/src/files/hash.ts`, `upload-worker.ts`, `upload.ts`, `Transfers.tsx`, `tests/file-values.test.mjs`; modify `apps/web/src/files/api.ts`, `Files.tsx`, `files.css`, `App.tsx`, `tests/e2e/files-console.spec.mjs`, `package.json`, `package-lock.json`.

**Interfaces:** `createSha256()` in `hash.ts` exposes `update(Uint8Array)` and `digestHex()` for chunk tests. `hashFile(file, onProgress, signal): Promise<string>` in `upload.ts` reads bounded slices in `upload-worker.ts`. `uploadFile(file, target, onProgress, signal): Promise<UploadResult>` creates the intent, signs at most 20 parts per call, PUTs exact signed slices, collects ETags, completes and polls terminal status. `target` is either `{ mode:"create", spaceId, parentFolderId, name }` or `{ mode:"new_version", spaceId, fileId, expectedCurrentVersionId, expectedMetadataVersion }`. `Transfers` owns the queue and persists only user-scoped upload IDs in `sessionStorage`.

`UploadResult` is the terminal `{upload: Upload}` response; `Upload` contains `upload_id`, `status`, `transfer_mode`, `part_size_bytes`, `part_count`, `version_id`, `file_id`, `failure_code`, and `status_url` as defined in the Files API contract. `onProgress` receives `{stage: "hashing" | "transfer" | "publishing", bytesDone: number, bytesTotal: number}`; only the transfer stage is rendered as an upload byte percentage.

- [ ] **Step 1: Write failing transport tests.** With an incremental hasher, injected API fetch and OSS fetch, assert SHA-256 for a multi-chunk fixture matches a fixed literal, sign batches never exceed 20 parts, signed PUTs contain no Vessel Authorization header, each part sends exactly the signed headers/body slice, and complete submits the captured ETag receipts. Separate tests cover cancellation, upload conflict, and 503 without retrying with a new idempotency key. Test the actual Worker file-reading path in Playwright because Node unit tests do not provide the browser Worker/Blob behavior.

```js
const hash = createSha256();
hash.update(new TextEncoder().encode("a"));
hash.update(new TextEncoder().encode("bc"));
assert.equal(hash.digestHex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
assert.equal(ossCall.headers.get("Authorization"), null);
assert.deepEqual(completeBody.parts, [{ part_number: 1, etag: '"etag-1"' }]);
```

- [ ] **Step 2: Run the new unit test file; observe RED.** `node --experimental-strip-types --test tests/file-values.test.mjs`.
- [ ] **Step 3: Implement bounded hashing and transport.** Add `@noble/hashes@2.4.0` and wrap `sha256.create()` from `@noble/hashes/sha2.js` in `hash.ts`; `crypto.subtle.digest` is not streaming. Send the browser `File` to a Worker, read it there in 4 MiB `File.slice` chunks, discard each buffer after `update`, terminate the Worker on abort, and report read bytes. Use server-supplied `part_size_bytes`, `part_count`, and instruction `size_bytes`. Call `/parts/sign` anew when signatures expire. Apply no Bearer or cookies to OSS URLs. After complete 202, poll `/file-uploads/{id}` until `ready/failed/expired/cancelled/conflict`; `verifying/publishing` display stage text rather than fabricated percentages. Limit concurrent files to 2 and concurrent parts per file to 3. On cancellation send `/cancel` with its own idempotency key, then re-read status to handle a simultaneous ready transition.

```ts
const response = await fetch(instruction.url, { method: "PUT", headers: instruction.headers, body: slice, credentials: "omit", signal });
const etag = response.headers.get("ETag");
if (!etag && transferMode === "multipart") throw new Error("OSS_ETAG_NOT_EXPOSED");
```

- [ ] **Step 4: Add a failing browser upload test and run it.** Use isolated PostgreSQL, a dedicated OSS test prefix and running Files worker. Assert a small file reaches `ready`, downloads with matching SHA-256, and a >16 MiB file completes through multipart with browser-visible ETag. This is the browser CORS gate: if preflight or ETag fails, record the exact Origin/method/header gap and fix authorized test Bucket configuration before proceeding; do not simulate success with a same-origin proxy.
- [ ] **Step 5: Run green checks.** Unit transport tests, targeted real browser upload, `npm run build:web`, and `git diff --check`. Implement drag/drop and picker as independent per-file intents, visible hashing/transfer/publish stages, a 2-file queue, cancel controls, and user-scoped `sessionStorage` containing upload IDs only. On reload, query stored IDs for status without trying to resume bytes; clear the index on logout and ignore another user's index. Verify these behaviors in the browser test.
- [ ] **Step 6: Commit Task 3 files.** Stage only upload/queue/client/test/package changes; commit `feat: add browser OSS uploads and transfer queue`.

### Task 4: Folder and item mutations with previews

**Files:** Create `apps/web/src/files/Actions.tsx`; modify `api.ts`, `Files.tsx`, `Directory.tsx`, `Details.tsx`, `files.css`, `tests/e2e/files-console.spec.mjs`.

**Interfaces:** `Actions` receives `{ item, permissions, spaceId, onSaved, onError }`. Folder creation takes `{ name, parent_folder_id }`; rename takes `{ name, expected_metadata_version }`; `prepareMove(itemId, targetId, expectedMetadataVersion, name?, key?)` returns `{move: MovePreview}` and `commitMove(itemId, preview, key)` sends its exact `preview_id`, `preview_hash`, `expected_metadata_version`, and `expected_acl_revision`. A destination picker lazily queries same-space folders and checks `can_create_children`.

- [ ] **Step 1: Write a failing browser test for create/rename/move.** Create two folders, rename one with its current version, choose the other as destination, assert the move preview lists permission gains/losses, confirm, then assert the item appears only in the target. In a second owner/share case, force an ACL revision change between prepare and commit and assert the UI asks for a new preview instead of committing stale data.

```js
await page.getByRole("button", { name: "移动" }).click();
await page.getByRole("button", { name: "预览移动" }).click();
await expect(page.getByRole("dialog", { name: "移动权限变化" })).toBeVisible();
await page.getByRole("button", { name: "确认移动" }).click();
```

- [ ] **Step 2: Run the focused browser test; observe RED.** `VESSEL_E2E_ORIGIN=http://127.0.0.1:52013 npx playwright test tests/e2e/files-console.spec.mjs --grep 'folder move preview' --reporter=line`.
- [ ] **Step 3: Implement create, rename and move.** Use fresh item and destination capabilities; reject selecting a file, self, descendant, or other-space folder in the picker, then let the API recheck. Leave folder/file action buttons disabled while one mutation is in flight. Generate one key per prepare/commit action and reuse it only for transport retry of that exact body. Display both `permission_changes.lost` and `.gained` as text without revealing an inaccessible ancestor name. On preview expiry, `FILE_OPERATION_PREVIEW_CONFLICT`, or metadata/ACL conflict, clear preview and require fresh prepare; keep entered destination/name until user cancels.

```ts
export const commitMove = (itemId: string, preview: MovePreview, key: string) => fileRequest<{item: FileItem}>("POST", `/v1/file-items/${itemId}/move/commit`, {preview_id: preview.preview_id, preview_hash: preview.preview_hash, expected_metadata_version: preview.expected_metadata_version, expected_acl_revision: preview.expected_acl_revision}, key);
```
- [ ] **Step 4: Run green checks and commit.** Run the focused browser test and build, then stage Task 4 files and commit `feat: add Files folder and move actions`.

### Task 5: Trash, restore, purge and audit completion

**Files:** Create `apps/web/src/files/Trash.tsx`; modify `api.ts`, `Files.tsx`, `Actions.tsx`, `files.css`, `tests/e2e/files-console.spec.mjs`, `README.md`.

**Interfaces:** Trash view consumes `GET /v1/spaces/{spaceId}/file-trash` and shows only API-returned batches; restore uses `/restore/prepare` then `/restore` with the preview ID/hash and ACL revision. `purgeBatch(batchId, expectedBatchVersion, key)` returns `{purge: PurgeJob}` whose `status_url` is polled until succeeded/failed. Audit view from Task 2 remains Owner/Admin-only.

- [ ] **Step 1: Write a failing browser test.** A team Editor trashes and restores a folder after reviewing the restore permission preview; a Viewer sees no trash actions; an Owner/Admin confirms permanent purge, sees pending/running instead of “deleted”, and later sees succeeded. Include a forced restore name conflict that offers a new location/name rather than reusing a stale preview.

```js
await page.getByRole("button", { name: "回收站" }).click();
await page.getByRole("button", { name: "预览恢复" }).click();
await expect(page.getByRole("dialog", { name: "恢复权限变化" })).toBeVisible();
```

- [ ] **Step 2: Run the focused browser test; observe RED.** `VESSEL_E2E_ORIGIN=http://127.0.0.1:52013 npx playwright test tests/e2e/files-console.spec.mjs --grep 'trash restore and purge' --reporter=line`.
- [ ] **Step 3: Implement the trash view.** Require explicit confirmations for trash and purge; show `retention_until` from API, never infer actual free quota from trash state. Restore only the selected batch. The restore preview shows original location, name, `permission_changes.lost`/`.gained`, and accepts a deliberate alternative target/name after conflict. Keep purge status visible until the job reaches `succeeded` or `failed`; on job failure show its safe `failure_code` and request ID. A 409 requires reloading the batch and a new preview. Surface 413 from upload as an actual server quota/size error and 503 as transfer temporarily unavailable while directory browsing remains available. Add concise README instructions for API, worker, test CORS and browser upload limitations.

```ts
export const commitRestore = (batchId: string, preview: RestorePreview, key: string) => fileRequest<{item: FileItem; trash_batch: TrashBatch}>("POST", `/v1/file-trash/${batchId}/restore`, {preview_id: preview.preview_id, preview_hash: preview.preview_hash, expected_acl_revision: preview.expected_acl_revision}, key);
export const purgeBatch = (batchId: string, batchVersion: number, key: string) => fileRequest<{purge: PurgeJob}>("POST", `/v1/file-trash/${batchId}/purge`, {expected_batch_version: batchVersion}, key);
```
- [ ] **Step 4: Run green checks and commit.** Run the focused browser test, build and `git diff --check`; stage Task 5 files only and commit `feat: add Files trash and recovery UI`.

### Task 6: Final integration and real E2E

**Files:** `tests/e2e/files-console.spec.mjs`, `tests/file-values.test.mjs`, affected `apps/web/src/files/*`, `README.md`.

**Interfaces:** No new interface; validate every capability and API boundary above. API, PostgreSQL, worker, and browser all run against an isolated test database and OSS prefix. Keep the user's existing local `127.0.0.1:52003` service and other worktree edits intact.

- [ ] **Step 1: Run the focused and affected core test set, capped at 100 cases.** Count first with `apps/api/.venv/bin/pytest --collect-only -q apps/api/tests/test_web_console.py apps/api/tests/test_auth.py apps/api/tests/test_spaces.py apps/api/tests/test_space_resources.py apps/api/tests/test_files_api.py apps/api/tests/test_files_metadata.py apps/api/tests/test_files_storage.py`; this selection currently has about 82 function tests before parametrization. If collected cases plus `tests/file-values.test.mjs` exceed 100, keep Files API/metadata, auth, spaces and web serving cases, then select only directly affected storage and space-resource cases. Run the counted selection and `node --experimental-strip-types --test tests/file-values.test.mjs`. Record exact commands, counts and results.
- [ ] **Step 2: Build and run the complete real browser E2E.** `npm run build:web`, then `VESSEL_E2E_ORIGIN=http://127.0.0.1:52013 npx playwright test tests/e2e/files-console.spec.mjs --reporter=line` while isolated PostgreSQL, API, Files worker and dedicated OSS test prefix are live. Required outcomes: personal create/upload/download/SHA-256, >16 MiB multipart with visible ETag, team Viewer 403 and Editor write, personal Viewer/Editor shared access and revocation, version restore, move/restore permission previews, trash/purge job and 409/503 messaging. Inspect rendered desktop and 390 px mobile screenshots.
- [ ] **Step 3: Verify local delivery and cleanup.** Check `/console`, built asset, `/healthz`, `/readyz` and Files navigation on the isolated API. If the user's `127.0.0.1:52003` service is a separately authorized local deployment target, update it deliberately and recheck health; do not silently modify its database or create a test account there. Stop only isolated test API, worker and PostgreSQL; clean only the dedicated OSS test prefix after confirming no referenced objects remain. Do not reset unrelated worktree changes.
- [ ] **Step 4: Review, stage and report.** Review a diff limited to Files UI and intentional shared-client/README changes; run `git diff --check`. Report all test commands/counts, browser E2E evidence, CORS/worker status and any unverified limits. Do not claim completion if the real browser OSS upload or purge path did not run successfully.

## Plan self-review

- The approved scope maps to Tasks 1–5: navigation/search/shared views; details/versions/sharing/audit; direct uploads/downloads; metadata/move; trash/restore/purge. Task 6 verifies the full browser path.
- No Files UI task depends on Page directory/assets, source-space membership for shared recipients, implicit root access, or a new backend data model.
- Browser CORS and worker readiness are implementation gates, not inferred from API unit tests.
