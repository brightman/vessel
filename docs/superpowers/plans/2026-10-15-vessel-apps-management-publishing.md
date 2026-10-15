# Vessel Apps Management and Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add manager-controlled App settings, a complete typed data grid, and immutable static H5 releases to Vessel while retaining its space-based authorization.

**Architecture:** Extend the existing `VesselApp` JSON-Manifest model with separate optimistic-lock settings metadata, release history and audit rows. A dedicated App-release storage adapter validates and stores ZIP assets under immutable keys, while FastAPI serves published and preview static content. The React console consumes the new API without importing Baizhi Platform identity, SQL policy, Field Agent or runtime code.

**Tech Stack:** FastAPI, SQLAlchemy 2, Alembic, PostgreSQL and SQLite test support, Aliyun OSS (`oss2`), React 19, TypeScript, Vite, Playwright, pytest.

## Global Constraints

- Every App belongs to a Vessel space; access checks resolve current Owner/Admin/Editor/Viewer membership for every request.
- Owner and Admin manage App settings, Manifest, archives and releases. Editor writes records. Viewer is read-only.
- Manifest changes remain additive: add tables and nullable fields only.
- App releases contain static files only; package upload never executes scripts, build tools or server code.
- Final release object keys are immutable `vessel-apps/{app_id}/releases/{version}/`; Draft archive keys are private `vessel-apps/{app_id}/drafts/{release_id}.zip`.
- Reuse OSS credentials through read-only environment/config loading; do not persist credentials, signed URLs, preview tickets or archive bytes in database rows or audit events.
- All API additions retain `{"detail":{"code":"..."}}` business-error payloads.
- Preserve existing modified files and the untracked `var/` directory. Commit only files belonging to each completed task.
- Follow red-green-refactor: write a behavioral test, observe its expected failure, implement only enough to pass, then rerun it.
- Run at most 100 targeted tests plus core-path tests in the final verification.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `apps/api/migrations/versions/0010_app_management_publishing.py` | Settings, release and audit schema migration. |
| `apps/api/src/vessel_service/models/app.py` | App settings, release and audit ORM models. |
| `apps/api/src/vessel_service/apps/router.py` | Settings, data-grid, releases, H5-token and authorization routes. |
| `apps/api/src/vessel_service/apps/releases.py` | Release state transition service and audit writes. |
| `apps/api/src/vessel_service/apps/h5_release.py` | ZIP validation, checksum and MIME-safe path rules. |
| `apps/api/src/vessel_service/apps/release_storage.py` | Local test/development and OSS immutable object storage adapters. |
| `apps/api/src/vessel_service/auth/router.py` | Refresh-cookie principal helper for H5 session creation. |
| `apps/api/src/vessel_service/auth/tokens.py` | Audience-aware H5 scoped token verification helper. |
| `apps/api/src/vessel_service/settings.py` | App-release prefix, temporary-root, preview-ticket and storage configuration. |
| `apps/api/src/vessel_service/main.py` | Storage wiring and public static H5 gateway. |
| `apps/api/tests/test_app_management.py` | Settings, role and data-grid API contracts. |
| `apps/api/tests/test_h5_release.py` | ZIP validator and release lifecycle API contracts. |
| `apps/api/tests/test_h5_gateway.py` | Public assets, preview tickets and H5 scoped session isolation. |
| `apps/web/src/api.ts` | Typed API client and H5 release interfaces. |
| `apps/web/src/Apps.tsx` | Settings, data grid and publishing console. |
| `apps/web/src/console.css` | Console styles for the App workspace. |
| `tests/e2e/apps-management.spec.mjs` | Isolated PostgreSQL browser E2E for manager/data/release path. |
| `docs/api-contract-pages-apps.md` | Reviewable HTTP contract. |
| `docs/db-schema.md` | Database schema reference. |

## Task 1: Persist App settings, release records and audit events

