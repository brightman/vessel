# Vessel Web Console Implementation Plan

> **For agentic workers:** Use the approved Vessel Web Console design. Execute tasks inline with a red-green cycle and review each result before continuing.

**Goal:** Deliver a locally usable Vessel browser console for registration, login, teams, Pages, and Apps.

**Architecture:** A React/Vite frontend reuses the Baizhi Pages Tiptap editor modules and calls Vessel's existing API. FastAPI serves the built frontend at `/console` and `/register`.

**Tech Stack:** React 19, TypeScript, Vite, Tiptap 3, FastAPI, Playwright, PostgreSQL.

## Global Constraints

- Preserve all existing dirty worktree files and the Baizhi Pages source tree.
- Do not expose legacy Page Agent or proposal routes.
- Keep tokens in memory, respect existing refresh cookies and API role permissions.
- Keep focused and core tests at or below 100 cases; finish with a real browser E2E.

---

### Task 1: Same-origin frontend entry

**Files:** `apps/api/src/vessel_service/main.py`, `apps/api/tests/test_web_console.py`, `apps/web/index.html`, `apps/web/vite.config.ts`, root `package.json` and lockfile.

**Interface:** `GET /console` and `GET /register` return the built HTML; `/console/assets/*` returns built assets. In development Vite proxies `/v1` to `127.0.0.1:52003`.

- [ ] Write and run a failing API test for the HTML and asset routes.
- [ ] Add the Vite package and static serving implementation; run the test green.
- [ ] Build the frontend and verify the served HTML references reachable assets.

### Task 2: Auth, spaces, and teams

**Files:** `apps/web/src/api.ts`, `apps/web/src/App.tsx`, `apps/web/src/Teams.tsx`, `apps/web/src/styles.css`, `tests/e2e/console.spec.mjs`.

**Interface:** typed API client owns the memory token and refresh flow; the shell provides selected space and permissions to its views.

- [ ] Write a failing browser scenario for direct registration, login restoration, team creation, invitation by user ID, acceptance, and role controls.
- [ ] Implement the client and shell, then team operations using existing endpoints.
- [ ] Run the browser scenario green against isolated local data.

### Task 3: Pages editor integration

**Files:** `apps/web/src/Pages.tsx`, copied `apps/web/src/editor/*` modules, `apps/web/src/editor.tsx`, `apps/web/src/api.ts`, `tests/e2e/console.spec.mjs`.

**Interface:** `PageEditor` receives a Page document, change handler, and `readOnly` flag. Pages view passes `expected_revision` on every save.

- [ ] Extend the browser scenario to fail on creating and editing a team Page.
- [ ] Copy only editor dependencies from Baizhi Pages and adapt imports and read-only mode.
- [ ] Implement space-owned Page and directory calls, version-aware save, archive/restore, and history.
- [ ] Run the scenario green and type check the copied editor.

### Task 4: Apps management

**Files:** `apps/web/src/Apps.tsx`, `apps/web/src/api.ts`, `tests/e2e/console.spec.mjs`.

**Interface:** App form emits `{name, manifest:{tables:{...}}}`; typed record controls emit `{values}` and versioned updates.

- [ ] Extend the browser scenario to fail on App creation, record creation, edit, and viewer read-only behavior.
- [ ] Implement guided Manifest creation, advanced JSON update, typed record forms, cursor pagination, and version conflict handling.
- [ ] Run the scenario green and build.

### Task 5: Final integration and local delivery

**Files:** `README.md`, `scripts/dev/start-api.sh` only if necessary, E2E configuration.

- [ ] Run focused backend and frontend tests, then affected core tests within the 100 case cap.
- [ ] Run the complete browser E2E against isolated PostgreSQL and inspect the rendered UI.
- [ ] Restart the local API with the built frontend and verify `/console`, `/register`, assets, `/healthz`, and `/readyz`.
- [ ] Report commands, test counts, result, and unverified boundaries.
