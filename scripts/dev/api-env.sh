#!/usr/bin/env bash

# Shared local API and Files worker configuration. Environment variables can
# override entries in the dotenv file for isolated development runs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
api_config_file="${NOTES_CONFIG_FILE-$repo_root/apps/api/.env}"
api_env_args=()
if [[ -n "$api_config_file" && -f "$api_config_file" ]]; then
  api_env_args=(--env-file "$api_config_file")
elif [[ -n "${NOTES_CONFIG_FILE:-}" ]]; then
  echo "NOTES_CONFIG_FILE does not exist." >&2
  exit 2
fi

require_api_database_url() {
  if ! uv run "${api_env_args[@]}" --project . python -c \
    'import os, sys; sys.exit(0 if os.environ.get("NOTES_DATABASE_URL") else 2)'; then
    echo "Set NOTES_DATABASE_URL in apps/api/.env or the process environment." >&2
    exit 2
  fi
}
