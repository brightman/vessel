#!/bin/sh
set -eu
COMPANION_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$COMPANION_ROOT"
swift test --disable-automatic-resolution --jobs 6
