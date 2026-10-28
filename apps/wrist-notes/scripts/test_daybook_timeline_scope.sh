#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path

source = Path("Sources/iPhone/DaybookView.swift").read_text()
start = source.index("    private var sessionMaintenance: some View {")
end = source.index("    private var recapLibraryEntries:", start)
maintenance = source[start:end]

assert "ForEach(content.library" not in maintenance, (
    "the maintenance footer must not render globally paged library segments as timeline rows"
)
assert "ForEach(sessions.sessions.filter { $0.startedAt == nil })" in maintenance, (
    "recording sessions waiting for a start timestamp should remain actionable"
)
assert "if content.hasMore" in maintenance and "if sessions.hasMore" in maintenance, (
    "library and session pagination controls should remain available"
)
print("Daybook timeline scope: PASS")
PY
