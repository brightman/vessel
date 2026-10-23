# Console Three-Column Visual Polish Implementation Plan

**Goal:** Merge Notes navigation into the Console sidebar, make the Agent independently collapsible, and unify Console component styling.

**Architecture:** Keep `App` as the Console shell. Render the Notes navigation into a dedicated sidebar slot using a React portal; `Notes` retains its own state. Keep `NoteAgent` mounted while hidden so streaming and proposal state survive collapse. Add a late-loaded scoped stylesheet for visual tokens and responsive rules.

**Tech Stack:** React 19, TypeScript, shadcn/ui, Radix UI, Tailwind v4, Lucide React, CSS.

## Global Constraints

- Preserve unrelated dirty worktree files and existing service/permission behavior.
- Do not add or run tests; run the Web build and whitespace check only.
- No new component library or server endpoint.

## Tasks

### Task 1: Shared shell and navigation

**Files:** `apps/web/src/App.tsx`, `apps/web/src/components/controls.tsx`

- [x] Add the Note navigation slot and pass it to Notes.
- [x] Align API Docs and Sign out as footer navigation rows.
- [x] Show right-side tooltips only for collapsed navigation icons.

### Task 2: Notes layout and Agent

**Files:** `apps/web/src/Notes.tsx`, `apps/web/src/NoteAgent.tsx`

- [x] Portal the existing Note list into the sidebar without moving data state.
- [x] Add independent right Agent collapse/expand controls and preserve the mounted Agent.
- [x] Keep narrow-screen access to both side panels.

### Task 3: Visual system

**Files:** `apps/web/src/console-polish.css`, `apps/web/src/main.tsx`

- [x] Establish scoped typography, spacing, border and surface tokens.
- [x] Normalize navigation rows, icons, tooltips, editor, and Agent controls.
- [x] Add responsive and reduced-motion behavior.

### Task 4: Review

- [x] Inspect the task diff and build the Web app.
- [x] Report visual-verification limits honestly.
