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

swiftc -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/AISettingsModel.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/PhoneWatchStatus.swift Tests/AISettingsSmoke.swift -o "$output/settings"
"$output/settings"

swiftc -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionSettingsModel.swift Tests/TranscriptionSettingsSmoke.swift -o "$output/transcription"
"$output/transcription"

swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppleSpeechReservationCoordinator.swift Tests/AppleSpeechReservationsSmoke.swift -o "$output/reservations"
"$output/reservations"

swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/WhisperModelStore.swift Tests/WhisperModelStoreSmoke.swift -o "$output/whisper-store"
"$output/whisper-store"

swiftc -module-cache-path "$output/cache" Sources/iPhone/PhotoMoment.swift Sources/iPhone/PhotoRepository.swift Tests/PhotoRepositorySmoke.swift -o "$output/photos"
"$output/photos"

swiftc -module-cache-path "$output/cache" Sources/iPhone/DaybookReminderPersistence.swift Sources/iPhone/DaybookPreferences.swift Tests/DaybookReminderSmoke.swift -o "$output/reminders"
"$output/reminders"

swiftc -D DAYBOOK_ASSISTANT_MODEL_TESTS -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookAssistantModel.swift Sources/iPhone/DaybookAnswerService.swift Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionConfiguration.swift Tests/DaybookRetrievalSmoke.swift -o "$output/daybook-ai"
"$output/daybook-ai"

swiftc -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookSuggestionStore.swift Tests/DaybookSuggestionSmoke.swift -o "$output/suggestions"
"$output/suggestions"
