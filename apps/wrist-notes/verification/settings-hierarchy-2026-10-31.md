# Settings hierarchy alignment — 2026-10-31

## Scope

User approved the settings prototype before native implementation. The active Daybook settings screen now uses the six approved groups: 通用设置, 语言与AI, 硬件, 数据来源, 隐私与安全, 关于.

Shared menu components specify 16-point semibold group headings, 14-point medium titles, 11-point supporting copy, 20-point icons, 72-point minimum rows and common separators. Quick settings and semantic search resource pages use these styles. Existing model, download, permissions, recording and index operations remain wired to their existing handlers. Audio import remains available under Data Sources; original recordings open the existing library filter. EurekaRing retains its compile flag.

## Verification

- Signed Simulator build passed using `WristNotes.xcworkspace`, scheme `WristNotes`, Debug, destination `332DEB86-4843-4543-8C73-4719B38DA704`, derived data `/tmp/wiselife-publish-20261028/build`, `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`.
- `codesign --verify --deep --strict` passed; simulated application identifier and keychain group are `cloud.karama.wisenote`.
- Update installation and launch passed, retaining existing App data.
- Native Simulator UI checks via CUA: six groups in correct order; Quick Settings opens and contains Action button, Lock Screen widget and Live Activities; Action button instructions open and return; AI Retrieval opens with separate semantic resource, translation resource and index groups; language menu offers Simplified Chinese, English, Traditional Chinese and Japanese; data-source label opens the existing authorization detail; Data & Privacy opens; Original Recordings navigates to the library with its filter selected.
- Screenshots inspected for settings overview, quick settings and retrieval typography/spacing. Final selector sizing adjusted to explicit 13-point values and a down chevron to match the prototype.
- Scoped `git diff --check`, Swift parse, menu-order assertion and string-catalog JSON parse passed. New labels have English and Japanese localizations.

Logs: `/tmp/wiselife-settings-native-20261031/`. Pre-task snapshots of the six edited Swift/string files are under `before/` in that folder.

UI checks did not change permissions, Face ID, model configuration, or the selected retrieval language; no resources downloaded or indexes deleted. This verifies Simulator layout/navigation, not real-device Apple Translation downloads or Watch transfer. No database migration or Git publication.

Final pass: `build-final.log` reports `BUILD SUCCEEDED` (exit 0); strict signature validation and update install/launch also returned 0. Final App PID 44501. CUA screenshot confirmed the smaller appearance/language values and all six group headings; Simulator is left on the Settings overview for review.