**Files:**
- Modify: `apps/api/src/vessel_service/models/app.py`
- Modify: `apps/api/src/vessel_service/models/__init__.py`
- Create: `apps/api/migrations/versions/0010_app_management_publishing.py`
- Create: `apps/api/tests/test_app_management.py`
- Modify: `docs/db-schema.md`

**Interfaces:**
- Consumes: existing `VesselApp` and `users`/`spaces` foreign keys.
- Produces: `VesselAppRelease`, `VesselAppAuditEvent`, `VesselApp.settings_version`, and release/audit database tables for router and storage tasks.

- [ ] **Step 1: Write the failing model and migration contract test**

```python
def test_app_management_schema_has_independent_settings_and_release_versions():
    from vessel_service.models import VesselApp, VesselAppAuditEvent, VesselAppRelease

    assert "settings_version" in VesselApp.__table__.c
    assert "description" in VesselApp.__table__.c
    assert "archived_at" in VesselApp.__table__.c
    assert {"release_id", "app_id", "version", "status", "object_prefix", "is_current"} <= set(VesselAppRelease.__table__.c)
    assert {"event_id", "app_id", "action", "details_json"} <= set(VesselAppAuditEvent.__table__.c)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py::test_app_management_schema_has_independent_settings_and_release_versions -q`

Expected: FAIL because the new ORM classes and `settings_version` column do not exist.

- [ ] **Step 3: Add the models and Alembic revision**

Add these App columns with safe defaults for the empty Vessel database:

```python
description: Mapped[str] = mapped_column(String(2000), default="", server_default="")
settings_version: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
archived_by: Mapped[str | None] = mapped_column(ForeignKey("users.user_id", ondelete="RESTRICT"))
```

Create `VesselAppRelease` with `unique(app_id, version)`, one partial unique current-release index, and `CheckConstraint("NOT is_current OR status = 'published'", name="ck_vessel_app_releases_current_published")`. Create `VesselAppAuditEvent` with JSON/JSONB details and indexes on `(app_id, created_at, event_id)` and `(release_id, created_at)`. In migration `0010`, use PostgreSQL-compatible columns and a SQLite-compatible JSON variant, then update `docs/db-schema.md` with the exact new columns and constraints.

- [ ] **Step 4: Run the model test and migration upgrade**

Run:

```bash
cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py::test_app_management_schema_has_independent_settings_and_release_versions -q
PAGES_DATABASE_URL=sqlite+pysqlite:////tmp/vessel-app-management-migration.sqlite3 .venv/bin/alembic upgrade head
```

Expected: test PASS; Alembic creates revision `0010_app_management_publishing` after `0009_shared_files`.

- [ ] **Step 5: Commit the database foundation**

```bash
git add apps/api/src/vessel_service/models/app.py apps/api/src/vessel_service/models/__init__.py apps/api/migrations/versions/0010_app_management_publishing.py apps/api/tests/test_app_management.py docs/db-schema.md
git commit -m "feat: add Vessel App management schema"
```

## Task 2: Add manager-only App settings and archive lifecycle

**Files:**
- Modify: `apps/api/src/vessel_service/apps/router.py`
- Modify: `apps/api/tests/test_app_management.py`
- Modify: `docs/api-contract-pages-apps.md`

**Interfaces:**
- Consumes: Task 1 settings columns and existing `space_access` role return value.
- Produces: `PATCH /v1/apps/{app_id}`, archive/restore routes, manager-only Manifest updates, and active/archived list behavior.

- [ ] **Step 1: Write failing settings authorization tests**

