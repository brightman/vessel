# Vessel CLI Implementation Plan

**Goal:** Build an installable CLI for Codex to operate Vessel through its existing HTTP API.

**Architecture:** Keep named host configuration, OS credentials, HTTP session handling, file transfer, and command parsing in separate modules under `tools/vessel-cli`. The CLI emits stable JSON, preserves API error codes, and applies server authorization.

**Tech Stack:** Python 3.11+, argparse, httpx, keyring, pytest.

## Constraints

- Preserve existing dirty worktree changes and avoid server-side API edits.
- Require an explicit named environment or `VESSEL_ENV`; production requires HTTPS.
- Store tokens and refresh cookies only in a secure OS credential store.
- Read document, manifest, record, and binary content from local files, never shell arguments.
- Require exact resource IDs and expected versions for optimistic writes.

## Tasks

### 1. Package, environment, and credentials

- [x] Add installable package metadata and `vessel` entry point.
- [x] Write failing tests for origin validation, explicit environment selection, secure backend rejection, and credential key isolation.
- [x] Implement host config and credential store with no plaintext fallback.
- [x] Run targeted tests.

### 2. Authenticated HTTP client

- [x] Write failing tests for login, refresh rotation, logout, API errors, and secret redaction.
- [x] Implement client with configured origin, bearer header, refresh cookie handling, and stable CLI errors.
- [x] Run targeted tests.

### 3. Command surface

- [x] Write failing command tests for spaces, Pages, Apps, JSON output, required expected versions, and production confirmation.
- [x] Implement parser and handlers using exact `/v1` paths and local JSON/Markdown inputs.
- [x] Run targeted tests.

### 4. File transfer

- [x] Write failing fake-HTTP tests for a signed upload, async status, download checksum, and signed-URL redaction. Multipart handling is implemented by the same part loop; no large OSS transfer has been run.
- [x] Implement chunked file transfer and command handlers.
- [x] Run targeted tests.

### 5. Documentation and live acceptance

- [x] Document installation, environment setup, auth, safe Codex invocation, commands and limits in CLI README and repository README.
- [x] Install package in the project environment, inspect `vessel --help` and mutation command help, and run `git diff --check`.
- [ ] Run authenticated isolated PostgreSQL HTTP calls against the local API and report unverified OSS path if no test Bucket is configured. Local API is configured for development registration, but no test account was created in this task.
