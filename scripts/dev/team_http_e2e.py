"""Exercise Vessel team authorization against a running local HTTP server."""

import sys
from uuid import uuid4

import httpx


def main(base_url: str) -> None:
    suffix = uuid4().hex[:10]
    password = "vessel-team-e2e-2026"
    with httpx.Client(base_url=base_url, timeout=10) as client:
        def register(name: str) -> tuple[str, str]:
            response = client.post(
                "/v1/auth/register",
                json={"name": name, "email": f"{name}-{suffix}@example.test", "password": password},
            )
            assert response.status_code == 201, response.text
            return response.json()["access_token"], response.json()["user"]["user_id"]

        owner_token, owner_id = register("owner")
        viewer_token, viewer_id = register("viewer")
        outsider_token, outsider_id = register("outsider")
        owner = {"Authorization": f"Bearer {owner_token}"}
        viewer = {"Authorization": f"Bearer {viewer_token}"}
        outsider = {"Authorization": f"Bearer {outsider_token}"}

        owner_spaces = client.get("/v1/spaces", headers=owner)
        assert owner_spaces.status_code == 200
        assert len(owner_spaces.json()["spaces"]) == 1
        assert owner_spaces.json()["spaces"][0]["kind"] == "personal"

        created = client.post("/v1/teams", headers=owner, json={"name": "E2E Team"})
        assert created.status_code == 201, created.text
        team_id = created.json()["space"]["space_id"]
        assert client.get(f"/v1/teams/{team_id}", headers=outsider).status_code == 404

        invited = client.post(
            f"/v1/teams/{team_id}/invitations", headers=owner,
            json={"invitee_user_id": viewer_id, "role": "viewer"},
        )
        assert invited.status_code == 201, invited.text
        invitation_id = invited.json()["invitation"]["invitation_id"]
        assert client.post(f"/v1/team-invitations/{invitation_id}/accept", headers=outsider).status_code == 404
        accepted = client.post(f"/v1/team-invitations/{invitation_id}/accept", headers=viewer)
        assert accepted.status_code == 200, accepted.text
        permissions = client.get(f"/v1/spaces/{team_id}/permissions", headers=viewer)
        assert permissions.status_code == 200
        assert permissions.json()["can_read"] is True
        assert permissions.json()["can_write"] is False
        assert client.get(f"/v1/teams/{team_id}/members", headers=viewer).status_code == 200

        promoted = client.patch(
            f"/v1/teams/{team_id}/members/{viewer_id}", headers=owner, json={"role": "editor"}
        )
        assert promoted.status_code == 200, promoted.text
        assert client.get(f"/v1/spaces/{team_id}/permissions", headers=viewer).json()["can_write"] is True
        denied = client.patch(
            f"/v1/teams/{team_id}/members/{owner_id}", headers=viewer, json={"role": "viewer"}
        )
        assert denied.status_code == 403, denied.text

        removed = client.delete(f"/v1/teams/{team_id}/members/{viewer_id}", headers=owner)
        assert removed.status_code == 204, removed.text
        assert client.get(f"/v1/spaces/{team_id}/permissions", headers=viewer).status_code == 404
        assert client.get(f"/v1/teams/{team_id}/members", headers=viewer).status_code == 404

        pending = client.post(
            f"/v1/teams/{team_id}/invitations", headers=owner,
            json={"invitee_user_id": outsider_id, "role": "viewer"},
        )
        assert pending.status_code == 201, pending.text
        pending_id = pending.json()["invitation"]["invitation_id"]
        listed = client.get(f"/v1/teams/{team_id}/invitations", headers=owner)
        assert listed.status_code == 200
        assert pending_id in {item["invitation_id"] for item in listed.json()["invitations"]}
        assert client.delete(
            f"/v1/teams/{team_id}/invitations/{pending_id}", headers=owner
        ).status_code == 204
        assert client.post(
            f"/v1/team-invitations/{pending_id}/accept", headers=outsider
        ).status_code == 409

    print("personal=200 team=201 invite=201 accept=200 viewer_read=200 viewer_write=false promote=200 remove=204 revoked_read=404 outsider=404 invite_revoke=204")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/dev/team_http_e2e.py http://127.0.0.1:PORT")
    main(sys.argv[1])