```python
def test_only_owner_or_admin_can_change_app_settings_or_manifest(api_factory):
    api, app_id, owner_headers, editor_headers, viewer_headers = managed_team_app(api_factory)
    denied = api("PATCH", f"/v1/apps/{app_id}", headers=editor_headers, json={
        "expected_settings_version": 1, "name": "Edited by editor",
    })
    assert denied.status_code == 403
    assert denied.json()["detail"]["code"] == "APP_MANAGER_REQUIRED"

    changed = api("PATCH", f"/v1/apps/{app_id}", headers=owner_headers, json={
        "expected_settings_version": 1, "name": "Roadmap", "description": "Quarterly priorities",
    })
    assert changed.status_code == 200
    assert changed.json()["app"]["settings_version"] == 2

    stale = api("POST", f"/v1/apps/{app_id}/archive", headers=owner_headers, json={"expected_settings_version": 1})
    assert stale.status_code == 409
    assert stale.json()["detail"]["code"] == "APP_SETTINGS_VERSION_CONFLICT"
    assert api("PUT", f"/v1/apps/{app_id}/manifest", headers=viewer_headers, json={"expected_version": 1, "manifest": {"tables": {}}}).status_code == 403
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py::test_only_owner_or_admin_can_change_app_settings_or_manifest -q`

Expected: FAIL because settings routes and `APP_MANAGER_REQUIRED` do not exist, and Editor can currently write the Manifest.

- [ ] **Step 3: Implement settings authorization and lifecycle**

Refactor App lookup into a helper that returns `(app, role)` and can explicitly include archived Apps. Add:

```python
class AppSettingsUpdate(BaseModel):
    expected_settings_version: int = Field(ge=1)
    name: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=2000)

class SettingsVersionRequest(BaseModel):
    expected_settings_version: int = Field(ge=1)
```

Require `role in {"owner", "admin"}` for App creation, `PATCH`, archive, restore and `PUT /manifest`. Use conditional `UPDATE ... WHERE settings_version = expected` for settings/archive/restore and return `APP_SETTINGS_VERSION_CONFLICT` when no row updates. Archive leaves rows/releases intact, sets archive actor/time and writes `app.archived`; restore writes `app.restored`. Active App-by-ID reads continue to hide archived Apps from Editor/Viewer and non-members; manager-only list with `status=archived` can expose archived Apps.

- [ ] **Step 4: Run focused App lifecycle tests**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py apps/api/tests/test_space_resources.py -q`

Expected: PASS; settings writes, role gates, archive visibility and existing space-resource behavior are covered.

- [ ] **Step 5: Update API contract and commit**

```bash
git add apps/api/src/vessel_service/apps/router.py apps/api/tests/test_app_management.py docs/api-contract-pages-apps.md
git commit -m "feat: manage Vessel App settings and archives"
```

## Task 3: Extend bounded App data queries and batch delete

**Files:**
- Modify: `apps/api/src/vessel_service/apps/router.py`
- Modify: `apps/api/tests/test_app_management.py`
- Modify: `docs/api-contract-pages-apps.md`

**Interfaces:**
- Consumes: existing typed value normalization, RecordQuery filtering/sorting and row versioning.
- Produces: query `search` plus `POST /records/bulk-delete` all-or-nothing records API.

- [ ] **Step 1: Write failing data-grid behavior tests**

```python
def test_app_record_query_search_and_bulk_delete_are_bounded_and_atomic(api_factory):
    api, prefix, headers, first, second = seeded_text_records(api_factory)
    result = api("POST", f"{prefix}/query", headers=headers, json={"search": "be", "limit": 20})
    assert [row["id"] for row in result.json()["records"]] == [second["id"]]

    stale = api("POST", f"{prefix}/bulk-delete", headers=headers, json={"records": [
        {"id": first["id"], "expected_row_version": first["row_version"]},
        {"id": second["id"], "expected_row_version": 99},
    ]})
    assert stale.status_code == 409
    assert api("GET", f"{prefix}/{first['id']}", headers=headers).status_code == 200

    deleted = api("POST", f"{prefix}/bulk-delete", headers=headers, json={"records": [
        {"id": first["id"], "expected_row_version": first["row_version"]},
        {"id": second["id"], "expected_row_version": second["row_version"]},
    ]})
    assert deleted.json() == {"deleted_count": 2}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py::test_app_record_query_search_and_bulk_delete_are_bounded_and_atomic -q`

Expected: FAIL because `search` is ignored and `bulk-delete` is not registered.

- [ ] **Step 3: Implement the bounded query behavior**

Add `search: str | None = Field(default=None, max_length=120)` to `RecordQuery`, trimming blanks to `None`. Build text search with `or_` across the table's declared `text` fields only, using an escaped case-insensitive substring expression. Include normalized `search` in the cursor signature. Add:

```python
class BulkDeleteRequest(BaseModel):
    records: list[RecordVersion] = Field(min_length=1, max_length=100)
