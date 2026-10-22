#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_output=$(mktemp -d /private/tmp/wiselife-apple-reminders.XXXXXX)
trap 'rm -rf "$test_output"' EXIT
swiftc -module-cache-path "$test_output/cache" Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookReminderPersistence.swift Tests/AppleRemindersSmoke.swift -o "$test_output/apple-reminders"
"$test_output/apple-reminders"
swiftc -module-cache-path "$test_output/cache" Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookReminderPersistence.swift Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Tests/DaybookReminderSmoke.swift -o "$test_output/local-reminders"
"$test_output/local-reminders"
