# Vessel Apps Management and Publishing Design

**Status:** Approved for implementation
**Date:** 2026-10-15
**Scope:** Vessel Apps Settings, Data, and static H5 Publishing

## Goal

Bring the useful Apps management flows from `baizhi-agent` into Vessel: an App settings workspace, a complete structured-data grid, and a static H5 release lifecycle. Each App remains owned by one Vessel space and continues to use Vessel accounts and role-based authorization.

## Reference and adaptation boundary

The reference implementation is the Apps UI and backend at Baizhi Agent commit `e2f073de`, especially `static/apps-app.jsx`, `apps/h5_release.py`, and the H5 release repository/service. Vessel will reuse the interaction and release concepts, but will not copy these Baizhi-specific parts:

- Supabase schemas, SQL policy expressions, `owner_id` rows, or App-level grants.
- Platform-admin identity, company identity, Agent executor bindings, Field Agents, or MCP runtime tools.
- Baizhi OIDC sessions and any Baizhi access or object-storage credentials.

Vessel keeps its existing PostgreSQL metadata tables, independent identity, space membership, and Aliyun OSS boundary.

## Roles and resource boundary

An App belongs to exactly one active Vessel space. App and release access checks resolve the current caller's membership on every request.

| Action | Owner | Admin | Editor | Viewer | Non-member |
| --- | --- | --- | --- | --- | --- |
| Read App metadata, schema, records and release history | Yes | Yes | Yes | Yes | 404 |
| Read an already published static file | Public | Public | Public | Public | Public |
| Create, edit, delete and restore records | Yes | Yes | Yes | 403 | 404 |
| Create App, update App details, change Manifest, archive or restore App | Yes | Yes | 403 | 403 | 404 |
| Create Draft, upload H5 package, preview, publish or rollback | Yes | Yes | 403 | 403 | 404 |
| Obtain an App-scoped H5 data session | Yes | Yes | Yes | Yes | 404 |

`Owner` and `Admin` are the App managers. `Editor` is a data editor. This narrows the present generic `can_write` check for Manifest updates to preserve a clear distinction between team data work and schema or public release changes.

A public published release exposes only immutable static assets. It does not expose App records. A signed-in user who opens an H5 release can explicitly exchange the existing Vessel refresh session for a short-lived token scoped to that one App; that token can call only the App record APIs allowed by the caller's current space role. It cannot call Files, Pages, Teams, Settings, Publishing, or another App.

## User experience

The existing Console `Apps` view becomes an App workspace with three tabs after an App is selected.

### Settings

- App name and optional description, with `settings_version` conflict detection.
- Schema table list, a guided add-table form, and a guided add-nullable-field form.
- A raw Manifest editor for the same additive changes already supported by Vessel.
- Archived Apps can be restored by a manager and are hidden from the active App list.
- Manager actions remain unavailable to Editor and Viewer roles.

The first release keeps Vessel's additive Schema rule: create tables and add nullable fields. It does not allow deleting or renaming tables or fields, changing field types, raw SQL policies, or importing Baizhi Agent Field Agents.

### Data

- Switch tables within the selected App.
- A paged grid that displays typed values and record version state.
- Create-record modal, inline cell editing, row selection, confirmation before bulk deletion, and a reload path after a row version conflict.
- A bounded query builder for the supported filter and sort contract.
- Text search across declared text fields, executed server-side and bounded to the selected App/table.

The grid never converts an `integer` or `numeric` value through JavaScript `Number` before writing it. It preserves numeric input as validated text for the API's existing decimal-string representation.

### Publishing

- A manager creates a numbered H5 Draft and uploads one built ZIP archive.
- The service validates it and returns a short-lived Preview URL. Uploading or opening a Preview never makes it public.
- A manager explicitly publishes a selected valid Draft. The release becomes the App's current published release.
- A manager can make any earlier published release current again. Published assets are never overwritten.
- Release history displays version, status, Manifest version, checksum, file count, size, actor and timestamps.