```

Reject duplicate IDs. In one transaction lock/retrieve every active row in the selected App/table, verify every expected row version, then soft-delete all rows and increment each row version. On any missing/stale row rollback every mutation and return the existing generic conflict/not-found behavior. Write only aggregate `records.bulk_deleted` audit details.

- [ ] **Step 4: Run data regressions**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_app_management.py apps/api/tests/test_space_resources.py -q`

Expected: PASS; typed filters, cursors, search and atomic batch deletion remain correct.

- [ ] **Step 5: Commit data APIs**

```bash
git add apps/api/src/vessel_service/apps/router.py apps/api/tests/test_app_management.py docs/api-contract-pages-apps.md
git commit -m "feat: add Vessel App data grid APIs"
```

## Task 4: Validate and persist immutable static H5 releases

**Files:**
- Create: `apps/api/src/vessel_service/apps/h5_release.py`
- Create: `apps/api/src/vessel_service/apps/release_storage.py`
- Create: `apps/api/src/vessel_service/apps/releases.py`
- Modify: `apps/api/src/vessel_service/settings.py`
- Modify: `apps/api/src/vessel_service/main.py`
- Modify: `apps/api/src/vessel_service/apps/router.py`
- Create: `apps/api/tests/test_h5_release.py`

**Interfaces:**
- Consumes: Task 1 release/audit models, Vessel `FilesSettings` read-only OSS configuration convention and manager lookup from Task 2.
- Produces: validated Draft lifecycle and manager API routes, with storage injected through `application.state.app_release_storage`.

- [ ] **Step 1: Write failing ZIP validator tests**

```python
def test_h5_validator_accepts_static_archive_and_rejects_path_escape(tmp_path):
    archive = make_zip(tmp_path, {"index.html": b"<script src='assets/app.js'></script>", "assets/app.js": b"console.log('ok')"})
    result = H5PackageValidator().validate(archive, "app-id", {"tables": {"notes": {"fields": {}}}})
    assert result.entry_file == "index.html"
    assert result.file_count == 2

    unsafe = make_zip(tmp_path, {"../outside.js": b"x", "index.html": b"ok"})
    with pytest.raises(ValueError, match="H5_PATH_TRAVERSAL"):
        H5PackageValidator().validate(unsafe, "app-id", {"tables": {}})
```

- [ ] **Step 2: Run the validator test to verify it fails**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_h5_release.py::test_h5_validator_accepts_static_archive_and_rejects_path_escape -q`

Expected: FAIL because the H5 validator module does not exist.

- [ ] **Step 3: Port only generic archive validation**

Implement `H5PackageValidator` with the approved 50 MiB ZIP, 200 MiB extraction, 2,000 file, 10-level, 10 MiB-file limits; allowlist static extensions; symlink/path escape/secret/file URL rejection; optional `vessel-app.json` App ID and table contract; deterministic content checksum; and guaranteed temporary-directory cleanup. Do not import any Baizhi runtime or account module.

Implement an `AppReleaseStorage` protocol with `put_draft`, `get_draft`, `publish_tree`, `get_published`, and `delete_draft`. Implement a local adapter for test/development and an OSS adapter that obtains configuration read-only from the current Files settings, confines keys to `vessel-apps/`, uses server-side encryption and forbid-overwrite for unversioned buckets. Do not rely on `OSSStorage` private members.

- [ ] **Step 4: Write the failing Draft/Publish state test**

```python
def test_release_draft_preview_never_becomes_current_until_explicit_publish(api_factory, h5_storage, valid_h5_zip):
    api, app_id, manager_headers = manager_app(api_factory, h5_storage)
    draft = api("POST", f"/v1/apps/{app_id}/releases", headers=manager_headers)
    assert draft.status_code == 201
    release_id = draft.json()["release"]["release_id"]

    uploaded = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/upload", headers=manager_headers, files={"file": valid_h5_zip})
    assert uploaded.json()["release"]["status"] == "draft"
    assert uploaded.json()["release"]["is_current"] is False

    published = api("POST", f"/v1/apps/{app_id}/releases/{release_id}/publish", headers=manager_headers)
    assert published.json()["release"]["status"] == "published"
    assert published.json()["release"]["is_current"] is True
