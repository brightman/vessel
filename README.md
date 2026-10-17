# Memory on Cloud

Coding agents can use the standalone [`vessel` CLI](tools/vessel-cli/README.md) for signed-in HTTP operations on spaces, Files, Pages, and Apps. It uses named environments, OS credential storage, and JSON output; it does not access Vessel's database directly.

Memory on Cloud is the public brand for Vessel, a storage service for people using coding agents. It provides personal and team spaces for files, structured tables, and block-based Pages. File bytes live in private OSS/S3 storage; Vessel owns its accounts, metadata, authorization, and APIs. A small Web console is available for account, team, Pages, and Apps management.

The API foundation is imported from Baizhi Pages. It supports independent local accounts, personal spaces, teams, invitations, member roles, space-owned Pages, and structured Apps tables. Team members see resources by default; viewers read and editors write. The inherited Baizhi Page Agent routes are not exposed in the Vessel API; Vessel will use a separate Page Agent. Shared files now support private Aliyun OSS storage, personal sharing, team folders, versions and a recoverable file worker. See the [file API contract](docs/api-contract-files.md) and [file runtime guide](docs/files-runtime.md). See the [API contract](docs/api-contract-pages-apps.md), [identity and team design](docs/identity-team-design.md), [database schema](docs/db-schema.md), [overall technical design](docs/technical-design.md), and [import record](docs/source-import.md).

## Run the API

Install the locked Python dependencies from `apps/api` with `uv sync`. Create a dedicated PostgreSQL database, then from the repository root set `PAGES_DATABASE_URL` to that database and run `bash scripts/dev/start-api.sh`. The script applies Alembic migrations and starts Uvicorn. Set `PAGES_ALLOW_REGISTRATION=true` only in an isolated development environment when self-registration is needed. Health endpoints are `/healthz` and `/readyz`; the OpenAPI document is `/openapi.json`. The primary API reference is Scalar at `/docs`; Swagger UI remains at `/swagger` and ReDoc at `/redoc`.

## Website and Web console

Run `npm ci && npm run build:marketing && npm run build:web` from the repository root before starting the API. Open `http://127.0.0.1:52003/` for the Memory on Cloud website, `/console` to log in to the Vessel management console, or `/register` to create an account when `PAGES_ALLOW_REGISTRATION=true`. For plain HTTP on local loopback, set `PAGES_REFRESH_COOKIE_SECURE=false` so the browser can retain the refresh cookie; keep it true under HTTPS. Both static sites are served by the same FastAPI origin; the public website uses `/assets/*`, while console assets remain under `/console/assets/*`. The console calls the existing `/v1` endpoints. For frontend development, `npm run dev:web` serves Vite on port 52004 and proxies `/v1` to the API on port 52003.

The console reuses the Baizhi Pages Tiptap block editor. Team Pages and Apps use the selected Vessel space and current role capabilities. The inherited Baizhi Page Agent UI is not included; Page image upload controls are disabled in this increment, while existing images can still be displayed. Unsaved Page drafts stay in browser memory and are lost on reload; save them before closing the tab. Team invitations require the invitee's existing Vessel user ID.

Files has a complete browser console: current-space folders, server-side search, shared-with-me, detail metadata, direct personal shares, version history, downloads, folder moves with permission previews, trash/restore and Owner/Admin purge jobs. Team members use their current role; personal share recipients do not receive access to the source-space root. Browser uploads hash 4 MiB chunks in a Worker, send file bytes directly to signed OSS URLs, upload at most two files and three parts per file concurrently, and keep only active upload IDs in user-scoped `sessionStorage`. A page refresh can query those upload statuses, but cannot resume file bytes automatically; choose the file again to start another upload. Signing URLs, OSS headers, access tokens, byte content and file names are never persisted by the console.

