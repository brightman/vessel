from typing import Any

def register(api, email: str) -> str:
    response = api(
        "POST",
        "/v1/auth/register",
        json={"name": "Page Owner", "email": email, "password": "pages-demo-2026"},
    )
    assert response.status_code == 201
    return response.json()["access_token"]


def authorized(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def document(text: str = "Hello Pages") -> dict[str, Any]:
    return {
        "type": "doc",
        "schema_version": 1,
        "content": [
            {
                "type": "paragraph",
                "attrs": {"block_id": "block_first"},
                "content": [{"type": "text", "text": text}],
            }
        ],
    }


def test_user_can_create_list_read_and_update_their_page(api_factory) -> None:
    api = api_factory()
    token = register(api, "owner@example.test")
    headers = authorized(token)

    created = api(
        "POST",
        "/v1/pages",
        headers=headers,
        json={"title": "First Page", "document": document()},
    )
    assert created.status_code == 201
    page = created.json()["page"]
    listed = api("GET", "/v1/pages", headers=headers)
    read = api("GET", f"/v1/pages/{page['page_id']}", headers=headers)
    updated = api(
        "PATCH",
        f"/v1/pages/{page['page_id']}",
        headers=headers,
        json={"expected_revision": 1, "title": "Renamed", "document": document("Updated")},
    )

    assert page["title"] == "First Page"
    assert page["revision"] == 1
    assert "Hello Pages" in page["markdown"]
    assert [entry["page_id"] for entry in listed.json()["pages"]] == [page["page_id"]]
    assert read.json()["page"]["document"] == document()
    assert updated.status_code == 200
    assert updated.json()["page"]["revision"] == 2
    assert updated.json()["page"]["title"] == "Renamed"
    assert "Updated" in updated.json()["page"]["markdown"]


def test_page_access_is_scoped_to_authenticated_owner(api_factory) -> None:
    api = api_factory()
    owner_token = register(api, "owner@example.test")
    other_token = register(api, "other@example.test")
    created = api(
        "POST",
        "/v1/pages",
        headers=authorized(owner_token),
        json={"title": "Private", "document": document()},
    )
    assert created.status_code == 201
    page_id = created.json()["page"]["page_id"]

    detail = api("GET", f"/v1/pages/{page_id}", headers=authorized(other_token))
    listing = api("GET", "/v1/pages", headers=authorized(other_token))

    assert detail.status_code == 404
    assert detail.json() == {"detail": {"code": "PAGE_NOT_FOUND"}}
    assert listing.status_code == 200
    assert listing.json()["pages"] == []


def test_stale_page_revision_cannot_overwrite_newer_content(api_factory) -> None:
    api = api_factory()
    token = register(api, "owner@example.test")
    headers = authorized(token)
    created = api(
        "POST",
        "/v1/pages",
        headers=headers,
        json={"title": "First Page", "document": document()},
    )
    assert created.status_code == 201
    page_id = created.json()["page"]["page_id"]
    api(
        "PATCH",
        f"/v1/pages/{page_id}",
        headers=headers,
        json={"expected_revision": 1, "document": document("Latest")},
    )

    stale = api(
        "PATCH",
        f"/v1/pages/{page_id}",
        headers=headers,
        json={"expected_revision": 1, "document": document("Stale")},
    )

    assert stale.status_code == 409
    assert stale.json() == {"detail": {"code": "PAGE_REVISION_CONFLICT"}}
    current = api("GET", f"/v1/pages/{page_id}", headers=headers).json()["page"]
    assert current["revision"] == 2
    assert "Latest" in current["markdown"]


def test_page_write_requires_authentication(api_factory) -> None:
    api = api_factory()

    response = api("POST", "/v1/pages", json={"title": "No owner", "document": document()})

    assert response.status_code == 401


def test_user_can_create_list_rename_and_archive_directories(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "directory-owner@example.test"))

    created = api("POST", "/v1/directories", headers=headers, json={"name": "Research"})
    assert created.status_code == 201
    directory = created.json()["directory"]
    page = api(
        "POST",
        "/v1/pages",
        headers=headers,
        json={
            "title": "Filed note",
            "document": document(),
            "directory_id": directory["directory_id"],
        },
    )
    assert page.status_code == 201
    assert page.json()["page"]["directory_id"] == directory["directory_id"]
    listed = api("GET", "/v1/directories", headers=headers)
    renamed = api(
        "PATCH",
        f"/v1/directories/{directory['directory_id']}",
        headers=headers,
        json={"name": "Market research"},
    )
    archived = api("POST", f"/v1/directories/{directory['directory_id']}/archive", headers=headers)

    assert directory["name"] == "Research"
    assert listed.json()["directories"] == [directory]
    assert renamed.status_code == 200
    assert renamed.json()["directory"]["name"] == "Market research"
    assert archived.status_code == 204
    assert api("GET", "/v1/directories", headers=headers).json()["directories"] == []
    assert api(
        "GET", f"/v1/pages/{page.json()['page']['page_id']}", headers=headers
    ).json()["page"]["directory_id"] is None


