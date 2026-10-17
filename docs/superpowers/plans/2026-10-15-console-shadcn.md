# Console shared controls

Approved scope: use shadcn/ui, preserve existing colors, unify Button, Input, Dialog, Dropdown and Tooltip. Keep Pages/Apps/Files business contracts and existing unrelated edits.

- Import official shadcn new-york Radix components and dependencies.
- Add Tailwind v4 without Preflight; map semantic tokens to the existing palette.
- Migrate React buttons and text inputs; preserve native file inputs, checkboxes and selects.
- Replace modal containers and native confirm/prompt with controlled Dialogs. Keep Files details as a modeless side panel.
- Replace editor text-style popup with Dropdown Menu and existing title hints with Tooltip.
- Verify production build, shared-control browser test, console workflows, Files metadata workflows, and desktop/mobile screenshots.

The source components are from https://ui.shadcn.com/r/styles/new-york/{button,input,dialog,dropdown-menu,tooltip}.json. Project adaptations live in `components/controls.tsx`, `components/dialogs.tsx` and `ui.css`. The overlay uses the existing restrained opacity. Large page titles explicitly retain their previous typography.

## Verification

- `npm run build:web`: passed. Existing large-bundle and client-directive warnings remain informational.
- 19 affected Chromium E2E tests: passed against isolated PostgreSQL and real HTTP. Covers auth, teams, Pages, Apps records/publishing, Files metadata/permissions/moves/trash restore, shared controls and 390px Dialog margins.
- Editor dropdown geometry/selection/keyboard regression: 3 consecutive passes after measuring the toolbar after React commit.
- Independent focused review: title typography and Escape focus findings fixed; follow-up found no further actionable issues.
- Desktop Pages/Apps and Files desktop/mobile screenshots inspected. Console colors are sourced from its existing white/sage/green palette; navigation alignment and large title typography retained.
- OSS-dependent upload/download/version/purge paths were not revalidated in this UI increment; the isolated test server intentionally had no OSS configuration. No deployment or commit was performed; unrelated working-tree edits retained.