```

- [ ] **Step 5: Run the state test to verify it fails**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_h5_release.py::test_release_draft_preview_never_becomes_current_until_explicit_publish -q`

Expected: FAIL because no release routes or state service exist.

- [ ] **Step 6: Implement release lifecycle routes and service**

Add manager-only routes:

```text
POST /v1/apps/{app_id}/releases
GET  /v1/apps/{app_id}/releases
POST /v1/apps/{app_id}/releases/{release_id}/upload
POST /v1/apps/{app_id}/releases/{release_id}/publish
POST /v1/apps/{app_id}/releases/{release_id}/rollback
```

Allocate per-App versions under a database lock. Upload only Draft/`validation_failed` releases. On validation error preserve a `validation_failed` row and code. Publish fetches the private archive, revalidates it against the release's Manifest version, emits immutable static objects, changes the release to `published`, switches `is_current` transactionally and deletes the Draft archive only after final metadata succeeds. Retried publish reads exact immutable keys/checksum and never overwrites a release tree. Rollback switches only to an already published release. Each transition writes its allowed audit event.

- [ ] **Step 7: Run release unit/API tests and commit**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_h5_release.py tests/test_app_management.py -q`

Expected: PASS; valid Draft, unsafe upload, manager authorization, publish and rollback paths are covered.

```bash
git add apps/api/src/vessel_service/apps/h5_release.py apps/api/src/vessel_service/apps/release_storage.py apps/api/src/vessel_service/apps/releases.py apps/api/src/vessel_service/settings.py apps/api/src/vessel_service/main.py apps/api/src/vessel_service/apps/router.py apps/api/tests/test_h5_release.py
git commit -m "feat: add immutable Vessel App releases"
```

## Task 5: Serve static releases and scope H5 data credentials

**Files:**
- Modify: `apps/api/src/vessel_service/auth/router.py`
- Modify: `apps/api/src/vessel_service/auth/tokens.py`
- Modify: `apps/api/src/vessel_service/apps/router.py`
- Modify: `apps/api/src/vessel_service/main.py`
- Create: `apps/api/tests/test_h5_gateway.py`
- Modify: `docs/api-contract-pages-apps.md`

**Interfaces:**
- Consumes: Task 4 release service and storage adapter plus existing `KeyRing` and refresh-session metadata.
- Produces: private-store static gateway, ten-minute Draft previews and a five-minute App-scoped H5 data token.

- [ ] **Step 1: Write failing gateway and token-isolation tests**

```python
def test_public_release_assets_are_versioned_and_missing_assets_do_not_fall_back(api_factory, published_release):
    api, app_id, version = published_release
    assert api("GET", f"/apps/{app_id}/releases/{version}/index.html").status_code == 200
    assert api("GET", f"/apps/{app_id}/releases/{version}/missing.js").status_code == 404
    assert api("GET", f"/apps/{app_id}/releases/{version}/projects/next").status_code == 200


