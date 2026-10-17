#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PAGES_DATABASE_URL:-}" ]]; then
  echo "Set PAGES_DATABASE_URL to the isolated Vessel development database before starting the API." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
brevo_config="${PAGES_BREVO_CONFIG_FILE-$repo_root/apps/api/.env.brevo}"
env_args=()
if [[ -n "$brevo_config" && -f "$brevo_config" ]]; then
  env_args=(--env-file "$brevo_config")
elif [[ -n "${PAGES_BREVO_CONFIG_FILE:-}" ]]; then
  echo "PAGES_BREVO_CONFIG_FILE does not exist." >&2
  exit 2
fi

api_host="${PAGES_HOST:-127.0.0.1}"
api_port="${PAGES_PORT:-52003}"
cd "$repo_root/apps/api"
export PYTHONPATH="$PWD/src${PYTHONPATH:+:$PYTHONPATH}"
uv run "${env_args[@]}" --project . alembic upgrade head
exec uv run "${env_args[@]}" --project . uvicorn vessel_service.main:app --host "$api_host" --port "$api_port"
