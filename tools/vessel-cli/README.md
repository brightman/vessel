# Karama.Cloud CLI (`vessel`)

`vessel` lets Codex operate a signed-in user's Vessel space through the HTTP API. It never connects to the database or uses OSS service keys.

## Install and configure

```sh
uv pip install --python apps/api/.venv/bin/python ./tools/vessel-cli
vessel env set local http://127.0.0.1:52003
vessel auth login --env local --email you@example.com
vessel auth whoami --env local
```

The install command above adds `vessel` to `apps/api/.venv/bin`. Re-run it after updating the package. To install it as a user-level command instead, use `uv tool install ./tools/vessel-cli`.

Login prompts for the password without echo. The CLI stores the access token, refresh token, and expiry in plaintext in `~/.config/vessel/.env` (or `$XDG_CONFIG_HOME/vessel/.env`), scoped to the selected environment and host. The file is written atomically with mode `0600`; the `vessel` config directory is mode `0700`. The CLI loads the file itself, so credentials persist across commands without shell setup. Before login or token refresh it verifies that the file can be written, read, and cleaned up. `vessel auth logout --env local` revokes the session and removes its token entries. Do not commit or share this file. Hosts are stored in `~/.config/vessel/hosts.json` (or `XDG_CONFIG_HOME/vessel/hosts.json`); this file contains origins only. Supported names are `local`, `test`, `staging`, and `production`. Production requires HTTPS. Every network command needs `--env` or `VESSEL_ENV`.

## Common commands

```sh
vessel spaces list --env local
vessel spaces permissions SPACE_ID --env local
vessel files root SPACE_ID --env local
vessel files list SPACE_ID --parent FOLDER_ID --env local
vessel files search SPACE_ID --name report --env local
vessel files upload SPACE_ID FOLDER_ID ./report.pdf --env local
vessel files download FILE_ID ./report.pdf --env local
vessel notes list SPACE_ID --env local
vessel notes get NOTE_ID --env local
vessel notes create SPACE_ID "Research" ./document.json --env local
vessel notes update-markdown NOTE_ID ./note.md --expected-revision 2 --env local
vessel apps list SPACE_ID --env local
vessel apps create SPACE_ID "Project tracker" ./manifest.json --env local
vessel apps tables APP_ID --env local
vessel apps records query APP_ID TABLE ./query.json --env local
vessel apps records create APP_ID TABLE ./values.json --env local
vessel apps records update APP_ID TABLE RECORD_ID ./values.json --expected-row-version 2 --env local
vessel apps manifest apply APP_ID ./manifest.json --expected-version 2 --confirm --env local
```

`document.json` must be a Tiptap document object; record files must be JSON objects containing only declared business fields. `query.json` follows the server's record query body. The CLI requires exact IDs and expected versions. All output is JSON, including errors; the exit code is nonzero on failure. Production mutations require `--confirm`; manifest changes always require it. Avoid passing passwords, tokens, file bytes, or signed URLs to Codex as command arguments.

Files upload in chunks through signed OSS URLs and polls the asynchronous worker. Downloads are checked against the server-provided SHA-256 and size before replacing the destination. The API must have OSS configured and the Files worker running for these commands. A failed upload returns a nonzero error code. Signed URLs and tokens are never included in CLI results.

This release does not manage teams, file sharing grants, trash/purge, App H5 releases, account registration, or MCP. API authorization remains authoritative.

Run tests from the repository root with `PYTHONPATH=tools/vessel-cli apps/api/.venv/bin/python -m pytest tools/vessel-cli/tests -q`.
