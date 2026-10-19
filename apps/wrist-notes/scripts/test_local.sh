#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wristnotes-checks.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/iPhone/NoteRepository.swift Tests/NoteRepositorySmoke.swift -o "$output/store"
"$output/store"
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Watch/WatchConnectivityStatus.swift Tests/WatchConnectivityStatusSmoke.swift -o "$output/connectivity"
"$output/connectivity"
swiftc -module-cache-path "$output/cache" Sources/Watch/RecordingButtonInteraction.swift Tests/RecordingButtonInteractionSmoke.swift -o "$output/gesture"
"$output/gesture"
ruby Tests/ProjectSourceMembershipSmoke.rb
ruby Tests/DebugIdleTimerSmoke.rb
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Tests/NoteEditingSmoke.swift -o "$output/editing"
"$output/editing"

swiftc -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/AISettingsModel.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/PhoneWatchStatus.swift Tests/AISettingsSmoke.swift -o "$output/settings"
"$output/settings"