Run the Files worker with the API environment before uploading: `cd apps/api && PYTHONPATH=src .venv/bin/python -m vessel_service.files.worker`. For a browser OSS test, authorize a narrowly scoped CORS rule for the exact local API Origin, `PUT`, the signed OSS request headers, and expose `ETag` for multipart receipts. The real upload path reports a temporary storage outage or quota/size limit while directory browsing remains available. Files currently use the API limits of 512 MiB per file, 10 GiB per space, 32 folder levels and 30 days of trash retention.

## App publishing

Apps have manager-only Settings and Publish workspaces, plus a role-aware Data workspace. Owners and Admins may change settings and additive schemas, archive or restore Apps, upload a static H5 ZIP, preview its Draft, explicitly publish it, and roll back the current public release. Editors can create and update typed records; Viewers can read them. `PAGES_APP_RELEASE_ORIGIN` defines a separate release zone, and every App runs on its own subdomain within that zone. The console creates a five-minute launch URL bound to the signed-in member, App, and release, then that App's release host exchanges its host-only, path-scoped HttpOnly launch Cookie for an App-only token. A direct public URL remains static-only; Draft archives and preview tickets remain private.

For local development and browser E2E, leave `VESSEL_FILES_OSS_FINAL_BUCKET` and `VESSEL_FILES_OSS_CONFIG_FILE` unset. The API then uses private local storage at `PAGES_APP_RELEASE_STORAGE_PATH` (default `var/app-releases`). Use an isolated PostgreSQL database and a temporary release directory:

```bash
bash scripts/dev/start-e2e-postgres.sh
export PAGES_DATABASE_URL='postgresql+psycopg://vessel@127.0.0.1:<printed-port>/vessel_e2e'
PAGES_ALLOW_REGISTRATION=true \
PAGES_REFRESH_COOKIE_SECURE=false \
PAGES_ISSUER_URL='http://api.127.0.0.1.nip.io:52013' \
PAGES_APP_RELEASE_ORIGIN='http://apps.127.0.0.1.nip.io:52013' \
PAGES_PORT=52013 \
PAGES_APP_RELEASE_STORAGE_PATH="$(mktemp -d /private/tmp/vessel-app-releases.XXXXXX)" \
bash scripts/dev/start-api.sh

VESSEL_E2E_ORIGIN=http://api.127.0.0.1.nip.io:52013 \
VESSEL_RELEASE_ORIGIN=http://apps.127.0.0.1.nip.io:52013 \
npm run test:console -- --grep 'App managers publish a draft'
```

`PAGES_APP_RELEASE_ORIGIN` must be a complete `http` or `https` release-zone origin whose hostname differs from `PAGES_ISSUER_URL`; production requires HTTPS. A release for App `<app_id>` is served from `https://<app_id>.apps.example`, when the configured base is `https://apps.example`. Default ports are normalized, so `https://apps.example:443` is equivalent to `https://apps.example`; non-default ports are preserved. For local browser E2E, `apps.127.0.0.1.nip.io` resolves both the base and `<app_id>.apps.127.0.0.1.nip.io` to loopback. The gateway serves each App's published and preview assets only from that App's host. It permits cross-origin H5 data calls only from that App's exact origin to its own typed record endpoints; `/v1/auth/refresh` rejects browser requests from every release origin.

When `VESSEL_FILES_OSS_FINAL_BUCKET` or `VESSEL_FILES_OSS_CONFIG_FILE` is configured, App releases reuse that read-only OSS connection configuration. Final release objects use immutable `vessel-apps/{app_id}/releases/{version}/` keys; Draft ZIPs use private `vessel-apps/{app_id}/drafts/{release_id}.zip` keys. The configuration must provide an HTTPS endpoint, region, temporary and final buckets, and runtime credentials through a RAM role, environment, or approved config file. Bucket versioning is preferred. An unversioned final bucket requires the explicit `VESSEL_FILES_OSS_ALLOW_UNVERSIONED=true` opt-in and uses OSS forbid-overwrite headers.

