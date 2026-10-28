#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
release_test_dir=$(mktemp -d /private/tmp/wiselife-release.XXXXXX)
trap 'rm -rf "$release_test_dir"' EXIT
mkdir -p "$release_test_dir/Test.bundle"
cat > "$release_test_dir/Test.bundle/Info.plist" <<'PLIST'
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.release</string><key>CFBundleShortVersionString</key><string>1.2.3</string><key>CFBundleVersion</key><string>42</string></dict></plist>
PLIST
SCRIPT_OUTPUT_FILE_0="$release_test_dir/Test.bundle/BuildMetadata.plist" sh scripts/write_build_metadata.sh
swiftc -module-cache-path "$release_test_dir/module-cache" Sources/iPhone/AppReleaseInfo.swift Tests/AppReleaseInfoSmoke.swift -o "$release_test_dir/check"
"$release_test_dir/check" "$release_test_dir/Test.bundle"
