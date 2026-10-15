# Vessel

Vessel is a storage service for people using coding agents. It will provide personal and team spaces for files, structured tables, and block-based Pages. File bytes will live in private OSS/S3 storage; Vessel owns its accounts, metadata, authorization, and APIs. A small Web console is available for account, team, Pages, and Apps management.

The API foundation is imported from Baizhi Pages. It supports independent local accounts, personal spaces, teams, invitations, member roles, space-owned Pages, and structured Apps tables. Team members see resources by default; viewers read and editors write. The inherited Baizhi Page Agent routes are not exposed in the Vessel API; Vessel will use a separate Page Agent. General OSS/S3 files remain a later increment. See the [API contract](docs/api-contract-pages-apps.md), [identity and team design](docs/identity-team-design.md), [database schema](docs/db-schema.md), [overall technical design](docs/technical-design.md), and [import record](docs/source-import.md).

## Run the API

Install the locked Python dependencies from `apps/api` with `uv sync`. Create a dedicated PostgreSQL database, then from the repository root set `PAGES_DATABASE_URL` to that database and run `bash scripts/dev/start-api.sh`. The script applies Alembic migrations and starts Uvicorn. Set `PAGES_ALLOW_REGISTRATION=true` only in an isolated development environment when self-registration is needed. Health endpoints are `/healthz` and `/readyz`; the OpenAPI document is `/openapi.json`.

## Web console

Run `npm ci && npm run build:web` from the repository root before starting the API. Open `http://127.0.0.1:52003/console` to log in, or `/register` to create an account when `PAGES_ALLOW_REGISTRATION=true`. For plain HTTP on local loopback, set `PAGES_REFRESH_COOKIE_SECURE=false` so the browser can retain the refresh cookie; keep it true under HTTPS. The built console is served by the same FastAPI origin and calls the existing `/v1` endpoints. For frontend development, `npm run dev:web` serves Vite on port 52004 and proxies `/v1` to the API on port 52003.

The console reuses the Baizhi Pages Tiptap block editor. Team Pages and Apps use the selected Vessel space and current role capabilities. The inherited Baizhi Page Agent UI is not included; Page image upload controls are disabled in this increment, while existing images can still be displayed. Unsaved Page drafts stay in browser memory and are lost on reload; save them before closing the tab. Team invitations require the invitee's existing Vessel user ID. The console leaves file management to the API.

The imported configuration still uses the `PAGES_*` prefix. Vessel user sessions use the `vessel-api` audience, `vessel:session` scope and `vessel_refresh` cookie. The old `baizhi-pages-mcp` capability and Agent Platform routes are test-only compatibility code and are not registered by the normal application. See `docs/source-import.md` for the import boundary.

The current identity increment invites existing active Vessel users by `user_id`. Self-registration defaults to disabled and email verification/reset are not implemented; do not enable public registration for production accounts. In a local isolated database, enable registration to exercise the team API. The team endpoints are `GET /v1/spaces`, `GET /v1/spaces/{id}/permissions`, `POST /v1/teams`, `GET /v1/teams/{id}`, `GET /v1/teams/{id}/members`, `GET/POST /v1/teams/{id}/invitations`, `DELETE /v1/teams/{id}/invitations/{invitation_id}`, `GET /v1/team-invitations`, `POST /v1/team-invitations/{id}/accept`, and `PATCH/DELETE /v1/teams/{id}/members/{user_id}`.

With the database migrated and `PAGES_DATABASE_URL` set, a server operator can create the first administrator with `cd apps/api && PYTHONPATH=src .venv/bin/python -m vessel_service.bootstrap_admin`. To provision a regular teammate while public registration is disabled, add `--role user`. The command prompts for the password without echoing it and creates the account with a personal space.

For a local isolated PostgreSQL E2E run, execute `bash scripts/dev/start-e2e-postgres.sh`, export the printed `PAGES_DATABASE_URL`, start the API with `PAGES_ALLOW_REGISTRATION=true bash scripts/dev/start-api.sh`, then run `apps/api/.venv/bin/python scripts/dev/team_http_e2e.py http://127.0.0.1:52003`. Stop the API and PostgreSQL using the command printed by the database script.

With registration left disabled, `PAGES_DATABASE_URL=... apps/api/.venv/bin/python scripts/dev/local_user_http_e2e.py http://127.0.0.1:52003` verifies controlled local provisioning and login against the same isolated setup.
