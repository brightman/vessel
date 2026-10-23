#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/api-env.sh"

api_host="${NOTES_HOST:-127.0.0.1}"
api_port="${NOTES_PORT:-52003}"
cd "$repo_root/apps/api"
export PYTHONPATH="$PWD/src${PYTHONPATH:+:$PYTHONPATH}"
require_api_database_url
uv run "${api_env_args[@]}" --project . alembic upgrade head
exec uv run "${api_env_args[@]}" --project . uvicorn vessel_service.main:app --host "$api_host" --port "$api_port"