def test_directory_and_page_assignment_are_scoped_to_authenticated_owner(api_factory) -> None:
    api = api_factory()
    owner_headers = authorized(register(api, "directory-owner@example.test"))
    other_headers = authorized(register(api, "directory-other@example.test"))
    directory = api(
        "POST", "/v1/directories", headers=owner_headers, json={"name": "Private"}
    ).json()["directory"]

    page_create = api(
        "POST",
        "/v1/pages",
        headers=other_headers,
        json={"title": "Cross-owner", "document": document(), "directory_id": directory["directory_id"]},
    )
    other_read = api(
        "GET", f"/v1/directories/{directory['directory_id']}", headers=other_headers
    )
    other_rename = api(
        "PATCH",
        f"/v1/directories/{directory['directory_id']}",
        headers=other_headers,
        json={"name": "Stolen"},
    )

    assert page_create.status_code == 404
    assert page_create.json() == {"detail": {"code": "DIRECTORY_NOT_FOUND"}}
    assert other_read.status_code == 404
    assert other_read.json() == {"detail": {"code": "DIRECTORY_NOT_FOUND"}}
    assert other_rename.status_code == 404
    assert other_rename.json() == {"detail": {"code": "DIRECTORY_NOT_FOUND"}}


def test_page_can_move_between_owned_directories_or_back_to_personal(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "directory-move@example.test"))
    first = api("POST", "/v1/directories", headers=headers, json={"name": "One"}).json()["directory"]
    second = api("POST", "/v1/directories", headers=headers, json={"name": "Two"}).json()["directory"]
    page = api(
        "POST", "/v1/pages", headers=headers,
        json={"title": "Move me", "document": document(), "directory_id": first["directory_id"]},
    ).json()["page"]

    moved = api(
        "PATCH", f"/v1/pages/{page['page_id']}", headers=headers,
        json={"expected_revision": 1, "directory_id": second["directory_id"]},
    )
    personal = api(
        "PATCH", f"/v1/pages/{page['page_id']}", headers=headers,
        json={"expected_revision": 2, "directory_id": None},
    )

    assert moved.status_code == 200
    assert moved.json()["page"]["directory_id"] == second["directory_id"]
    assert moved.json()["page"]["revision"] == 2
    assert personal.status_code == 200
    assert personal.json()["page"]["directory_id"] is None
    assert personal.json()["page"]["revision"] == 3


def test_directory_names_must_not_be_blank(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "directory-name@example.test"))

    response = api("POST", "/v1/directories", headers=headers, json={"name": "   "})

    assert response.status_code == 422


def test_page_checkpoints_are_idempotent_and_listed_in_revision_order(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "page-version@example.test"))
    created = api(
        "POST", "/v1/pages", headers=headers,
        json={"title": "Draft", "document": document("First")},
    ).json()["page"]
    api(
        "PATCH", f"/v1/pages/{created['page_id']}", headers=headers,
        json={"expected_revision": 1, "title": "Draft 2", "document": document("Second")},
    )

    checkpoint = api(
        "POST", f"/v1/pages/{created['page_id']}/versions/checkpoint", headers=headers,
        json={"expected_revision": 2},
    )
    repeated = api(
        "POST", f"/v1/pages/{created['page_id']}/versions/checkpoint", headers=headers,
        json={"expected_revision": 2},
    )
    versions = api("GET", f"/v1/pages/{created['page_id']}/versions", headers=headers)

    assert checkpoint.status_code == 201
    assert repeated.status_code == 200
    assert checkpoint.json()["version"]["version_id"] == repeated.json()["version"]["version_id"]
    assert [version["revision"] for version in versions.json()["versions"]] == [2, 1]
    assert versions.json()["versions"][0]["source"] == "human"


