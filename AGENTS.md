# Vessel repository guidance

When a task asks you to work with Vessel data through the service, use the `vessel` CLI from [tools/vessel-cli/README.md](tools/vessel-cli/README.md).

- Require a named environment for each network command. Confirm the signed-in identity with `vessel auth whoami` before writes.
- Inspect the target space, Page, App, table or file by exact ID before changing it. Preserve expected revision/version fields.
- Read request bodies and binary data from local files. Never put passwords, tokens, file contents or signed URLs in chat or command arguments.
- Treat nonzero exit codes and JSON `ok: false` as failures. Keep API error codes in the report.
- Production writes require explicit user authorization and `--confirm`; `--confirm` alone is not authorization.

The CLI accesses the HTTP API as the user's account. Do not access the database or object store directly for user operations.
