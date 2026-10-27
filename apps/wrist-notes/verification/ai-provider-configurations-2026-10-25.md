# Independent AI provider settings

Four provider profiles are stored under aiProviderConfigurations. The selected
profile remains in aiConfiguration for existing consumers. Custom API keys and
ChatGPT/Mac credentials remain in their existing Keychain stores.

The editor keeps a draft per provider while the settings page is open. Selecting
a saved, unchanged custom profile restores its accepted configuration state;
changing endpoint, model, protocol or key still requires a new test. Closing
without saving continues to discard draft edits.

Old configuration fields are migrated where recoverable. A Mac pairing can also
be restored from Keychain without another scan. Previously overwritten custom
fields cannot be reconstructed if no saved copy remains.

Verification:
- scripts/test_ai_settings.sh passed: all four providers selected/saved in turn,
  custom and Mac settings survive restart, ChatGPT account/model survive switching,
  unsaved drafts preserved within editor, credentials excluded from profile JSON,
  existing configuration validation and stale-test checks.
- Final iOS Simulator Debug build passed, including the Keychain restore UI.
- git diff --check passed.
- No physical device UI acceptance performed.
