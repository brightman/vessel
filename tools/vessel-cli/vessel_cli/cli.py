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
    parser = CliArgumentParser(prog="vessel", description="Vessel CLI for coding agents")
    parser.add_argument("--env", choices=("local", "test", "staging", "production"))
    groups = parser.add_subparsers(dest="group", required=True, parser_class=CliArgumentParser)

    env = groups.add_parser("env")
    envs = env.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    envs.add_parser("list")
    setting = envs.add_parser("set")
    setting.add_argument("name", choices=("local", "test", "staging", "production"))
    setting.add_argument("origin")

    auth = groups.add_parser("auth")
    auths = auth.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    login = auths.add_parser("login")
    login.add_argument("--email", required=True)
    auths.add_parser("whoami")
    auths.add_parser("logout")

    spaces = groups.add_parser("spaces")
    ss = spaces.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    ss.add_parser("list")
    sp = ss.add_parser("permissions")
    sp.add_argument("space_id")

    files = groups.add_parser("files")
    fs = files.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    for name in ("root", "list", "search"):
        cmd = fs.add_parser(name)
        cmd.add_argument("space_id")
        if name == "list":
            cmd.add_argument("--parent")
        if name == "search":
            cmd.add_argument("--name", required=True)
    for name in ("get", "versions"):
        fs.add_parser(name).add_argument("item_id")
    fs.add_parser("shared")
    mkdir = fs.add_parser("mkdir")
    mkdir.add_argument("space_id")
    mkdir.add_argument("parent_folder_id")
    mkdir.add_argument("name")
    rename = fs.add_parser("rename")
    rename.add_argument("item_id")
    rename.add_argument("name")
    rename.add_argument("--expected-metadata-version", type=int, required=True)
    upload = fs.add_parser("upload")
    upload.add_argument("space_id")
    upload.add_argument("parent_folder_id")
    upload.add_argument("path")
    upload.add_argument("--name")
    download = fs.add_parser("download")
    download.add_argument("file_id")
    download.add_argument("path")
    download.add_argument("--version-id")

    pages = groups.add_parser("pages")
    ps = pages.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    ps.add_parser("list").add_argument("space_id")
    for name in ("get", "export-markdown"):
        ps.add_parser(name).add_argument("page_id")
    page_create = ps.add_parser("create")
    page_create.add_argument("space_id")
    page_create.add_argument("title")
    page_create.add_argument("document_json")
    page_update = ps.add_parser("update-markdown")
    page_update.add_argument("page_id")
    page_update.add_argument("markdown_file")
    page_update.add_argument("--expected-revision", type=int, required=True)

    apps = groups.add_parser("apps")
    aps = apps.add_subparsers(dest="action", required=True, parser_class=CliArgumentParser)
    aps.add_parser("list").add_argument("space_id")
    aps.add_parser("get").add_argument("app_id")
    aps.add_parser("tables").add_argument("app_id")
    create_app = aps.add_parser("create")
    create_app.add_argument("space_id")
    create_app.add_argument("name")
    create_app.add_argument("manifest_json")
    manifest = aps.add_parser("manifest")
    ms = manifest.add_subparsers(dest="subaction", required=True, parser_class=CliArgumentParser)
    apply = ms.add_parser("apply")
    apply.add_argument("app_id")
    apply.add_argument("manifest_json")
    apply.add_argument("--expected-version", type=int, required=True)
    records = aps.add_parser("records")
    rs = records.add_subparsers(dest="subaction", required=True, parser_class=CliArgumentParser)
    for name in ("list", "query", "get", "create", "update"):
        cmd = rs.add_parser(name)
        cmd.add_argument("app_id")
        cmd.add_argument("table_name")
        if name in {"get", "update"}:
            cmd.add_argument("record_id")
        if name in {"query", "create", "update"}:
            cmd.add_argument("json_file")
        if name == "update":
            cmd.add_argument("--expected-row-version", type=int, required=True)

    # A confirmation flag is accepted only on mutation leaves.
    for group in (fs, ps, aps, ms, rs):
        for action in group.choices.values():
            if action.prog.split()[-1] in {"mkdir", "rename", "upload", "create", "update-markdown", "apply", "update"}:
                action.add_argument("--confirm", action="store_true")
    def add_leaf_environment(node):
        for item in node._actions:
            if isinstance(item, argparse._SubParsersAction):
                for child in item.choices.values():
                    if any(isinstance(action, argparse._SubParsersAction) for action in child._actions):
                        add_leaf_environment(child)
                    elif child.prog.split()[1] != "env":
                        child.add_argument("--env", choices=("local", "test", "staging", "production"), default=argparse.SUPPRESS)
    add_leaf_environment(parser)
    return parser


def dispatch(args, client):
    group, action = args.group, args.action
    if group == "auth":
        if action == "login":
            return client.login(args.email, getpass.getpass("Vessel password: "))
        if action == "logout":
            return client.logout()
        return client.request("GET", "/v1/auth/me")
    if group == "spaces":
        return client.request("GET", "/v1/spaces" if action == "list" else f"/v1/spaces/{segment(args.space_id)}/permissions")
    writing = (group == "files" and action in {"mkdir", "rename", "upload"}) or (group == "pages" and action in {"create", "update-markdown"}) or (group == "apps" and (action in {"create", "manifest"} or action == "records" and args.subaction in {"create", "update"}))
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
    if group == "pages":
        if action == "list":
            return client.request("GET", f"/v1/spaces/{segment(args.space_id)}/pages")
        if action == "get":
            return client.request("GET", f"/v1/pages/{segment(args.page_id)}")
        if action == "export-markdown":
            return client.text("GET", f"/v1/pages/{segment(args.page_id)}/markdown")
        if action == "create":
            return client.request("POST", f"/v1/spaces/{segment(args.space_id)}/pages", body={"title": args.title, "document": read_object(args.document_json)})
        return client.request("PUT", f"/v1/pages/{segment(args.page_id)}/markdown", body={"expected_revision": args.expected_revision, "markdown": read_text(args.markdown_file)})
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
