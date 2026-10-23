#!/usr/bin/env bash
set -euo pipefail

pg_bin_dir="$(pg_config --bindir)"
for tool in initdb pg_ctl createdb pg_isready; do
  if [[ ! -x "$pg_bin_dir/$tool" ]]; then
    printf 'PostgreSQL tool is unavailable: %s\n' "$tool" >&2
    exit 2
  fi
done

e2e_root="$(mktemp -d /private/tmp/vessel-e2e-pg.XXXXXX)"
pg_data_dir="$e2e_root/data"
pg_ctl="$pg_bin_dir/pg_ctl"
started=0
cleanup_failed_start() {
  local status=$?
  if (( status != 0 && started == 1 )); then
    "$pg_ctl" -D "$pg_data_dir" stop -m fast >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_failed_start EXIT

port="$(python3 - <<'PY'
import socket

for _ in range(128):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    if port >= 50000:
        print(port)
        break
else:
    raise SystemExit("Could not select an unused high loopback port.")
PY
)"

"$pg_bin_dir/initdb" -D "$pg_data_dir" --username=vessel --auth-local=trust --auth-host=trust --no-instructions >"$e2e_root/initdb.log"
"$pg_ctl" -D "$pg_data_dir" -l "$e2e_root/postgres.log" \
  -o "-p $port -h 127.0.0.1 -c listen_addresses=127.0.0.1 -c shared_memory_type=mmap -c dynamic_shared_memory_type=mmap" \
  -w -t 30 start
started=1
"$pg_bin_dir/createdb" -h 127.0.0.1 -p "$port" -U vessel vessel_e2e
"$pg_bin_dir/pg_isready" -h 127.0.0.1 -p "$port"

printf 'NOTES_DATABASE_URL=postgresql+psycopg://vessel@127.0.0.1:%s/vessel_e2e\n' "$port"
printf 'Stop after testing: %s -D %s stop -m fast\n' "$pg_ctl" "$pg_data_dir"
trap - EXIT
