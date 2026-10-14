# Vessel

Vessel is an API-only storage service for people using coding agents. It will provide personal and team spaces for files, structured tables, and block-based Pages. File bytes will live in private OSS/S3 storage; Vessel owns its accounts, metadata, authorization, and APIs.

The API foundation is imported from Baizhi Pages. It currently supports independent local accounts, personal Pages, page versions, private Page image assets, and a private Page MCP endpoint. Team spaces, shared resources, general OSS/S3 files, and tables are being built in separate increments. See the [technical design](docs/technical-design.md), [database schema](docs/db-schema.md), and [import record](docs/source-import.md).

## Run the API

Install the locked Python dependencies from `apps/api` with `uv sync`. Create a dedicated PostgreSQL database, then from the repository root set `PAGES_DATABASE_URL` to that database and run `bash scripts/dev/start-api.sh`. The script applies Alembic migrations and starts Uvicorn. Set `PAGES_ALLOW_REGISTRATION=true` only in an isolated development environment when self-registration is needed. Health endpoints are `/healthz` and `/readyz`; the OpenAPI document is `/openapi.json`.

The imported configuration still uses the `PAGES_*` prefix and existing Pages token audiences during the base migration. These compatibility details are documented in `docs/source-import.md`; the Vessel identity increment will replace the token audience before a production release.
