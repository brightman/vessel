# Karama.Cloud and Notes Renaming Implementation Plan

> **For agentic workers:** Implement in this session, in order, keeping unrelated worktree changes intact.

**Goal:** Replace the Page product and Memory on Cloud brand throughout current Vessel code and product descriptions.

**Architecture:** Rename the public contract and internal Note model together. Add a forward Alembic migration to rename persisted PostgreSQL objects without discarding rows. Preserve old migration scripts only as migration history.

**Tech Stack:** FastAPI, SQLAlchemy, Alembic, React, TypeScript, argparse.

## Global constraints

- Public brand: `Karama.Cloud`; document product: `Note` and `Notes`.
- HTTP: `/v1/notes`, `/v1/spaces/{space_id}/notes`, `note_id`, `note` and `notes` JSON keys.
- CLI: `vessel notes`; runtime configuration prefix: `NOTES_`.
- No compatibility aliases; retain persisted data through rename migration.
- Do not edit ignored credentials or unrelated worktree files.

## Tasks

### Task 1: PostgreSQL and backend contract

1. Add migration `0012_notes_rename` after `0011_registration_email` using `op.rename_table`, `op.alter_column(..., new_column_name=...)`, and `op.execute('ALTER ... RENAME CONSTRAINT ...')` where required. Rename indexes as needed. Test upgrade on isolated PostgreSQL.
2. Rename Note models and dependent imports in `apps/api/src/vessel_service/models/`, `pages/`, `versions/`, `directories/`, `assets/`, `spaces/`, `proposals/`, `mcp/`, `main.py`, `settings.py` and other backend code where Page denotes the document resource. Rename `pages/` to `notes/`, `models/page*.py` to `models/note*.py`.
3. Update current API tests and inspect `/openapi.json` for new routes and response keys.

### Task 2: Frontend and CLI

1. Rename the console component `Pages.tsx` to `Notes.tsx`, adapt its API wrapper and all product-facing labels. Preserve pagination terms in Apps and browser test variables.
2. Rename the CLI `pages` parser group to `notes`, update URLs and examples, and update its focused command tests.
3. Update website and console brand to Karama.Cloud, Note product copy, HTML metadata, and registration email copy.

### Task 3: Documentation and local verification

1. Update README and current product/API documentation to Karama.Cloud and Notes. Keep historical implementation plans and old migration scripts as records of what ran.
2. Rebuild marketing and console bundles. Run focused backend and CLI checks, upgrade the local isolated PostgreSQL, restart local service with `NOTES_DATABASE_URL`, then inspect health, Note routes, and pages.
