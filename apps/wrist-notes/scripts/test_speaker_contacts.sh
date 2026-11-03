#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-contacts.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Tests/SpeakerContactsSmoke.swift -o "$output/contacts"
"$output/contacts"
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/SpeakerTranscript.swift Tests/SpeakerDiarizationSmoke.swift -o "$output/speakers"
"$output/speakers"
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Tests/VoiceOwnerSmoke.swift -o "$output/owner"
"$output/owner"
