#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-actions.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -D ACTION_CORE_TESTS -module-cache-path "$output/cache" Sources/iPhone/DaybookDatabase.swift Sources/iPhone/ActionItem.swift Sources/iPhone/ActionProposal.swift Tests/ActionSmoke.swift -o "$output/actions"
"$output/actions"