The console uses the existing English-language Vessel UI. No build step, package manager, script execution, or generated server code runs while uploading a release.

## Data model and migration

Create Alembic migration `0010_app_management_publishing`, following `0009_shared_files`.

### Changes to `vessel_apps`

| Column | Type | Meaning |
| --- | --- | --- |
| `description` | `varchar(2000) not null default ''` | User-visible App description. |
| `settings_version` | `integer not null default 1` | Optimistic-lock version for App details and archive state. |
| `status` | existing `varchar(16)` | Values become `active` or `archived`; existing records remain `active`. |
| `archived_at` | `timestamptz null` | Audit timestamp for archive state. |
| `archived_by` | FK `users.user_id`, null | Manager who archived the App. |

`manifest_version` remains the independent optimistic-lock version for schema changes.

### `vessel_app_releases`

| Column | Type | Meaning |
| --- | --- | --- |
| `release_id` | `varchar(36)` primary key | Server-generated UUID. |
| `app_id` | FK `vessel_apps.app_id` | Owning App. |
| `version` | integer | Monotonic per-App release number. |
| `manifest_version` | integer | Manifest revision validated for this release. |
| `status` | varchar(32) | `draft`, `validation_failed`, or `published`. |
| `entry_file` | varchar(512), nullable | Validated entry point. |
| `object_prefix` | varchar(512) unique | Immutable final release prefix. |
| `draft_object_key` | varchar(512) unique | Private Draft archive key. |
| `file_count` | integer, nullable | Validated package file count. |
| `total_size_bytes` | bigint, nullable | Extracted package byte count. |
| `checksum_sha256` | varchar(64), nullable | Content-tree checksum. |
| `validation_error_code` | varchar(128), nullable | Stable package validation failure. |
| `created_by` / `created_at` | user FK / timestamptz | Draft creator and time. |
| `published_by` / `published_at` | user FK / timestamptz nullable | Publisher and time. |
| `is_current` | boolean not null default false | Current published release. |

Constraints:

- `unique(app_id, version)`.
- At most one current release per App through a partial unique index on `app_id where is_current`.
- A current release must have `status='published'`, enforced by `check (not is_current or status = 'published')` and application transactions.
- A release object prefix is stable: `vessel-apps/{app_id}/releases/{version}/`.
- A Draft archive key is stable: `vessel-apps/{app_id}/drafts/{release_id}.zip`.

### `vessel_app_audit_events`

| Column | Type | Meaning |
| --- | --- | --- |
| `event_id` | UUID string primary key | Server-generated ID. |
| `app_id` | FK App | Related App. |
| `release_id` | FK release, nullable | Related release when relevant. |
| `actor_user_id` | FK user | Authenticated actor. |
| `action` | varchar(64) | `app.updated`, `app.archived`, `manifest.updated`, `records.bulk_deleted`, `release.created`, `release.uploaded`, `release.validation_failed`, `release.published`, or `release.rolled_back`. |
| `details_json` | JSONB/JSON | IDs, counts, checksum and versions only; no record values, archive contents, tokens or signed URLs. |
| `created_at` | timestamptz | Event time. |

## H5 archive validation and storage

Port the generic package-validation rules from Baizhi's `h5_release.py` to a Vessel module. The validator uses an isolated temporary directory and removes it in `finally`.

- ZIP archive maximum: 50 MiB.
- Extracted content maximum: 200 MiB, 2,000 files, 10 path components, and 10 MiB per file.
- Required entry: `index.html` or `dist/index.html`.
- Allow: HTML, CSS, JS, JSON, fonts, images and SVG. Reject symlinks, absolute paths, traversal paths, executables, dynamic code, database files, private-key files and environment files.
- Reject `file://` references in the entry file and secret markers in any extracted file.
- Optional `vessel-app.json` may declare `app_id`, required tables and required CRUD operations. The validator verifies the App ID and current Manifest without granting capabilities beyond the Vessel role model.
- Build the checksum from sorted relative paths plus each file's SHA-256.

