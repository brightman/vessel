#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PAGES_DATABASE_URL:-}" ]]; then
  echo "Set PAGES_DATABASE_URL to the isolated Pages development database before starting the API." >&2
  exit 2
fi

api_host="${PAGES_HOST:-127.0.0.1}"
api_port="${PAGES_PORT:-52003}"
cd apps/api
export PYTHONPATH="$PWD/src${PYTHONPATH:+:$PYTHONPATH}"
uv run --project . alembic upgrade head
exec uv run --project . uvicorn pages_service.main:app --host "$api_host" --port "$api_port"
