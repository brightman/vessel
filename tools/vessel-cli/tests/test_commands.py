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


def test_spaces_pages_and_records_use_exact_paths(tmp_path):
    client = FakeClient()
    data = tmp_path / "record.json"
    data.write_text('{"name":"Ada"}', encoding="utf-8")
    assert run(client, "spaces", "list") == {"ok": True}
    run(client, "pages", "list", "space-1")
    run(client, "apps", "records", "create", "app-1", "contacts", str(data))
    assert client.calls == [
        ("GET", "/v1/spaces", {}),
        ("GET", "/v1/spaces/space-1/pages", {}),
        ("POST", "/v1/apps/app-1/tables/contacts/records", {"body": {"values": {"name": "Ada"}}}),
    ]


def test_versioned_mutations_and_production_confirmation(tmp_path):
    client = FakeClient()
    content = tmp_path / "page.md"
    content.write_text("# Hi\n", encoding="utf-8")
    with pytest.raises(CliError, match="CLI_ARGUMENTS_INVALID"):
        build_parser().parse_args(["pages", "update-markdown", "page-1", str(content)])
    run(client, "pages", "update-markdown", "page-1", str(content), "--expected-revision", "2")
    assert client.calls[-1][2]["body"] == {"markdown": "# Hi\n", "expected_revision": 2}
    client.environment = "production"
    with pytest.raises(CliError, match="CONFIRM_REQUIRED"):
        run(client, "pages", "update-markdown", "page-1", str(content), "--expected-revision", "2")
    run(client, "pages", "update-markdown", "page-1", str(content), "--expected-revision", "2", "--confirm")


def test_rejects_non_object_json_for_record(tmp_path):
    data = tmp_path / "list.json"
    data.write_text("[]", encoding="utf-8")
    with pytest.raises(CliError, match="JSON_OBJECT_REQUIRED"):
        run(FakeClient(), "apps", "records", "create", "app-1", "contacts", str(data))


def test_argument_errors_use_json_error_contract(capsys):
    assert main(["pages", "update-markdown", "page-1", "note.md"]) == 1

    captured = capsys.readouterr()
    assert captured.out == ""
    assert json.loads(captured.err) == {"ok": False, "error": {"code": "CLI_ARGUMENTS_INVALID"}}