Before production deployment, run a ZIP upload, preview, publish, public-asset fetch, and rollback against a dedicated non-production OSS configuration. That live OSS verification has not been performed by this repository's local test suite. Production also requires `PAGES_H5_PREVIEW_SECRET`, `PAGES_APP_RELEASE_ORIGIN` on a separate HTTPS release zone such as `https://apps.memoryon.cloud`, wildcard DNS for `*.apps.memoryon.cloud`, a TLS certificate that covers that wildcard, `PAGES_SIGNING_KEYS_FILE`, HTTPS cookies, and production database configuration; do not point exploratory E2E runs at a production OSS bucket.

The imported configuration still uses the `PAGES_*` prefix. Vessel user sessions use the `vessel-api` audience, `vessel:session` scope and `vessel_refresh` cookie. The old `baizhi-pages-mcp` capability and Agent Platform routes are test-only compatibility code and are not registered by the normal application. See `docs/source-import.md` for the import boundary.

The current identity increment invites existing active Vessel users by `user_id`. Self-registration defaults to disabled. Self-registration requires a single-use six-digit email code through Brevo before account creation. Configure the API key, verified sender and code secret as described in [registration email verification](docs/registration-email.md); migration `0011_registration_email` persists verification state. Real delivery and deployment need separate target-environment acceptance. Self-service password reset is a separate future feature. Keep public registration disabled until the email flow is configured and verified for the target environment. In an isolated development database, enable registration to exercise the team API. The team endpoints are `GET /v1/spaces`, `GET /v1/spaces/{id}/permissions`, `POST /v1/teams`, `GET /v1/teams/{id}`, `GET /v1/teams/{id}/members`, `GET/POST /v1/teams/{id}/invitations`, `DELETE /v1/teams/{id}/invitations/{invitation_id}`, `GET /v1/team-invitations`, `POST /v1/team-invitations/{id}/accept`, and `PATCH/DELETE /v1/teams/{id}/members/{user_id}`.

With the database migrated and `PAGES_DATABASE_URL` set, a server operator can create the first administrator with `cd apps/api && PYTHONPATH=src .venv/bin/python -m vessel_service.bootstrap_admin`. To provision a regular teammate while public registration is disabled, add `--role user`. The command prompts for the password without echoing it and creates the account with a personal space.

For a local isolated PostgreSQL E2E run, execute `bash scripts/dev/start-e2e-postgres.sh`, export the printed `PAGES_DATABASE_URL`, start the API with `PAGES_ALLOW_REGISTRATION=true bash scripts/dev/start-api.sh`, then run `apps/api/.venv/bin/python scripts/dev/team_http_e2e.py http://127.0.0.1:52003`. Stop the API and PostgreSQL using the command printed by the database script.

With registration left disabled, `PAGES_DATABASE_URL=... apps/api/.venv/bin/python scripts/dev/local_user_http_e2e.py http://127.0.0.1:52003` verifies controlled local provisioning and login against the same isolated setup.

## Shared files

File endpoints are registered under `/v1/spaces/{space_id}/file-items`, `/folders`, `/file-uploads` and resource-ID paths. They use the same Vessel access token and current team roles. Personal files/folders can be shared with existing users as viewer/editor. Page directories and assets are separate.

Configure `VESSEL_FILES_OSS_*` or read an existing approved configuration through `VESSEL_FILES_OSS_CONFIG_FILE`; no secrets are copied. Reusing an unversioned Bucket requires explicit `VESSEL_FILES_OSS_ALLOW_UNVERSIONED=true` and a dedicated `VESSEL_FILES_OSS_PREFIX`. Migration `0009_shared_files` creates the independent file metadata schema.

Run `PYTHONPATH=src .venv/bin/python -m vessel_service.files.worker` from `apps/api` with the same environment as the API. The worker is required for restart recovery, expired uploads and delayed object cleanup. See [files-runtime.md](docs/files-runtime.md) for settings, validation evidence and limits. The `vessel` CLI supports common File listing, search, upload, download and version reads; sharing mutation and MCP remain outside its current scope.
