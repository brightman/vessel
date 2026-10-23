"""Stable JSON command surface for Vessel."""

import argparse
import getpass
import json
import sys
from pathlib import Path
from urllib.parse import quote

from .client import VesselClient
from .config import CliError, Config
from .credentials import CredentialStore


class CliArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise CliError("CLI_ARGUMENTS_INVALID")


def segment(value: str) -> str:
    return quote(value, safe="")


def read_object(path: str) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CliError("JSON_INPUT_INVALID") from exc
    if not isinstance(value, dict):
        raise CliError("JSON_OBJECT_REQUIRED")
    return value


def read_text(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise CliError("INPUT_READ_FAILED") from exc


def build_parser() -> argparse.ArgumentParser:
    parser = CliArgumentParser(
        prog="vessel",
        description="Karama.Cloud CLI for coding agents",
        epilog=(
            "Network commands require an environment. Set VESSEL_ENV or pass --env on the command; "
            "env set configures an environment origin. Results are JSON. Production writes require --confirm; "
            "manifest apply requires it in every environment.\n"
            "Examples:\n"
            "  vessel env set local http://127.0.0.1:52003\n"
            "  vessel auth login --email you@example.com --env local\n"
            "  vessel spaces list --env local"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--env",
        choices=("local", "test", "staging", "production"),
        help="named API environment to use (overrides VESSEL_ENV)",
    )
    groups = parser.add_subparsers(dest="group", required=True, parser_class=CliArgumentParser)

    env = groups.add_parser("env", help="configure and list named API environments", description="Configure the API origin for an environment or list saved environments.")
    envs = env.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    envs.add_parser("list", help="list saved environment origins", description="Show the configured API origin for each named environment.")
    setting = envs.add_parser("set", help="save or replace an environment API origin", description="Set the base URL used when a command selects this environment.")
    setting.add_argument("name", choices=("local", "test", "staging", "production"), help="environment name to configure")
    setting.add_argument("origin", help="API base URL, for example http://127.0.0.1:52003")

    auth = groups.add_parser("auth", help="sign in and manage the saved session", description="Sign in to an environment, show the current identity, or sign out.")
    auths = auth.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    login = auths.add_parser("login", help="sign in and save a bearer token", description="Sign in to the selected environment. The password is prompted without echo; the session is saved locally.")
    login.add_argument("--email", required=True, help="account email address")
    auths.add_parser("whoami", help="show the signed-in account", description="Show the identity returned by the selected environment.")
    auths.add_parser("logout", help="sign out and remove the saved session", description="Revoke the selected environment's session and remove its local token.")

    spaces = groups.add_parser("spaces", help="list spaces and inspect space permissions", description="List spaces available to the signed-in account or inspect permissions for one space.")
    ss = spaces.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    ss.add_parser("list", help="list spaces available to the account", description="List the spaces available to the signed-in account.")
    sp = ss.add_parser("permissions", help="show the account's permissions in a space", description="Inspect the signed-in account's role and permissions for the exact space ID.")
    sp.add_argument("space_id", help="exact space ID")

    files = groups.add_parser("files", help="browse and manage files and folders", description="List, search, upload, download, rename, and organize files in a space.")
    fs = files.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    root = fs.add_parser("root", help="get a space's root folder", description="Show the root folder for the exact space ID.")
    root.add_argument("space_id", help="exact space ID")
    file_list = fs.add_parser("list", help="list a folder's files and subfolders", description="List file items in a space, optionally under a parent folder.")
    file_list.add_argument("space_id", help="exact space ID")
    file_list.add_argument("--parent", help="folder ID to list; defaults to the space's root folder")
    search = fs.add_parser("search", help="search files by name", description="Find file items whose names contain the supplied text.")
    search.add_argument("space_id", help="exact space ID to search")
    search.add_argument("--name", required=True, help="text contained in the file or folder name")
    file_get = fs.add_parser("get", help="show file or folder metadata", description="Fetch the metadata for one file item.")
    file_get.add_argument("item_id", help="exact file item ID")
    versions = fs.add_parser("versions", help="list a file's versions", description="List versions available for one file.")
    versions.add_argument("item_id", help="exact file ID")
    fs.add_parser("shared", help="list files shared with the account", description="List shared files available to the signed-in account.")
    mkdir = fs.add_parser("mkdir", help="create a folder", description="Create a folder under the specified parent folder.")
    mkdir.add_argument("space_id", help="exact space ID")
    mkdir.add_argument("parent_folder_id", help="destination parent folder ID")
    mkdir.add_argument("name", help="new folder name")
    rename = fs.add_parser("rename", help="rename a file or folder", description="Rename one file item using its current metadata version.")
    rename.add_argument("item_id", help="exact file item ID")
    rename.add_argument("name", help="new file or folder name")
    rename.add_argument("--expected-metadata-version", type=int, required=True, help="current metadata version from the item's details")
    upload = fs.add_parser("upload", help="upload a local file", description="Upload a local file into a space folder.")
    upload.add_argument("space_id", help="exact destination space ID")
    upload.add_argument("parent_folder_id", help="destination parent folder ID")
    upload.add_argument("path", help="local path to the file to upload")
    upload.add_argument("--name", help="name to use in Vessel (defaults to the local filename)")
    download = fs.add_parser("download", help="download a file to a local path", description="Download the current file version or a selected version.")
    download.add_argument("file_id", help="exact file ID")
    download.add_argument("path", help="local destination path")
    download.add_argument("--version-id", help="specific version ID; defaults to the current version")

    notes = groups.add_parser("notes", help="read and edit notes", description="List notes, read their content, export Markdown, create notes, or update note content from Markdown.")
    ps = notes.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    note_list = ps.add_parser("list", help="list notes in a space", description="List notes in the exact space ID.")
    note_list.add_argument("space_id", help="exact space ID")
    note_get = ps.add_parser("get", help="show a note's content and metadata", description="Fetch the note with its exact ID.")
    note_get.add_argument("note_id", help="exact note ID")
    note_export = ps.add_parser("export-markdown", help="fetch a note's content as Markdown", description="Fetch a note's Markdown representation.")
    note_export.add_argument("note_id", help="exact note ID")
    note_create = ps.add_parser("create", help="create a note from a JSON document", description="Create a note from a Tiptap document JSON object in a local file.")
    note_create.add_argument("space_id", help="exact destination space ID")
    note_create.add_argument("title", help="new note title")
    note_create.add_argument("document_json", help="local path to a Tiptap document JSON object")
    note_update = ps.add_parser("update-markdown", help="replace note content from a Markdown file", description="Replace a note's content using a local Markdown file and its current revision.")
    note_update.add_argument("note_id", help="exact note ID")
    note_update.add_argument("markdown_file", help="local path to the Markdown source file")
    note_update.add_argument("--expected-revision", type=int, required=True, help="current note revision from its details")

    apps = groups.add_parser("apps", help="manage Apps, manifests, tables, and records", description="List and inspect Apps, create Apps, update manifests, and read or change table records.")
    aps = apps.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    app_list = aps.add_parser("list", help="list Apps in a space", description="List Apps in the exact space ID.")
    app_list.add_argument("space_id", help="exact space ID")
    app_get = aps.add_parser("get", help="show App details and version", description="Fetch an App by its exact ID.")
    app_get.add_argument("app_id", help="exact App ID")
    tables = aps.add_parser("tables", help="list an App's tables", description="List table names and schemas for an App.")
    tables.add_argument("app_id", help="exact App ID")
    create_app = aps.add_parser("create", help="create an App from a manifest", description="Create an App in a space using a local manifest JSON object.")
    create_app.add_argument("space_id", help="exact destination space ID")
    create_app.add_argument("name", help="new App name")
    create_app.add_argument("manifest_json", help="local path to the App manifest JSON object")
    manifest = aps.add_parser("manifest", help="manage an App manifest", description="Apply a manifest update using the App's current version.")
    ms = manifest.add_subparsers(dest="subaction", required=True, parser_class=CliArgumentParser)
    apply = ms.add_parser("apply", help="replace an App manifest", description="Apply a local manifest JSON object. This command always requires --confirm.")
    apply.add_argument("app_id", help="exact App ID")
    apply.add_argument("manifest_json", help="local path to the new manifest JSON object")
    apply.add_argument("--expected-version", type=int, required=True, help="current App version from its details")
    records = aps.add_parser("records", help="read and change App table records", description="List, query, fetch, create, or update rows in an App table.")
    rs = records.add_subparsers(dest="subaction", required=True, parser_class=CliArgumentParser)
    record_help = {
        "list": "list records in a table",
        "query": "query table records using a JSON request body",
        "get": "fetch one record by ID",
        "create": "create a record from a JSON values object",
        "update": "update a record using its current row version",
    }
    for name in ("list", "query", "get", "create", "update"):
        cmd = rs.add_parser(name, help=record_help[name], description=record_help[name].capitalize() + ".")
        cmd.add_argument("app_id", help="exact App ID")
        cmd.add_argument("table_name", help="exact table name")
        if name in {"get", "update"}:
            cmd.add_argument("record_id", help="exact record ID")
        if name in {"query", "create", "update"}:
            file_help = "local path to a JSON query body" if name == "query" else "local path to a JSON object containing field values"
            cmd.add_argument("json_file", help=file_help)
        if name == "update":
            cmd.add_argument("--expected-row-version", type=int, required=True, help="current row version from the record details")

    # A confirmation flag is accepted only on mutation leaves.
    for group in (fs, ps, aps, ms, rs):
        for action in group.choices.values():
            if action.prog.split()[-1] in {"mkdir", "rename", "upload", "create", "update-markdown", "apply", "update"}:
                confirm_help = (
                    "confirm this manifest update (required in every environment)"
                    if action.prog.endswith("apps manifest apply")
                    else "confirm this write (required when --env production)"
                )
                action.add_argument("--confirm", action="store_true", help=confirm_help)
    def add_leaf_environment(node):
        for item in node._actions:
            if isinstance(item, argparse._SubParsersAction):
                for child in item.choices.values():
                    if any(isinstance(action, argparse._SubParsersAction) for action in child._actions):
                        add_leaf_environment(child)
                    elif child.prog.split()[1] != "env":
                        child.add_argument(
                            "--env",
                            choices=("local", "test", "staging", "production"),
                            default=argparse.SUPPRESS,
                            help="named API environment to use (overrides VESSEL_ENV)",
                        )
    add_leaf_environment(parser)
    return parser


def dispatch(args, client):
    group, action = args.group, args.action
    if group == "auth":
        if action == "login":
            return client.login(args.email, getpass.getpass("Karama.Cloud password: "))
        if action == "logout":
            return client.logout()
        return client.request("GET", "/v1/auth/me")
    if group == "spaces":
        return client.request("GET", "/v1/spaces" if action == "list" else f"/v1/spaces/{segment(args.space_id)}/permissions")
    writing = (group == "files" and action in {"mkdir", "rename", "upload"}) or (group == "notes" and action in {"create", "update-markdown"}) or (group == "apps" and (action in {"create", "manifest"} or action == "records" and args.subaction in {"create", "update"}))
    if writing and client.environment == "production" and not getattr(args, "confirm", False):
        raise CliError("CONFIRM_REQUIRED")
    if group == "files":
        from .transfers import upload_file, download_file
        if action == "root":
            return client.request("GET", f"/v1/spaces/{segment(args.space_id)}/folders/root")
        if action == "list":
            return client.request("GET", f"/v1/spaces/{segment(args.space_id)}/file-items", params={"parent_folder_id": args.parent} if args.parent else None)
        if action == "search":
            return client.request("POST", f"/v1/spaces/{segment(args.space_id)}/file-items/search", body={"name_contains": args.name})
        if action == "get":
            return client.request("GET", f"/v1/file-items/{segment(args.item_id)}")
        if action == "versions":
            return client.request("GET", f"/v1/files/{segment(args.item_id)}/versions")
        if action == "shared":
            return client.request("GET", "/v1/shared-files")
        if action == "mkdir":
            return client.request("POST", f"/v1/spaces/{segment(args.space_id)}/folders", body={"parent_folder_id": args.parent_folder_id, "name": args.name}, idempotent=True)
        if action == "rename":
            return client.request("PATCH", f"/v1/file-items/{segment(args.item_id)}", body={"name": args.name, "expected_metadata_version": args.expected_metadata_version}, idempotent=True)
        if action == "upload":
            return upload_file(client, args.space_id, args.parent_folder_id, Path(args.path), args.name)
        return download_file(client, args.file_id, Path(args.path), args.version_id)
    if group == "notes":
        if action == "list":
            return client.request("GET", f"/v1/spaces/{segment(args.space_id)}/notes")
        if action == "get":
            return client.request("GET", f"/v1/notes/{segment(args.note_id)}")
        if action == "export-markdown":
            return client.text("GET", f"/v1/notes/{segment(args.note_id)}/markdown")
        if action == "create":
            return client.request("POST", f"/v1/spaces/{segment(args.space_id)}/notes", body={"title": args.title, "document": read_object(args.document_json)})
        return client.request("PUT", f"/v1/notes/{segment(args.note_id)}/markdown", body={"expected_revision": args.expected_revision, "markdown": read_text(args.markdown_file)})
    if group == "apps":
        if action == "list":
            return client.request("GET", f"/v1/spaces/{segment(args.space_id)}/apps")
        if action == "get":
            return client.request("GET", f"/v1/apps/{segment(args.app_id)}")
        if action == "tables":
            return client.request("GET", f"/v1/apps/{segment(args.app_id)}/tables")
        if action == "create":
            return client.request("POST", f"/v1/spaces/{segment(args.space_id)}/apps", body={"name": args.name, "manifest": read_object(args.manifest_json)})
        if action == "manifest":
            if not args.confirm:
                raise CliError("CONFIRM_REQUIRED")
            return client.request("PUT", f"/v1/apps/{segment(args.app_id)}/manifest", body={"expected_version": args.expected_version, "manifest": read_object(args.manifest_json)})
        base = f"/v1/apps/{segment(args.app_id)}/tables/{segment(args.table_name)}/records"
        if args.subaction == "list":
            return client.request("GET", base)
        if args.subaction == "query":
            return client.request("POST", base + "/query", body=read_object(args.json_file))
        if args.subaction == "get":
            return client.request("GET", base + f"/{segment(args.record_id)}")
        if args.subaction == "create":
            return client.request("POST", base, body={"values": read_object(args.json_file)})
        return client.request("PATCH", base + f"/{segment(args.record_id)}", body={"expected_row_version": args.expected_row_version, "values": read_object(args.json_file)})
    raise CliError("COMMAND_INVALID")


def main(argv=None) -> int:
    try:
        args = build_parser().parse_args(argv)
        config = Config()
        if args.group == "env":
            result = {"environments": config.list()} if args.action == "list" else {"environment": args.name, "origin": config.set(args.name, args.origin)}
        else:
            name = config._name(args.env)
            origin = config.resolve(name)
            client = VesselClient(name, origin, CredentialStore())
            try:
                result = dispatch(args, client)
            finally:
                client.close()
        print(json.dumps({"ok": True, **result}, ensure_ascii=False))
        return 0
    except CliError as exc:
        print(json.dumps({"ok": False, "error": {"code": exc.code, **({"status": exc.status} if exc.status is not None else {})}}), file=sys.stderr)
        return 1
    except OSError:
        print(json.dumps({"ok": False, "error": {"code": "FILE_IO_ERROR"}}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
