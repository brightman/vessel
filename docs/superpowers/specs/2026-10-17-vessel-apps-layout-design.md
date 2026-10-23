# Vessel Apps layout alignment

**Status:** Approved by user on 2026-10-17

## Goal and reference

Align the Vessel Console Apps layout and visual hierarchy with the Apps pages in `/Users/karama/Documents/baizhi-apps-worktree/static/apps-app.jsx` and `static/apps-styles.css`. The source files are the visual reference because browser automation was unavailable during design review.

## Scope

- The Apps landing view becomes a card list with a heading, search, status filters, a create button, empty state, and a create modal. Cards show App name, description, Vessel status, table count, and Setting, Data, and Publish actions.
- Choosing an action opens a dedicated workspace with a Back to Apps control and a heading. Setting retains App details, additive schema controls, raw Manifest editor, archive/restore, and audit history. Data uses a collapsible table rail and a grid-oriented content panel. Publish retains upload, publish, release history, and rollback.
- Match the reference's content width, card proportions, spacing, typography, pills, borders, compact controls, and responsive stacking. Use CSS scoped to Vessel Apps so the Console navigation and other products are unaffected.
- Keep the existing Vessel App IDs, APIs, record query contract, optimistic version checks, and Owner/Admin/Editor/Viewer authorization. The UI hides or disables controls according to existing permissions; the API remains the authority.
- Do not include Field Agent, per-row SQL policy, Baizhi identity, or Preview. Remove the current draft Preview link and related frontend state. Do not add an App deletion action; Vessel provides archive/restore.

## Navigation and states

Landing is the default whenever Apps is opened or the selected space changes. App actions switch to Setting, Data, or Publish in client state. Back returns to the current list and filter. Archived Apps are available to managers via a status filter and open in Setting only. The create modal contains the existing guided Manifest form and advanced JSON form. Search matches name, description, and exact App ID locally within the loaded list. All loading, empty, conflict, and API error states stay visible.

## Data and styling boundary

No database migration or new service endpoint is required. Landing status filters use Vessel's `active` and `archived` statuses, rather than Baizhi's `published` and `draft` labels, which describe a different resource model. A card's Publish action leads to Vessel release management; published releases are shown there. CSS uses the reference's neutral surfaces and blue accents inside Apps, with the global Karama.Cloud navigation retained.

## Acceptance boundary

The implementation should preserve create, settings, Manifest, record CRUD/query, H5 upload/publish/rollback, and role-aware disabled states while presenting the new layout at desktop and narrow widths. No automated tests or browser verification are requested in this task; report the actual verification performed and the unavailable browser separately.
