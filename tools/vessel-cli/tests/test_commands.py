import argparse
import json

import pytest

from vessel_cli.cli import build_parser, dispatch, main
from vessel_cli.config import CliError


class FakeClient:
    environment = "local"
    def __init__(self):
        self.calls = []
    def request(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        return {"ok": True}


def run(client, *argv):
    return dispatch(build_parser().parse_args(argv), client)


def test_help_documents_every_command_and_argument():
    parser = build_parser()
    root_help = parser.format_help()
    assert "configure and list named API environments" in root_help
    assert "browse and manage files and folders" in root_help
    assert "Results are JSON" in root_help
    assert "manifest apply requires it in every environment" in root_help

    def check_parser(current):
        for action in current._actions:
            if isinstance(action, argparse._HelpAction):
                continue
            if isinstance(action, argparse._SubParsersAction):
                command_help = {choice.dest: choice.help for choice in action._choices_actions}
                for subparser in action.choices.values():
                    assert subparser.description, subparser.prog
                    assert command_help[subparser.prog.rsplit(" ", 1)[-1]], subparser.prog
                    check_parser(subparser)
                continue
            assert action.help, f"{current.prog}: {action.dest}"

    check_parser(parser)

    files_parser = parser._subparsers._group_actions[0].choices["files"]
    upload_parser = files_parser._subparsers._group_actions[0].choices["upload"]
    upload_help = upload_parser.format_help()
    assert "local path to the file to upload" in upload_help
    assert "parent folder ID" in upload_help
    assert "required when --env production" in upload_help
    list_help = files_parser._subparsers._group_actions[0].choices["list"].format_help()
    assert "defaults to the space's root folder" in list_help

    notes_parser = parser._subparsers._group_actions[0].choices["notes"]
    update_note = notes_parser._subparsers._group_actions[0].choices["update-markdown"]
    assert "current note revision" in update_note.format_help()

    apps_parser = parser._subparsers._group_actions[0].choices["apps"]
    manifest_parser = apps_parser._subparsers._group_actions[0].choices["manifest"]
    manifest_apply = manifest_parser._subparsers._group_actions[0].choices["apply"]
    manifest_help = " ".join(manifest_apply.format_help().split())
    assert "required in every environment" in manifest_help
    records_parser = apps_parser._subparsers._group_actions[0].choices["records"]
    update_record = records_parser._subparsers._group_actions[0].choices["update"]
    assert "current row version" in update_record.format_help()


def test_spaces_notes_and_records_use_exact_paths(tmp_path):
    client = FakeClient()
    data = tmp_path / "record.json"
    data.write_text('{"name":"Ada"}', encoding="utf-8")
    assert run(client, "spaces", "list") == {"ok": True}
    run(client, "notes", "list", "space-1")
    run(client, "apps", "records", "create", "app-1", "contacts", str(data))
    assert client.calls == [
        ("GET", "/v1/spaces", {}),
        ("GET", "/v1/spaces/space-1/notes", {}),
        ("POST", "/v1/apps/app-1/tables/contacts/records", {"body": {"values": {"name": "Ada"}}}),
    ]


def test_versioned_mutations_and_production_confirmation(tmp_path):
    client = FakeClient()
    content = tmp_path / "page.md"
    content.write_text("# Hi\n", encoding="utf-8")
    with pytest.raises(CliError, match="CLI_ARGUMENTS_INVALID"):
        build_parser().parse_args(["notes", "update-markdown", "page-1", str(content)])
    run(client, "notes", "update-markdown", "page-1", str(content), "--expected-revision", "2")
    assert client.calls[-1][2]["body"] == {"markdown": "# Hi\n", "expected_revision": 2}
    client.environment = "production"
    with pytest.raises(CliError, match="CONFIRM_REQUIRED"):
        run(client, "notes", "update-markdown", "page-1", str(content), "--expected-revision", "2")
    run(client, "notes", "update-markdown", "page-1", str(content), "--expected-revision", "2", "--confirm")


def test_rejects_non_object_json_for_record(tmp_path):
    data = tmp_path / "list.json"
    data.write_text("[]", encoding="utf-8")
    with pytest.raises(CliError, match="JSON_OBJECT_REQUIRED"):
        run(FakeClient(), "apps", "records", "create", "app-1", "contacts", str(data))


def test_argument_errors_use_json_error_contract(capsys):
    assert main(["notes", "update-markdown", "page-1", "note.md"]) == 1

    captured = capsys.readouterr()
    assert captured.out == ""
    assert json.loads(captured.err) == {"ok": False, "error": {"code": "CLI_ARGUMENTS_INVALID"}}
