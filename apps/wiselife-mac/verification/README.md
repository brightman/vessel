# Desktop verification — 2026-10-24

## 0.2.0: light-gray iPhone styling and model recommendations

- Reused the iPhone light NotesStyle / DaybookStyle tokens: gray `#f5f5f7`, white grouped cards, blue-gray `#335f83` primary actions, 18pt card radius.
- Read actual Apple M4 / 16 GB hardware. Conservative catalog policy selects 1.7B for 8–12 GB and 4B for 16 GB+, excludes unknown models and unsupported configurations. This is a heuristic, not measured model RAM consumption or M3 acceptance.
- Model card's download button now starts Hugging Face download directly. Source, license, download size and memory guidance are visible in the card; fixed revision is in expandable details.
- Added byte counts, rate, explicit verification stage, cancellation/retry and an installed-only completion notice. Background progress reports are throttled, and stale progress is ignored.
- `WISELIFE_HF_DOWNLOAD_SMOKE=1 sh scripts/test.sh`: **23 tests, 0 failures**, including actual HTTPS model-card + 11 MB LFS tokenizer download from Hugging Face/CDN, verified against pinned SHA-256. No language-model weights were downloaded by this test.
- Actual sandboxed 0.2.0 App: clicked the 1.7B model’s download button once; the inline progress changed from connecting to real Hugging Face bytes (72 KB observed). Cancel returned immediately to a cancellation notice and a retry button. No complete language-model weights were downloaded or loaded. The staging directory was cleaned.
- Preview QA: `overview-gray.png`, `models-gray.png`, and `model-downloading.png`. The downloading screenshot uses an isolated debug fixture; it is not evidence of a real weight download. No injected fixture state is enabled in Release.
- Packaging now stages a clean signed bundle and replaces the previous App instead of merging Debug and Release contents; this fixes leftover debug-dylib resource-seal failures.
- Pairing Keychain access is now lazy and runs off the main actor. With service paused, starting the app and downloading a model do not require pairing-credential authorization. Device status distinguishes unread credentials from an empty registry.
- Final startup was rechecked after the lazy-Keychain change: the Release window opened immediately, reported actual M4 / 16 GB hardware, and navigated to the recommended model library without requiring pairing authorization. Offline regression: 23 executed, 1 opt-in network check skipped, 0 failures; the actual Hub/CDN check had passed separately above.
- Final 0.2.0 arm64 Release build and zip completed; bundle version and strict deep ad-hoc signature verification passed. Release entitlements retain only App Sandbox plus client/server network permissions.

## Original 0.1.0 verification — 2026-10-23

Environment: MacBook Pro / Apple M4 / 16 GB, macOS 15.7.4 (24G517), Xcode 26.3 (17C529), Swift 6.2.4. This is **not** the design's named M3 Air acceptance machine.

## Automated verification

`sh scripts/test.sh` runs deterministic, weight-free XCTest cases. Inference uses a cancellable stub; transport tests use a real NIO/NIOSSL listener on loopback, URLSession certificate pinning, generated in-memory identities and an isolated credential store. No user's iPhone, Keychain, notes or model weights are used.

Result: **19 tests passed, 0 failures**. `sh scripts/build.sh` completed an arm64 Release App and zip, with model catalog and MLX `default.metallib` verified inside the bundle. `codesign --verify --deep --strict` passed with the local ad-hoc signature. This does not mean Developer ID / notarization passed.

Final Release entitlements contain only App Sandbox and network client/server permissions; automatic `get-task-allow` debug access injection is disabled. The development host's missing Metal Toolchain was installed through Xcode's official component downloader before the successful build.

`sh scripts/benchmark.sh --check-metal` compiled the Xcode command-line target and successfully evaluated **1 + 2 + 3 = 6** with MLX Metal on this M4. This verifies the GPU integration without downloading or loading language-model weights.

Coverage:

- Strict text-only request schema, system/user messages, unknown settings, stream rejection, output clamp and 1 MiB bound.
- Immutable catalog revisions, SHA-256 hashes, local file tampering, successful atomic install, failed install cleanup and revalidation before load.
- Expiring single-use QR secret, rate limit, replay, wrong bearer, credential rotation, restart persistence, verifier storage and revocation.
- Stable self-signed certificate identity and certificate DER fingerprint.
- Single active inference, bounded FIFO, queue-full, caller cancellation, timeout, revoked-client admission, idle unload and shutdown drain.
- Pause during pairing cancels generation while retaining the pairing flow.
- Real HTTPS pair → models → completion → revoke; paused/model-not-ready responses, wrong TLS pin, cleartext rejection and oversized request.
- Rejection of wildcard/public listener addresses.
- Concurrent service stops and subsequent listener restart.

Plist/entitlements were linted with `plutil`; shell scripts were checked with `sh -n`; maintainer Python scripts compile. App sources contain no request/response logger or cloud inference endpoint.

The actual sandboxed Release App was launched and inspected through accessibility: first launch reached paused service / unloaded model state without an error; model-library navigation and the download disclosure showed the pinned revision, license and size. Cancelling returned to the not-downloaded state. The App then quit normally. This launch created the app's own local Keychain identity and empty device registry; no pairing or network availability was enabled.

## Visual verification

Debug-only isolated preview renders the actual SwiftUI window, not an HTML mockup. Preview creates no identity, network listener or downloads. PNGs:

- `overview.png`: empty model / first device / paused state.
- `models.png`: pinned 4B and 1.7B model cards, storage, load/download controls and engineering qualification.
- `devices.png`: first pairing instructions, availability and connection help.
- `privacy.png`: text data flow, credential handling and release limitations.

## Required release acceptance still outstanding

1. On the exact M3 Air / 16 GB, explicitly download both pinned candidates and run the synthetic Chinese benchmark and 30-minute soak **one at a time**. Inspect generated summaries/titles/citations/JSON/content decisions; establish numerical latency/memory gates from observations. No real model quality, speed, sustained memory pressure or thermal passing result is claimed here.
2. Integrate iPhone Nearby Mac provider, discovery, QR parsing, certificate pinning, Keychain and shared authorized routing for all text tasks. Preserve source validation, citations, cancellation and stale-result guards. Existing desktop sync QR is a different protocol.
3. With real iPhone + M3 Air, verify Local Network denial, firewall, sleep/wake, Wi-Fi change, hotspots/client isolation, revocation and no cloud fallback. Loopback TLS tests do not prove LAN Bonjour behavior.
4. Audit bundled notices and model licenses at release; configure Developer ID signing and notarization. Local ad-hoc build is not a distributable notarized release.

See the app README for exact commands. Benchmark output is explicitly marked `UNREVIEWED`, includes model pins and system data, and cannot automatically qualify hardware.