The server stores the uploaded archive privately. On Publish it validates the same archive again, expands files into the release's immutable prefix, then changes release metadata and `is_current` in one database transaction. If database finalization fails after objects are copied, retrying Publish must reconcile the exact object keys/checksum instead of overwriting assets.

Vessel's current configured OSS bucket may be unversioned. Release keys include the immutable App/version prefix and must use `x-oss-forbid-overwrite`; neither `latest` objects nor mutable release paths are used. A dedicated `AppReleaseStorage` adapter will use the existing `FilesSettings` read-only credential/configuration boundary but hard-code the release prefix and expose only archive upload, immutable-object publication and exact-object reads. It must not call `OSSStorage` private methods or add secrets to the database, response body or logs. Vessel's public `/apps/...` gateway serves static bytes from that private storage; it does not make OSS objects public.

## HTTP API

All routes require a Vessel access token unless documented as public static content. Error shape stays `{"detail":{"code":"..."}}`.

### App Settings

| Method and path | Request | Response | Role |
| --- | --- | --- | --- |
| `GET /v1/apps/{app_id}` | — | App including description, versions and status | Reader |
| `PATCH /v1/apps/{app_id}` | `expected_settings_version`, optional `name`, `description` | Updated App | Owner/Admin |
| `POST /v1/apps/{app_id}/archive` | `expected_settings_version` | Updated App | Owner/Admin |
| `POST /v1/apps/{app_id}/restore` | `expected_settings_version` | Updated App | Owner/Admin |
| `PUT /v1/apps/{app_id}/manifest` | existing `expected_version`, `manifest` | Updated App | Owner/Admin |
| `GET /v1/apps/{app_id}/audit-events?cursor=&limit=50` | — | keyset-paged audit events | Owner/Admin |

`PATCH` only accepts a nonblank name and a trimmed description of at most 2,000 characters. Any stale setting write returns `409 APP_SETTINGS_VERSION_CONFLICT`; stale Manifest writes continue to return `409 APP_MANIFEST_VERSION_CONFLICT`.

`GET /v1/spaces/{space_id}/apps` defaults to active Apps and accepts `status=active|archived` for managers. Viewer, Editor and non-members never receive archived Apps through the regular list.

### Data grid

Keep existing single-record endpoints and add bounded extensions under `/v1/apps/{app_id}/tables/{table_name}`.

| Method and path suffix | Request | Response | Role |
| --- | --- | --- | --- |
| `POST /records/query` | existing filter/sort/cursor plus `search` | records and `next_cursor` | Reader |
| `POST /records/bulk-delete` | `records: [{id, expected_row_version}]`, 1–100 | `deleted_count` | Owner/Admin/Editor |
| `POST /records/{record_id}/restore` | existing expected row version | record | Owner/Admin/Editor |

Search is a maximum-120-character case-insensitive substring over `text` fields declared in the selected table. It combines with the existing bounded `and` filter and sort. Search, filters and sort form part of the cursor signature. API limits remain at 200 records/page and 3 sort clauses; batch deletion is all-or-nothing and returns `409 APP_RECORD_VERSION_CONFLICT` when any selected row is stale or unavailable.

No raw SQL, cross-App queries, cross-space queries, per-row ACL, Field Agent actions or arbitrary filter expressions are added.

### H5 releases

| Method and path | Request | Response | Role |
| --- | --- | --- | --- |
| `POST /v1/apps/{app_id}/releases` | — | 201 Draft release | Owner/Admin |
| `GET /v1/apps/{app_id}/releases` | — | release history | Reader |
| `POST /v1/apps/{app_id}/releases/{release_id}/upload` | multipart `file` ZIP | validated Draft release | Owner/Admin |
| `POST /v1/apps/{app_id}/releases/{release_id}/publish` | — | current published release | Owner/Admin |
| `POST /v1/apps/{app_id}/releases/{release_id}/rollback` | — | selected current release | Owner/Admin |
| `GET /v1/apps/{app_id}/releases/{release_id}/preview/{path}?ticket=` | short-lived signed ticket | Draft static bytes | Ticket holder |
| `POST /v1/apps/{app_id}/h5/session` | — | short-lived App-scoped token | Reader |
| `GET /apps/{app_id}/releases/{version}/{path}` | no token | published static bytes | Public |