def test_restore_creates_a_new_revision_without_overwriting_history(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "page-restore@example.test"))
    created = api(
        "POST", "/v1/pages", headers=headers,
        json={"title": "Original", "document": document("Original text")},
    ).json()["page"]
    initial_versions = api(
        "GET", f"/v1/pages/{created['page_id']}/versions", headers=headers
    ).json()["versions"]
    api(
        "PATCH", f"/v1/pages/{created['page_id']}", headers=headers,
        json={"expected_revision": 1, "title": "Newer", "document": document("Newer text")},
    )
    checkpoint = api(
        "POST", f"/v1/pages/{created['page_id']}/versions/checkpoint", headers=headers,
        json={"expected_revision": 2},
    ).json()["version"]

    restored = api(
        "POST",
        f"/v1/pages/{created['page_id']}/versions/{initial_versions[0]['version_id']}/restore",
        headers=headers,
        json={"expected_revision": 2},
    )
    assert restored.status_code == 200
    assert restored.json()["page"]["revision"] == 3
    assert restored.json()["page"]["title"] == "Original"
    assert "Original text" in restored.json()["page"]["markdown"]
    assert checkpoint["revision"] == 2
    versions = api("GET", f"/v1/pages/{created['page_id']}/versions", headers=headers)
    assert [(item["revision"], item["source"]) for item in versions.json()["versions"]] == [
        (3, "restore"), (2, "human"), (1, "human")
    ]


def test_page_archive_and_restore_preserve_content(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "page-archive@example.test"))
    created = api(
        "POST", "/v1/pages", headers=headers,
        json={"title": "Keep me", "document": document("Still here")},
    ).json()["page"]

    archived = api("POST", f"/v1/pages/{created['page_id']}/archive", headers=headers)
    listing = api("GET", "/v1/pages", headers=headers)
    archived_listing = api("GET", "/v1/pages/archived", headers=headers)
    restored = api("POST", f"/v1/pages/{created['page_id']}/restore", headers=headers)

    assert archived.status_code == 204
    assert listing.json()["pages"] == []
    assert [page["page_id"] for page in archived_listing.json()["pages"]] == [created["page_id"]]
    assert restored.status_code == 200
    assert restored.json()["page"]["title"] == "Keep me"
    assert "Still here" in restored.json()["page"]["markdown"]


def test_user_can_import_markdown_as_a_new_page_revision_and_export_it(api_factory) -> None:
    api = api_factory()
    headers = authorized(register(api, "markdown-owner@example.test"))
    created = api(
        "POST", "/v1/pages", headers=headers,
        json={"title": "Research", "document": document("Original")},
    ).json()["page"]

    imported = api(
        "PUT", f"/v1/pages/{created['page_id']}/markdown", headers=headers,
        json={
            "expected_revision": 1,
            "markdown": "# Imported research\n\nVerified **finding**.",
        },
    )
    exported = api("GET", f"/v1/pages/{created['page_id']}/markdown", headers=headers)
    versions = api("GET", f"/v1/pages/{created['page_id']}/versions", headers=headers)

    assert imported.status_code == 200
    assert imported.json()["page"]["revision"] == 2
    assert imported.json()["page"]["document"]["content"][0]["type"] == "heading"
    assert "**finding**" in exported.text
    assert exported.headers["content-type"].startswith("text/markdown")
    assert 'attachment; filename="Research.md"' == exported.headers["content-disposition"]
    assert [(item["revision"], item["source"]) for item in versions.json()["versions"]] == [
        (2, "import"), (1, "human"),
    ]


def test_markdown_import_checks_revision_and_owner_scope(api_factory) -> None:
    api = api_factory()
    owner_headers = authorized(register(api, "markdown-owner@example.test"))
    other_headers = authorized(register(api, "markdown-other@example.test"))
    page = api(
        "POST", "/v1/pages", headers=owner_headers,
        json={"title": "Research", "document": document()},
    ).json()["page"]

    stale = api(
        "PUT", f"/v1/pages/{page['page_id']}/markdown", headers=owner_headers,
        json={"expected_revision": 9, "markdown": "New text"},
    )
    foreign = api(
        "PUT", f"/v1/pages/{page['page_id']}/markdown", headers=other_headers,
        json={"expected_revision": 1, "markdown": "Private text"},
    )

    assert stale.status_code == 409
    assert stale.json() == {"detail": {"code": "PAGE_REVISION_CONFLICT"}}
    assert foreign.status_code == 404
    assert foreign.json() == {"detail": {"code": "PAGE_NOT_FOUND"}}
