#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/api-env.sh"
cd "$repo_root/apps/api"
export PYTHONPATH="$PWD/src${PYTHONPATH:+:$PYTHONPATH}"
require_api_database_url
exec uv run "${api_env_args[@]}" --project . python -m vessel_service.files.worker "$@"