def test_h5_token_cannot_manage_or_cross_app(api_factory, refresh_cookie, published_release, other_app):
    api, app_id, version = published_release
    token = api("POST", f"/v1/apps/{app_id}/h5/session", cookies=refresh_cookie, json={"release_version": version}).json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert api("GET", f"/v1/apps/{other_app}", headers=headers).status_code == 404
    assert api("POST", f"/v1/apps/{app_id}/releases", headers=headers).status_code == 401
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_h5_gateway.py -q`

Expected: FAIL because public release gateway and H5 session route do not exist.

- [ ] **Step 3: Implement gateway, preview tickets and H5 principal**

Add a signed HMAC preview ticket containing the App ID, release ID and expiry. Validate it without logging its value. Serve preview bytes only for a Draft, implement SPA fallback only for extensionless routes, and return 404 for missing asset paths. Serve published objects through `/apps/{app_id}/releases/{version}/{path}` with MIME type inferred from validated static extensions, `X-Content-Type-Options: nosniff`, and immutable cache controls.

Extract refresh-cookie-to-user validation into a reusable auth helper used by `/v1/auth/refresh` and the new H5 session endpoint. Issue an EdDSA token with this exact claim set:

```python
keyring.issue(
    subject=user.user_id,
    issuer=settings.issuer_url,
    audience="vessel-app-h5",
    scope="vessel:app-h5",
    lifetime_seconds=300,
    additional_claims={"app_id": app_id, "release_version": release.version},
)
```

Add a separate App-record principal dependency that accepts either the ordinary `vessel-api` session token or the H5 audience token. H5 tokens must match the requested App ID and must always re-check space role. All non-record routes retain their ordinary `vessel-api` dependency and reject H5 tokens.

- [ ] **Step 4: Run gateway and authorization tests**

Run: `cd apps/api && .venv/bin/python -m pytest tests/test_h5_gateway.py tests/test_h5_release.py tests/test_app_management.py -q`

Expected: PASS; static, preview, H5 session and regular API authorization contracts hold.

- [ ] **Step 5: Commit gateway and contract**

```bash
git add apps/api/src/vessel_service/auth/router.py apps/api/src/vessel_service/auth/tokens.py apps/api/src/vessel_service/apps/router.py apps/api/src/vessel_service/main.py apps/api/tests/test_h5_gateway.py docs/api-contract-pages-apps.md
git commit -m "feat: serve Vessel App releases securely"
```

## Task 6: Implement Settings, Data and Publish views in the Web console

**Files:**
- Modify: `apps/web/src/api.ts`
- Modify: `apps/web/src/Apps.tsx`
- Modify: `apps/web/src/console.css`
- Modify: `apps/web/src/App.tsx`

**Interfaces:**
- Consumes: Tasks 2 through 5 API routes and existing `Permissions` data.
- Produces: English App workspace with role-aware Settings, typed data grid and publishing user flows.

- [ ] **Step 1: Write failing browser E2E assertions for the App workspace**

```javascript
test("App managers publish a draft while Editors only edit typed data", async ({ browser }) => {
  const { ownerPage, editorPage, viewerPage, app } = await createManagedApp(browser);
  await ownerPage.getByRole("button", { name: "Settings" }).click();
  await expect(ownerPage.getByLabel("App description")).toBeVisible();
  await editorPage.getByRole("button", { name: "Settings" }).click();
  await expect(editorPage.getByRole("button", { name: "Save app settings" })).toBeDisabled();
  await editorPage.getByRole("button", { name: "Data" }).click();
  await editorPage.getByLabel("Edit title for record 1").fill("Updated by editor");
  await ownerPage.getByRole("button", { name: "Publish" }).click();
  await expect(ownerPage.getByRole("button", { name: "Upload H5 ZIP" })).toBeVisible();
  await expect(viewerPage.getByRole("button", { name: "Upload H5 ZIP" })).toBeDisabled();
});
```

- [ ] **Step 2: Run the E2E assertion to verify it fails**

Run: `npm run test:console -- --grep "App managers publish a draft"`

Expected: FAIL because the existing basic Apps panel has no Settings/Data/Publish tabs or H5 upload interface.

- [ ] **Step 3: Add typed API interfaces and Console state**

In `api.ts`, add types/functions for `VesselApp.description`, `settings_version`, `status`, audit pages, query search, bulk delete, H5 release list/upload/publish/rollback and manager mutations. Keep numbers as strings for `numeric` fields; reuse `parseValue` and `asInput` without sending `numeric` through JavaScript `Number`.

In `Apps.tsx`, split the selected App workspace into `Settings`, `Data`, and `Publish` tabs. Settings provides detail saves, guided add-table/add-nullable-field forms, raw Manifest update and archive/restore. Data provides table selection, server-side search, bounded query filters/sorts, inline typed edit, record create modal, multi-select deletion confirmation, pagination and explicit conflict reload. Publish provides a ZIP selector, Draft status, Preview link, explicit Publish action, release history and Rollback.

Every manager action is disabled where `permissions.role` is not `owner` or `admin`; Data mutation remains enabled for Editor. Keep all copy English and preserve the existing global error surface.

- [ ] **Step 4: Run TypeScript build and targeted browser E2E**

Run:

```bash
npm run build:web
npm run test:console -- --grep "App managers publish a draft"
```

Expected: build PASS; targeted browser test passes against isolated PostgreSQL with local App-release storage.

- [ ] **Step 5: Commit console implementation**

```bash
git add apps/web/src/api.ts apps/web/src/Apps.tsx apps/web/src/console.css apps/web/src/App.tsx tests/e2e/apps-management.spec.mjs
git commit -m "feat: manage and publish Vessel Apps in console"
```

## Task 7: Run integrated verification and document deployment boundary

**Files:**
- Modify: `README.md`
- Modify: `docs/api-contract-pages-apps.md`
- Modify: `docs/db-schema.md`
- Modify: `tests/e2e/apps-management.spec.mjs`

**Interfaces:**
- Consumes: all preceding API, migration and console changes.
- Produces: reproducible local usage and verified primary owner/admin/editor/viewer path.

- [ ] **Step 1: Add a real browser E2E with local release storage**

The test must create a team App in the isolated PostgreSQL service, make a valid in-memory static ZIP, upload it as a Draft, open Preview, publish it, fetch its immutable public path, make a second release current through Rollback, then verify Editor data write and Viewer read-only behavior. It must not depend on a user database at port 52003 or real OSS credentials.

- [ ] **Step 2: Run focused API test suite**

Run:

```bash
cd apps/api && .venv/bin/python -m pytest \
  tests/test_app_management.py tests/test_h5_release.py tests/test_h5_gateway.py tests/test_space_resources.py -q
