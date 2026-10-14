# Pages API Base Migration Implementation Plan

> Execute this plan inline in the Vessel repository. Preserve the Pages source checkout. Do not delegate work.

**Goal:** Import the current Baizhi Pages API into Vessel as a runnable, independently versioned API foundation, without its Web UI or local secrets.

**Architecture:** Copy the current API, migrations, tests and API launch script into Vessel. Keep domain behavior intact for the first import, then rename the Python package to Vessel. Document inherited limits: personal ownership, page-only assets and Baizhi Agent Platform integration.

**Tech Stack:** Python 3.11+, FastAPI, SQLAlchemy, Alembic, PostgreSQL, uv, pytest.

## Constraints

- Source: `/Users/karama/Documents/baizhi/baizhi-pages`, Git HEAD `3ee791d`, with important untracked API files.
- Destination: independent Git repository `/Users/karama/Documents/Vessel`.
- Import from current disk state. Exclude virtualenv, caches, generated files, secrets, Web UI and browser prototype.
- Preserve source checkout without editing, cleaning or committing it.
- API test gate: 82 collected cases, below the 100-case cap. Run one real HTTP E2E after tests.
- This migration establishes a runnable base; it does not claim team, table or OSS/S3 features are implemented.

## Task 1: Import the bounded API snapshot

**Files:** `apps/api/pyproject.toml`, `apps/api/uv.lock`, `apps/api/alembic.ini`, `apps/api/src/pages_service/**`, `apps/api/migrations/**`, `apps/api/tests/**`, `scripts/dev/start-api.sh`, `scripts/dev/pages_e2e_helpers.py`, `docs/source-import.md`.

- [x] Copy only the listed source paths, filtering virtualenv/cache/build output.
- [x] Record source commit, dirty-state fact, included paths and excluded paths.
- [x] Compare source and destination file hashes before any rename.
- [x] Verify no credential or generated file entered the destination.

## Task 2: Rebrand the imported API package

**Files:** move `apps/api/src/pages_service/` to `apps/api/src/vessel_service/`; update Python imports, tests, Alembic env, package metadata, lock file, launch script and README.

**Interface:** expose `vessel_service.main:create_app` and `vessel_service.main:app` while retaining existing Pages API routes.

- [x] Rename import/package references from `pages_service` to `vessel_service`.
- [x] Rename Python distribution to `vessel-api`; update the lock file offline.
- [x] Change FastAPI title and launch script module path to Vessel.
- [x] Keep existing `PAGES_*` environment variables and token audiences temporarily, documenting this compatibility boundary rather than silently changing authentication.
- [x] Compile through test collection and execution.

## Task 3: Verify and commit

**Files:** `apps/api/tests/**`, `README.md`, `docs/source-import.md`.

- [x] Run the 82 related API tests without widening to unrelated browser suites.
- [x] Start a real local Vessel API process with an isolated PostgreSQL database; request `/healthz`, `/readyz`, register/login and create/read a Page through HTTP.
- [x] Check `git diff --check`, test count, file inventory and source checkout status.
- [x] Commit only in Vessel, then report which Vessel product features remain unimplemented.
