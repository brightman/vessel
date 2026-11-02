# Settings navigation adjustment

User-approved layout: Quick Recording follows App Language; AI Retrieval follows AI Model and owns the existing Local Semantic Search controls. Keep current native styling.

## Implementation

- Move the Daybook Quick Recording entry, preserving its existing sheet and recording behavior.
- Add `aiRetrieval` to Daybook and legacy Settings routes. Present `AIRetrievalSettingsView`, a `SettingsPage` wrapper around the existing semantic settings.
- Remove semantic controls from `AISettingsView`; retain AI model editing, saving and outbound confirmation preferences.
- Update retrieval fallback copy and new entry translations. Update current retrieval documentation paths.
- Build the signed Simulator app, inspect scoped diffs, cover-install and launch without resetting data. This is a reversible navigation-only change; no new automated tests or data migrations.

No Git publication or unrelated dirty-worktree edits.

## Verification

Completed: signed iPhone Simulator build, signature and keychain identity verification, update installation and launch. Native Simulator UI via CUA showed Quick Recording directly after App Language and AI Retrieval directly after AI Model. Opened Quick Recording successfully; opened AI Retrieval and confirmed Local Semantic Search, language selection, resource status and index controls. New screen left open for user review. Scoped diff whitespace check passed. No recording/model preferences changed during verification.

## Approved prototype follow-up — 2026-10-31

User reviewed `prototype/iphone-day.html?preview=settings` and approved native implementation.

- Overview order: 通用设置 (外观, 界面语言, 快捷设置), 语言与AI, 硬件, 数据来源, 隐私与安全, 关于.
- Share menu typography: section 16 semibold, row 14 medium, supporting text 11 regular; 20-point icons, 72-point minimum rows and common separators.
- Quick settings contains Action button, Lock Screen widget, and Live Activities instruction pages, with existing permission/status controls retained.
- AI Retrieval separates local semantic resources, Chinese-English translation resources and index controls. Resource acquisition and index lifecycle remain the existing implementations.
- Data-source switches use `LifeSourceModel.setEnabled`; labels open the existing detail/authorization sheet. Keep audio import and expose original recordings through the existing library filter.
- Move existing Face ID control into privacy; add local data-use explanation. Show About links directly.
- Keep EurekaRing behind the existing compile flag. No database/schema, recording, transport or model-provider changes.
- Scoped files: DaybookView, SettingsViews, QuickRecordingSettingsView, DaybookSemanticSettingsView, MyVoiceEnrollmentView, Localizable.xcstrings. No Git publication requested.
- Verification: signed Simulator build, update install, and native visual/navigation checks. No permission toggles, downloads, index deletions or real credential changes are needed for this layout acceptance.
