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

- `apps/web/`, browser prototype, Node packages, browser tests and Playwright scripts, because Vessel is API-only.
- `apps/api/.venv/`, `.pytest_cache/`, `__pycache__/`, `*.pyc`, `apps/api/var/`, source `.env`, local object data and generated output.

Before package renaming, a checksum-mode `rsync -anc` comparison of the bounded `apps/api/` source and destination produced no differences. The copied launch script had the same SHA-256 (`ab5875cd762af56464be63baceed4df3c7460879e38a13d7168bf0ff7f5bd200`). Running the imported API suite in Vessel with the source virtualenv as a read-only interpreter gave `82 passed in 5.24s`. Vessel will install its own dependencies before the final verification.

The imported code is a Pages baseline, not the complete Vessel product. The Python package and API title were renamed to `vessel_service` / `Vessel API` after the preserved import commit `fd50e23`. It still uses personal Page ownership, private image assets, `PAGES_*` configuration, Pages token audiences and optional Baizhi Agent Platform integration. Team spaces, general OSS/S3 files and tables are separate implementation increments governed by `docs/technical-design.md` and `docs/db-schema.md`.

Migration verification: `uv lock --offline`, `uv sync --offline`, and `.venv/bin/python -m pytest tests -q -p no:cacheprovider` reported `82 passed`. A real Uvicorn process with an isolated local PostgreSQL database applied migrations `0001`–`0006`; HTTP checks returned health 200, readiness 200, registration 201, login 200, Page create 201, owner read 200, and other-account read 404. The API and test database processes were stopped afterward.
