#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import re

source = Path("Sources/iPhone/ContentEnrichmentService.swift").read_text()
start = source.index("struct FoundationContentTextModel")
end = source.index("\n#endif", start)
model = source[start:end]

expected = r"SystemLanguageModel\s*\(\s*guardrails\s*:\s*\.permissiveContentTransformations\s*\)"
assert len(re.findall(expected, model)) == 2, "both Foundation text-transformation paths must use permissive content guardrails"
assert "SystemLanguageModel.default" not in model, "voice-note transformations must not use default input guardrails"
print("Foundation content guardrails: PASS")
PY
