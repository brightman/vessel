# Homepage component alignment

User approved extending the existing shadcn/ui component standard to the homepage. Preserve its teal/cream palette, existing text, sections, navigation destinations and native FAQ disclosure behavior.

1. Add a failing browser check for 8px CTA corners, preserved teal, keyboard focus and navigation/FAQ behavior.
2. Enable the existing Tailwind integration in the separate marketing Vite build, without Preflight. Reuse the console's official shadcn Button with asChild anchors; theme locally to the homepage's existing palette.
3. Apply the shared size, radius and focus conventions to existing action links. No new forms, dialogs, dropdowns, tooltips or product features.
4. Build both sites, run homepage desktop/mobile/control regressions and inspect screenshots. Preserve all preexisting edits and do not deploy.

Verification: the new radius assertion failed against the original 999px buttons, then all 3 homepage browser tests passed after migration. Marketing and console production builds passed; desktop and 390px screenshots inspected, and `git diff --check` passed. Existing copy edits retained. No deployment performed.
