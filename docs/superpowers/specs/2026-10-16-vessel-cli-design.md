# Vessel CLI for coding agents

Status: approved for implementation on 2026-10-16.

## Goal

Provide a standalone `vessel` command that Codex can call through a terminal. It uses Vessel's existing HTTP API and the signed-in human user's permissions. It never connects to PostgreSQL or uses OSS service credentials.

## Package and environments

Place an installable Python package in `tools/vessel-cli`. `vessel env set <name> <origin>` configures named `local`, `test`, `staging`, or `production` origins. Every network command requires `--env <name>` or `VESSEL_ENV`; there is no implicit production fallback. Production origins require HTTPS. Config contains only origins, never credentials. Output is one JSON object on stdout by default; errors are one JSON object on stderr with `ok: false`, stable code, HTTP status where available, and a nonzero exit code.

## Authentication

`vessel auth login --env ... --email ...` prompts for a password without echo. The login response access token and HttpOnly refresh cookie are stored in the operating system credential manager, keyed by environment and origin. The CLI may refresh the access token and rotate the cookie, updating the stored session atomically from its perspective. It never prints tokens, passwords, cookies, or signed URLs. `auth whoami` uses `/v1/auth/me`; `auth logout` revokes the refresh session and removes local credentials. Failure to access a secure OS store is a clear error; no plaintext file fallback.

## Commands

- `spaces list`, `spaces permissions <space-id>`.
- `files root/list/search/get/mkdir/rename/shared/versions/upload/download`. Upload reads a local path in chunks, hashes it, creates an upload intent, follows the server's signed single or multipart instructions, completes it, and polls until `ready` or a terminal failure. Download writes a local file through a temporary path and verifies size and SHA-256 before atomic replacement. Signed URLs never enter JSON output.
- `pages list/get/export-markdown/create/update-markdown`. Create reads a Tiptap document from a JSON file. Markdown update reads a local file and requires `--expected-revision`.
- `apps list/get/tables/records list/query/get/create/update` and `apps manifest apply`. Record and query values come from JSON files. Update requires `--expected-row-version`; manifest apply requires `--expected-version` and `--confirm`.

Resource IDs are exact; names are not resolved heuristically. All operations continue to be authorized by the server. File mutations use a fresh `Idempotency-Key` per request. No command accepts arbitrary URL or arbitrary HTTP method. This first release excludes team administration, App H5 publishing, file sharing mutations, trash/purge, MCP server, and registration.

## Safety and errors

The CLI sends bearer tokens only to the configured Vessel origin. Signed OSS URLs are used only for upload/download data transfer and are not printed. Production writes require explicit `--confirm`. Destructive operations are not exposed in this version. API 409/422/503 codes are preserved in CLI errors. A failed asynchronous upload reports its final `failure_code` and a nonzero exit. File paths are local to the CLI process; binary bytes never pass through command arguments or model output.

## Acceptance

Unit tests cover environment isolation, secure-store failures, login/refresh/logout, redacted errors, optimistic versions and file checksum failures. An isolated PostgreSQL HTTP test exercises login, space listing, Page and App record read/write. File upload/download requires configured test OSS and worker; in its absence, test the signed transport with a fake HTTP boundary and report live OSS as unverified. Package installation, `--help`, JSON output, and exit codes must work from a clean invocation.
