#!/bin/sh
set -eu
chatgpt_sources="Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift"
cd "$(dirname "$0")/.."
sh scripts/test_phone_recording.sh
sh scripts/test_watch_sync.sh
sh scripts/test_watch_recording_launcher.sh
sh scripts/test_audio_duration.sh
sh scripts/test_recording_sessions.sh
sh scripts/test_recording_titles.sh
sh scripts/test_recording_title_coordinator.sh
output=$(mktemp -d /private/tmp/wristnotes-checks.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Tests/NoteRepositorySmoke.swift -o "$output/store"
"$output/store"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Watch/WatchConnectivityStatus.swift Tests/WatchConnectivityStatusSmoke.swift -o "$output/connectivity"
"$output/connectivity"
swiftc -module-cache-path "$output/cache" Sources/Watch/RecordingButtonInteraction.swift Tests/RecordingButtonInteractionSmoke.swift -o "$output/gesture"
"$output/gesture"
ruby Tests/ProjectSourceMembershipSmoke.rb
ruby Tests/WatchRecordingWidgetProjectSmoke.rb
ruby Tests/DebugIdleTimerSmoke.rb
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Tests/NoteEditingSmoke.swift -o "$output/editing"
"$output/editing"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/SpeakerTranscript.swift Tests/SpeakerDiarizationSmoke.swift -o "$output/speakers"
"$output/speakers"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Tests/VoiceOwnerSmoke.swift -o "$output/voice-owner"
"$output/voice-owner"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/iPhone/SpeakerTranscript.swift Sources/iPhone/VoiceSpeechSelection.swift Tests/VoiceSpeechWindowsSmoke.swift -o "$output/voice-windows"
"$output/voice-windows"
swiftc -module-cache-path "$output/cache" Sources/iPhone/VoiceIdentity.swift Tests/VoiceIdentitySmoke.swift -o "$output/voice-profile"
"$output/voice-profile"
sh scripts/test_voice_profile_recovery.sh

swiftc $chatgpt_sources -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/AISettingsModel.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/PhoneWatchStatus.swift Tests/AISettingsSmoke.swift -o "$output/settings"
"$output/settings"

swiftc $chatgpt_sources -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionSettingsModel.swift Tests/TranscriptionSettingsSmoke.swift -o "$output/transcription"
"$output/transcription"

swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppleSpeechReservationCoordinator.swift Tests/AppleSpeechReservationsSmoke.swift -o "$output/reservations"
"$output/reservations"

swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/WhisperModelStore.swift Tests/WhisperModelStoreSmoke.swift -o "$output/whisper-store"
"$output/whisper-store"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/PhotoMoment.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/PhotoRepository.swift Tests/PhotoRepositorySmoke.swift -o "$output/photos"
"$output/photos"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookReminderPersistence.swift Sources/iPhone/DaybookPreferences.swift Tests/DaybookReminderSmoke.swift -o "$output/reminders"
"$output/reminders"

swiftc Sources/Shared/CaptureMetadata.swift $chatgpt_sources -D DAYBOOK_ASSISTANT_MODEL_TESTS -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookAssistantModel.swift Sources/iPhone/DaybookAnswerService.swift Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionConfiguration.swift Tests/DaybookRetrievalSmoke.swift -o "$output/daybook-ai"
"$output/daybook-ai"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookSuggestionStore.swift Tests/DaybookSuggestionSmoke.swift -o "$output/suggestions"
"$output/suggestions"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Tests/LifeSourceSmoke.swift -o "$output/life-sources"
"$output/life-sources"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/LifeSourceModel.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Tests/LifeSourceModelSmoke.swift -o "$output/life-source-model"
"$output/life-source-model"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Sources/iPhone/DaybookInsightService.swift Sources/iPhone/DaybookInsightModel.swift Tests/DaybookInsightSmoke.swift -o "$output/insights"
"$output/insights"

swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Tests/SQLitePersistenceSmoke.swift -o "$output/sqlite"
"$output/sqlite"

sh scripts/test_metadata_sqlite.sh
# Includes full-text SQL, complete chunk persistence, and foreground continuation smoke tests.
sh scripts/test_semantic.sh

sh scripts/test_places.sh
sh scripts/test_health.sh
sh scripts/test_addresses.sh
