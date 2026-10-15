# Vessel Web Console Design

## Goal and scope

Provide a small browser console for Vessel accounts, personal and team spaces, Pages, and Apps. It must run against Vessel's existing `/v1` API and be usable at the local API origin. File management and the future Vessel Page Agent are outside this increment.

## Architecture

Use a React, TypeScript, and Vite frontend under `apps/web`. Copy the Baizhi Pages Tiptap editor and its directly required editor modules into Vessel, preserving its document schema and stable block IDs. Build a new Vessel console shell around that editor instead of copying the Baizhi Pages Agent and proposal UI. Serve the built bundle from FastAPI at `/console` and `/register`; Vite proxies `/v1` to the local API in development. The UI introduces no new data model or account API.

The access token lives in JavaScript memory. Login and registration set the existing HTTP only refresh cookie. On reload the frontend calls `/v1/auth/refresh`, and on logout it calls `/v1/auth/logout`. The registration link is visible when `/v1/auth/options` enables it. API calls remain same origin and include the Bearer token. The API remains the authorization boundary.

## Main flows

1. After login, list `/v1/spaces` and select a personal or team space. Fetch `/v1/spaces/{id}/permissions`; use the capabilities to disable write and member controls. Clear the selected resource when switching spaces. Retain only the selected space ID in local storage.
2. Team management creates a team, shows members and pending invitations, invites an already registered user by `user_id`, accepts the signed-in user's invitations, changes roles, revokes invitations, and removes members. Show and copy the current user's ID because the API has no email lookup or email invitation.
3. Pages list/create through `/v1/spaces/{id}/pages`, and directories through `/v1/spaces/{id}/directories`. Detail edits use `PATCH /v1/pages/{id}` with `expected_revision`; archive/restore and version history use existing Page endpoints. The copied Tiptap editor emits the Vessel document JSON. Show a save button and unsaved state. A 409 keeps the local draft visible and requires the user to reload or copy it; it never silently overwrites server content. Image upload controls are disabled when storage is unavailable.
4. Apps list/create through the space routes. A guided one-table form creates a valid Manifest, while an advanced JSON editor permits multiple tables and additive Manifest updates. Table records render from field definitions, preserving numeric values as strings and parsing JSON fields explicitly. List pages use the API cursor. Updates and deletes pass the row version. A 409 requires reload before retry.

## Errors and security

Render API error codes and validation details near the action. Never store access tokens or passwords in local storage. Do not render user input as unsanitized HTML. All destructive actions require a browser confirmation. Role based UI controls are convenience only; all writes still rely on API authorization. Do not call inherited Page Agent, proposal, or MCP routes.

## Verification

Build and type check the frontend. Run focused backend route tests and frontend API/UI tests, then affected auth, team, Page, and App tests, keeping the total at or below 100 cases. Finish with a real browser E2E against an isolated PostgreSQL database: register two users, create a team, invite and accept, create and edit a Page, create an App and record, and verify viewer write controls and API rejection. Report commands, case counts, results, and the E2E scenario.
