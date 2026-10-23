# Console components

The console uses shadcn/ui's **new-york / Radix** components. Official source lives in `apps/web/src/components/ui`; console adaptations live in `components/controls.tsx` and `components/dialogs.tsx`.

Import `Button`, `Input` and `Modal` from the console controls module. Button preserves existing `primary`, `secondary`, `text-button` and `icon-button` classes while sharing focus, disabled and size behavior. A `title` becomes an accessible Tooltip. New code can use explicit shadcn `variant` and `size` props.

The Console shell merges Note navigation into its left sidebar. That sidebar and the Note Agent panel collapse independently. Primary navigation labels stay visible while expanded; collapsed icon buttons use `tooltipSide="right"` to keep tooltips clear of adjacent menu rows. The API Docs and Sign out rows share navigation geometry. `console-polish.css` supplies the Console's neutral type and spacing layer after the legacy styles, while the existing components and product APIs remain in place.

Use `useDialogs().confirm(message)` or `.prompt(message)` and await the result. Cancel, backdrop and Escape resolve without performing the action. Modal traps focus and restores it to its opener. Files details remains a modeless side panel.

Use the shadcn Dropdown Menu for action menus; native form selects are intentionally retained. The editor menu portals within its toolbar so Tiptap retains the selection when focus moves into the menu; Escape returns to the trigger and selecting a style returns to the document.

`ui.css` maps tokens to the existing console's white/sage surfaces, green primary and focus colors. Tailwind v4 runs without Preflight to preserve document and table styling. Note-title input typography is explicitly preserved. File inputs, checkboxes, textareas, form selects and imperative Tiptap extension widgets retain their native behavior in this increment.

Run `npm run build:web` and `npm run test:ui`. The latter starts or reuses local Vite and tests a fixture excluded from the production build. For actual console flows, run the PostgreSQL HTTP service documented in README and use `VESSEL_E2E_ORIGIN=http://127.0.0.1:<port>` with a matching `NOTES_ISSUER_URL`. HTTP custom domains are not secure browser contexts and cannot provide `crypto.randomUUID` used by Files. OSS upload/download/version/purge tests additionally require the approved isolated OSS configuration.

Official component source: https://ui.shadcn.com/r/styles/new-york/{button,input,dialog,dropdown-menu,tooltip}.json.

## Homepage

The separate marketing build also reuses the same official shadcn Button, using `asChild` so navigation remains an anchor. Homepage actions keep their existing teal, dark teal and cream palette through local CTA variables; button corners use 8px and larger panels use 12px. Keyboard focus follows the homepage's teal accent. The homepage has no Input, Dialog, Dropdown or Tooltip use cases in this increment; its native FAQ disclosures remain unchanged.

Verify with `npm run build:marketing` and `VESSEL_E2E_ORIGIN=<marketing-preview-origin> npx playwright test tests/e2e/marketing-home.spec.mjs --reporter=line`.
