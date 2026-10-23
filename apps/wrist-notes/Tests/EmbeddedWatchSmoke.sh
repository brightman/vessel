#!/bin/sh
set -eu

app="$1"
watch="$app/Watch/WristNotesWatch.app"
if [ ! -d "$watch" ]; then
  echo "Expected embedded Watch app at $watch" >&2
  exit 1
fi
if [ -d "$app/PlugIns/WristNotesWatch.app" ]; then
  echo "Watch app was packaged as a plugin" >&2
  exit 1
fi
python3 - "$app" "$watch" <<'PY'
import pathlib
import plistlib
import sys

def info(path):
    with (path / "Info.plist").open("rb") as file:
        return plistlib.load(file)

phone, watch = map(pathlib.Path, sys.argv[1:])
phone_info, watch_info = info(phone), info(watch)
assert watch_info["WKApplication"] is True, "Watch app marker is missing"
assert watch_info["WKCompanionAppBundleIdentifier"] == phone_info["CFBundleIdentifier"], "Watch companion ID does not match iPhone app"
assert watch_info["CFBundleIdentifier"].startswith(phone_info["CFBundleIdentifier"] + "."), "Watch bundle ID must be scoped to iPhone app"
for key in ("CFBundleVersion", "CFBundleShortVersionString"):
    assert watch_info[key] == phone_info[key], f"iPhone/Watch mismatch: {key}"
for parent in (phone, watch):
    parent_info = info(parent)
    for extension in (parent / "PlugIns").glob("*.appex"):
        extension_info = info(extension)
        assert extension_info["CFBundleIdentifier"].startswith(parent_info["CFBundleIdentifier"] + "."), f"Extension bundle ID does not match parent: {extension.name}"
        for key in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleSupportedPlatforms"):
            assert extension_info[key] == parent_info[key], f"Extension mismatch: {extension.name} {key}"
print("Embedded Watch location, companion ID and app/extension versions passed (signing not checked)")
PY