`upload` accepts only a Draft or `validation_failed` release. It sets `validation_failed` and a stable error code on archive validation failure; it never changes the current release. `publish` accepts only a valid Draft. `rollback` accepts only a published release and changes only the current pointer.

Preview tickets bind `app_id`, `release_id`, an expiry of ten minutes and a signature. They are not logged or persisted. Preview supports static asset paths and SPA fallback to the entry file; missing assets return 404 rather than HTML.

`POST /h5/session` authenticates through the existing refresh cookie. The request identifies a published `release_version`; the server validates that release belongs to the requested App, then issues a five-minute JWT with `aud=vessel-app-h5`, `scope=vessel:app-h5`, `sub=<user_id>`, `app_id=<app_id>` and `release_version=<version>`. Referrer and browser origin are not treated as authorization evidence. App read/write routes accept it only after verifying those claims and current space membership. Manager and all non-App routes reject it.

## Error contract

| HTTP | Code | Meaning |
| --- | --- | --- |
| 403 | `APP_MANAGER_REQUIRED` | A Viewer or Editor attempted App configuration or publishing. |
| 404 | `APP_NOT_FOUND`, `APP_RELEASE_NOT_FOUND` | Resource is absent or hidden from caller. |
| 409 | `APP_SETTINGS_VERSION_CONFLICT`, `APP_MANIFEST_VERSION_CONFLICT`, `APP_RECORD_VERSION_CONFLICT`, `APP_RELEASE_NOT_PUBLISHABLE` | Optimistic concurrency or invalid state transition. |
| 422 | `H5_PACKAGE_TOO_LARGE`, `H5_PATH_TRAVERSAL`, `H5_FILE_TYPE_NOT_ALLOWED`, `H5_ENTRY_NOT_FOUND`, `H5_APP_ID_MISMATCH`, `H5_MANIFEST_TABLE_MISSING`, `H5_SECRET_DETECTED` | ZIP or contract validation failed. |
| 503 | `APP_RELEASE_STORAGE_UNAVAILABLE` | OSS is absent or cannot safely satisfy the release operation. |

## Test strategy

1. **API and database tests**
   - Owner/Admin versus Editor/Viewer authorization for settings, Manifest, archive and publishing.
   - App settings and Manifest optimistic-lock conflicts.
   - Bounded text search, filter/sort cursor integrity, and all-or-nothing bulk delete.
   - Archive hides an App from normal lists without deleting records or release history.
   - ZIP validator success and traversal, symlink, illegal type, oversized archive, secret and Manifest mismatch failures.
   - Draft upload does not become current; Publish creates a current immutable release; rollback changes only the pointer.
   - H5-scoped token cannot read a different App or call Pages, Files, Teams, Settings or Publishing.

2. **Browser E2E using isolated PostgreSQL**
   - Owner creates a team App, Admin updates its Schema, Editor changes a record, Viewer reads only.
   - Owner creates a valid H5 Draft, opens Preview, explicitly publishes it, then rolls back to a prior release.
   - Data-grid create, inline update, filtering and conflict reload behaviour.

3. **Build and integrity checks**
   - Targeted pytest suite and affected console Playwright tests, kept below the repository's 100-test limit.
   - `npm run build:web`, `git diff --check`, and a local service health check.
   - Real OSS publishing E2E runs only when a dedicated non-production OSS configuration is available. Without it, record the exact unverified boundary rather than claiming live publishing is verified.

## Out of scope

This release does not add custom domains, anonymous data access, payment plans, App-specific team roles, arbitrary server-side H5 code, custom backends, H5 deployment from source repositories, direct database connections, CSV import/export, public record sharing, Field Agents, MCP execution, or Baizhi Agent's page/runtime identity.
