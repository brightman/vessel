# Vessel Apps Layout Implementation Plan

**Goal:** Align Vessel Apps layout and styling with the local baizhi-agent Apps HTML/CSS reference while keeping Vessel APIs and permissions.

**Architecture:** Keep Apps state and API calls in `apps/web/src/Apps.tsx`. Replace its App-first rail shell with a card overview and dedicated Setting, Data, and Publish workspaces. Add scoped CSS in a new `apps/web/src/apps.css`, imported by Apps. The global Console shell is unchanged.

**Tech Stack:** React 19, TypeScript, Vite, native CSS, existing Vessel API client and controls.

## Global Constraints

- No Field Agent, Preview, App delete action, Baizhi identity, or row SQL policies.
- Keep Vessel space-role authorization and all existing version checks.
- Preserve unrelated dirty worktree files; edit only task-owned files.
- Do not add or run tests because the user has not asked for testing.

## Tasks

### Task 1: Landing and navigation

**Files:** `apps/web/src/Apps.tsx`

- [x] Replace automatic first-App selection with an overview mode.
- [x] Add local name/description/ID search and status chips backed by the existing active/archived list API.
- [x] Render reference-style App cards with Setting, Data, Publish actions and a role-aware create button.
- [x] Move the existing creation form into a modal and preserve its guided and JSON paths.
- [x] Give each workspace a Back to Apps control and preserve existing operations.

### Task 2: Data and publishing presentation

**Files:** `apps/web/src/Apps.tsx`

- [x] Move Data table selection into a collapsible inner rail beside the query and grid panels.
- [x] Keep record CRUD/query, pagination, conflict recovery, and disabled states wired to Vessel APIs.
- [x] Remove draft Preview link, preview state, and preview copy from Publish.

### Task 3: Reference-aligned CSS

**Files:** `apps/web/src/apps.css`, `apps/web/src/Apps.tsx`

- [x] Scope neutral/blue tokens and 1240px content width under `.vessel-apps`.
- [x] Match the reference's cards, headers, filters, modal, Data rail, grid, settings panels, and release list.
- [x] Add responsive stacking and visible focus styles.

### Task 4: Review deliverable

**Files:** task-owned files above

- [x] Inspect the exact diff for accidental API, permission, and unrelated changes.
- [x] Run a TypeScript/Vite build for compile feedback; do not run tests.
- [x] Report browser visual comparison as unavailable if the computer-use bridge remains down.
