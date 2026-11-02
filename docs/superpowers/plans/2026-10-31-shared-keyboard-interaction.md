# Shared keyboard interaction

**Goal:** Search, Ask AI and editing/settings sheets share the same keyboard behavior: hide bottom navigation while the keyboard overlaps the app, dismiss on outside tap or interactive scrolling, preserve drafts and ordinary control actions.

**Cause:** `DaybookView` hides its bottom bar only for the AI composer's focus callback. Only the AI conversation scroll view dismisses focus on an outside tap. Search and sheet inputs have no common focus/dismissal owner.

**Implementation:** A window-scoped `AppKeyboardCoordinator` observes local keyboard frame changes and installs a non-cancelling tap recognizer. It ignores text inputs, text-selection editing controls and the press-to-talk microphone. Attach it once to the root view; sheets in that window inherit the behavior. Bottom navigation reads keyboard visibility. Page transitions explicitly dismiss before optional search autofocus. Preserve the native keyboard safe-area behavior and propagate interactive scroll dismissal.

**Files:** `Sources/iPhone/AppKeyboardCoordinator.swift`, `DaybookView.swift`, `DaybookAssistantView.swift`, `WristNotesApp.swift` if root inheritance requires it; project membership/generator; `Tests/KeyboardInteractionUITests.swift`; `scripts/test_keyboard_ui.rb`.

## Steps

- [x] Reproduce search navigation and outside-tap failures with the installed app and a native XCTest runner.
- [x] Implement shared keyboard lifecycle, outside-input hit filtering and navigation cleanup. Remove the AI-only bottom navigation rule.
- [x] Exercise search, Ask AI, settings/form fields, multi-field focus changes and scrolling. Verify existing voice hold/release still works. Do not send AI questions or save test records/settings.
- [x] Build and install on the simulator, and record actual verification boundaries. User requested simulator verification first; defer device installation/acceptance.

## Added pending-recording defect

- [x] Inspect and back up the simulator's stuck draft. Its M4A lacks a readable `moov` atom, duration is zero, and ordinary retry cannot import it.
- [x] Add a direct confirmed delete action to the failed recording banner. Retain the pending draft identity if recovery throws; surface cleanup failures so deletion can be retried.
- [x] Verify filesystem refusal, retry and preservation of unrelated files with the recording-session regression suite.
- [x] Exercise retry failure, cancel delete, confirm delete and relaunch through native simulator UI; verify the exact draft manifest/directory are removed and its backup remains.

Evidence: `apps/wrist-notes/verification/keyboard-and-pending-recording-2026-10-31.md`.

## Simulator installation correction

UI acceptance requires a signed simulator app, even when only testing keyboard behavior. Use `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` and validate the generated simulator entitlement with `Tests/test_keychain_entitlements.py` before installing. The earlier unsigned app installation caused Keychain `-34018`; compile success and keyboard-only checks did not catch that packaging regression. Follow-up evidence: `apps/wrist-notes/verification/keychain-installation-2026-10-31.md`.

Work proceeds inline in the existing dirty checkout; preserve prior changes. No Git publication requested.
