"""Real HTTP smoke for Vessel Page/App team authorization on isolated PostgreSQL."""

import asyncio
import sys
from uuid import uuid4

import httpx


def main(base_url: str) -> None:
    marker = uuid4().hex[:12]
    with httpx.Client(base_url=base_url, timeout=10) as client:
        def register(role: str):
            result = client.post("/v1/auth/register", json={
                "name": role, "email": f"{role}-{marker}@example.test", "password": "vessel-e2e-2026",
            })
            assert result.status_code == 201, result.text
            body = result.json()
            return {"Authorization": f"Bearer {body['access_token']}"}, body["user"]["user_id"]

        owner, _ = register("owner")
        editor, editor_id = register("editor")
        viewer, viewer_id = register("viewer")
        outsider, _ = register("outsider")
        team = client.post("/v1/teams", headers=owner, json={"name": "E2E Team"})
        assert team.status_code == 201, team.text
        space_id = team.json()["space"]["space_id"]
        for headers, user_id, role in ((editor, editor_id, "editor"), (viewer, viewer_id, "viewer")):
            invite = client.post(f"/v1/teams/{space_id}/invitations", headers=owner,
                                 json={"invitee_user_id": user_id, "role": role})
            assert invite.status_code == 201, invite.text
            accepted = client.post(f"/v1/team-invitations/{invite.json()['invitation']['invitation_id']}/accept", headers=headers)
            assert accepted.status_code == 200, accepted.text

        document = {"type": "doc", "schema_version": 1, "content": [{
            "type": "paragraph", "attrs": {"block_id": "intro"},
            "content": [{"type": "text", "text": "Shared"}],
        }]}
        page = client.post(f"/v1/spaces/{space_id}/pages", headers=owner,
                           json={"title": "E2E note", "document": document})
        assert page.status_code == 201, page.text
        page_id = page.json()["page"]["page_id"]
        assert client.get(f"/v1/pages/{page_id}", headers=viewer).status_code == 200
        assert client.get(f"/v1/pages/{page_id}", headers=outsider).status_code == 404
        assert client.patch(f"/v1/pages/{page_id}", headers=viewer,
                            json={"expected_revision": 1, "title": "Denied"}).status_code == 403
        edited = client.patch(f"/v1/pages/{page_id}", headers=editor,
                              json={"expected_revision": 1, "title": "Edited"})
        assert edited.status_code == 200, edited.text
        assert edited.json()["page"]["revision"] == 2

        app = client.post(f"/v1/spaces/{space_id}/apps", headers=owner, json={
            "name": "E2E table", "manifest": {"tables": {"leads": {"fields": {
                "company": {"type": "text", "nullable": False},
                "score": {"type": "integer", "nullable": True},
            }}}},
        })
        assert app.status_code == 201, app.text
        app_id = app.json()["app"]["app_id"]
        records = f"/v1/apps/{app_id}/tables/leads/records"
        assert client.get(f"/v1/apps/{app_id}", headers=viewer).status_code == 200
        assert client.get(f"/v1/apps/{app_id}", headers=outsider).status_code == 404
        assert client.post(records, headers=viewer, json={"values": {"company": "Denied"}}).status_code == 403
        row = client.post(records, headers=editor, json={"values": {"company": "Acme", "score": 8}})
        assert row.status_code == 201, row.text
        record_id = row.json()["record"]["id"]
        assert client.post(records, headers=editor, json={
            "values": {"company": "Too large", "score": 2_147_483_648},
        }).status_code == 422
        queried = client.post(f"{records}/query", headers=viewer,
                              json={"filter": {"field": "score", "op": "gte", "value": 7}})
        assert queried.status_code == 200, queried.text
        assert [item["id"] for item in queried.json()["records"]] == [record_id]
        extra = client.post(f"{records}/bulk", headers=editor, json={"records": [
            {"values": {"company": name, "score": score}}
            for name, score in (("B", 1), ("C", 2), ("D", 3))
        ]})
        assert extra.status_code == 201, extra.text
        first_page = client.get(f"{records}?limit=2", headers=viewer).json()
        assert [item["values"]["company"] for item in first_page["records"]] == ["Acme", "B"]
        removed_id = extra.json()["records"][0]["id"]
        assert client.request("DELETE", f"{records}/{removed_id}", headers=editor,
                              json={"expected_row_version": 1}).status_code == 204
        later_page = client.get(f"{records}?limit=2&cursor={first_page['next_cursor']}", headers=viewer).json()
        assert [item["values"]["company"] for item in later_page["records"]] == ["C", "D"]
        ranked = client.post(f"{records}/query", headers=viewer, json={
            "sort": [{"field": "score", "direction": "desc"}], "limit": 2,
        }).json()
        ranked_next = client.post(f"{records}/query", headers=viewer, json={
            "sort": [{"field": "score", "direction": "desc"}], "limit": 2,
            "cursor": ranked["next_cursor"],
        }).json()
        assert [item["values"]["company"] for item in ranked["records"] + ranked_next["records"]] == ["Acme", "D", "C"]

        numeric_app = client.post(f"/v1/spaces/{space_id}/apps", headers=owner, json={
            "name": "Amounts", "manifest": {"tables": {"items": {"fields": {
                "amount": {"type": "numeric", "nullable": False},
            }}}},
        })
        assert numeric_app.status_code == 201, numeric_app.text
        amounts = f"/v1/apps/{numeric_app.json()['app']['app_id']}/tables/items/records"
        assert client.post(amounts, headers=editor, json={"values": {"amount": "1e1000"}}).status_code == 422
        amount = client.post(amounts, headers=editor, json={"values": {"amount": "1.25"}})
        assert amount.status_code == 201, amount.text
        filtered_amounts = client.post(f"{amounts}/query", headers=viewer, json={
            "filter": {"field": "amount", "op": "gte", "value": "1"},
        })
        assert filtered_amounts.status_code == 200, filtered_amounts.text
        assert [item["id"] for item in filtered_amounts.json()["records"]] == [amount.json()["record"]["id"]]

        async def downgrade_during_upload():
            first_chunk = asyncio.Event()
            continue_upload = asyncio.Event()

            async def image_stream():
                yield b"\x89PNG\r\n\x1a\n"
                first_chunk.set()
                await continue_upload.wait()
                yield b"image-content"

            async with httpx.AsyncClient(base_url=base_url, timeout=5) as concurrent:
                upload = asyncio.create_task(concurrent.post(
                    f"/v1/pages/{page_id}/assets", headers={**editor, "Content-Type": "image/png"},
                    content=image_stream(),
                ))
                try:
                    await asyncio.wait_for(first_chunk.wait(), 3)
                    changed = await asyncio.wait_for(concurrent.patch(
                        f"/v1/teams/{space_id}/members/{editor_id}", headers=owner,
                        json={"role": "viewer"},
                    ), 3)
                finally:
                    continue_upload.set()
                uploaded = await upload
                assert uploaded.status_code == 403, uploaded.text
                return changed

        changed = asyncio.run(downgrade_during_upload())
        assert changed.status_code == 200, changed.text
        assert client.patch(f"/v1/pages/{page_id}", headers=editor,
                            json={"expected_revision": 2, "title": "Denied"}).status_code == 403
        assert client.post(records, headers=editor, json={"values": {"company": "Denied"}}).status_code == 403
        assert client.delete(f"/v1/teams/{space_id}/members/{editor_id}", headers=owner).status_code == 204
        assert client.get(f"/v1/pages/{page_id}", headers=editor).status_code == 404
        assert client.get(f"{records}/{record_id}", headers=editor).status_code == 404
        assert client.get(f"/v1/pages/{page_id}/agent/status", headers=owner).status_code == 404
        print("PASS real HTTP: register, team invite, Page/App read-write, numeric query, deletion-safe cursor, slow upload revocation, role downgrade, removal")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: space_resources_http_e2e.py <base-url>")
    main(sys.argv[1])
