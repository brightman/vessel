# Baizhi Pages API source import

Date: 2026-10-14

Source checkout: `/Users/karama/Documents/baizhi/baizhi-pages`
Source Git HEAD: `3ee791d docs: specify Pages selection toolbar behavior`
Destination: this independent Vessel Git repository

The source checkout had modified tracked files and untracked files. In particular, the full-stack `apps/api` tree was untracked there. This import therefore uses the current source filesystem state rather than `git archive HEAD`. It does not edit, clean, or commit the source checkout.

Imported:

- `apps/api/`: API package, Alembic migrations, 14 API test modules, `pyproject.toml`, `uv.lock`, `alembic.ini`, and non-secret `.env.example`.
- `scripts/dev/start-api.sh` and `scripts/dev/pages_e2e_helpers.py`. The helper is required by the imported API test suite.

Excluded:

- `apps/web/`, browser prototype, Node packages, browser tests and Playwright scripts were excluded from this 2026-10-14 API source import. Vessel later added its own Web console and browser tests; see the 2026-10-15 editor import below.
- `apps/api/.venv/`, `.pytest_cache/`, `__pycache__/`, `*.pyc`, `apps/api/var/`, source `.env`, local object data and generated output.

Before package renaming, a checksum-mode `rsync -anc` comparison of the bounded `apps/api/` source and destination produced no differences. The copied launch script had the same SHA-256 (`ab5875cd762af56464be63baceed4df3c7460879e38a13d7168bf0ff7f5bd200`). Running the imported API suite in Vessel with the source virtualenv as a read-only interpreter gave `82 passed in 5.24s`. Vessel will install its own dependencies before the final verification.

The imported code is a Pages baseline, not the complete Vessel product. The Python package and API title were renamed to `vessel_service` / `Vessel API` after the preserved import commit `fd50e23`. It still uses personal Page ownership, private image assets, `PAGES_*` configuration, Pages token audiences and optional Baizhi Agent Platform integration. Team spaces, general OSS/S3 files and tables are separate implementation increments governed by `docs/technical-design.md` and `docs/db-schema.md`.

Migration verification: `uv lock --offline`, `uv sync --offline`, and `.venv/bin/python -m pytest tests -q -p no:cacheprovider` reported `82 passed`. A real Uvicorn process with an isolated local PostgreSQL database applied migrations `0001`–`0006`; HTTP checks returned health 200, readiness 200, registration 201, login 200, Page create 201, owner read 200, and other-account read 404. The API and test database processes were stopped afterward.

The later identity and team increment adds migration `0007`, changes user session audience to `vessel-api`, and changes its cookie to `vessel_refresh`. The Page MCP capability retains its separate historical audience. See `docs/db-schema.md` for current tables and limits.

The Pages/Apps integration adds migration `0008` for space-owned Pages/directories and Vessel App records. The normal Vessel application no longer registers the imported Agent Platform, proposal, or MCP routes. Their imported tests can enable those routes only through an explicit test-environment factory argument; a separate Vessel Page Agent will be configured later. Baizhi Apps Manifest identifier/type rules and value normalization were adapted into `vessel_service.apps.manifest`; its runtime policy, row ACL, Agent, and H5 modules were not imported. Source checkouts remain read-only.

## Web console editor import (2026-10-15)

After Vessel gained a Web console requirement, the editor source was copied from the same Baizhi Pages checkout into `apps/web/src/editor.tsx` and `apps/web/src/editor/`. The copied modules are the Tiptap editor, block/section controls, slash menu, image rendering block, table controls, and supporting editor styles. The current source filesystem state was used because `apps/web/` and the prototype modules remain untracked in that checkout. The Baizhi Pages source tree was not edited or cleaned.

Vessel's `apps/web/src/App.tsx`, `Teams.tsx`, `Pages.tsx`, `Apps.tsx`, and `api.ts` are new Vessel code. They call Vessel account, team, space, Page, and App APIs. The legacy Baizhi Pages Agent and proposal UI was not imported. Page image upload is disabled in this console; existing images can be rendered through the existing Page asset read API.