```

Expected: fewer than 100 test cases, all PASS.

- [ ] **Step 3: Run browser and build verification**

Run:

```bash
npm run build:web
npm run test:console -- --grep "App managers publish a draft|registration, team sharing, Pages editing and Apps records"
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Perform local HTTP E2E and document OSS boundary**

Start the isolated PostgreSQL service with local App-release storage, then run the new browser test against its real HTTP endpoint. Update `README.md` with release storage configuration, the safe local test path and the exact live-OSS configuration requirement. If a dedicated non-production OSS configuration is available, run one actual upload/publish/fetch cycle; otherwise record that the OSS adapter's live behavior is unverified.

- [ ] **Step 5: Commit verification/docs changes**

```bash
git add README.md docs/api-contract-pages-apps.md docs/db-schema.md tests/e2e/apps-management.spec.mjs
git commit -m "docs: verify Vessel App management workflow"
```

## Plan Self-Review

- **Spec coverage:** Task 1 implements settings/release/audit persistence; Task 2 implements manager role gates and App lifecycle; Task 3 implements data filters/search/bulk deletion; Task 4 implements H5 validation, Draft, Publish and Rollback; Task 5 implements Preview, public static gateway and H5-scoped access; Task 6 implements all Console views; Task 7 runs primary-path verification and records the OSS boundary.
- **Placeholder scan:** The plan has no `TBD`, `TODO`, “implement later”, or undefined task references.
- **Type consistency:** Settings writes use `expected_settings_version`; schema writes use the existing `expected_version`; row writes use `expected_row_version`; H5 release routes always use `release_id` and published gateway paths always use a per-App `version`.
