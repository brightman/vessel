#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: prepare_translation_resources.sh OUTPUT_DIRECTORY}
mkdir -p "$output"
output=$(cd "$output" && pwd)
app="$output/WiseLife Translation Experiment.app"
mkdir -p "$app/Contents/MacOS"
xcrun --sdk macosx swiftc -parse-as-library -target arm64-apple-macos26.0 \
    Tests/AppleTranslationResourceHelper.swift -o "$app/Contents/MacOS/TranslationResources"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'cloud.karama.wiselife.translation-experiment',
                  'CFBundleName':'WiseLife Translation Experiment',
                  'CFBundleExecutable':'TranslationResources','CFBundlePackageType':'APPL',
                  'CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
                  'LSMinimumSystemVersion':'26.0','NSPrincipalClass':'NSApplication'}, f)
PY
codesign --force --sign - "$app"
open "$app"
