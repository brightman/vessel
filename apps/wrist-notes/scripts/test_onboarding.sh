#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-onboarding.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/OnboardingProgress.swift Sources/iPhone/OnboardingStore.swift Tests/OnboardingSmoke.swift -o "$output/onboarding"
"$output/onboarding"
