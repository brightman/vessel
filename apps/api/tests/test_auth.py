import json
import asyncio

import httpx
import jwt

from vessel_service.main import create_app
from vessel_service.settings import Settings


def register(api):
    return api(
        "POST",
        "/v1/auth/register",
        json={
            "name": "Notes User",
            "email": "notes.user@example.test",
            "password": "notes-demo-2026",
        },
    )


def test_registration_creates_a_session_without_returning_refresh_token(api_factory) -> None:
    api = api_factory()

    response = register(api)

    assert response.status_code == 201
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 900
    assert body["user"]["email"] == "notes.user@example.test"
    assert body["access_token"]
    assert jwt.decode(body["access_token"], options={"verify_signature": False})["aud"] == "vessel-api"
    assert "refresh_token" not in body
    assert "vessel_refresh" in response.cookies
    cookie = response.headers["set-cookie"].lower()
    assert "httponly" in cookie
    assert "samesite=lax" in cookie


def test_registration_is_disabled_by_default_and_returns_stable_error(api_factory) -> None:
    api = api_factory(allow_registration=False)

    response = register(api)

    assert response.status_code == 403
    assert response.json() == {"detail": {"code": "REGISTRATION_DISABLED"}}


def test_auth_options_disclose_registration_without_exposing_secrets(api_factory) -> None:
    disabled = api_factory(allow_registration=False)
    enabled = api_factory(allow_registration=True)

    assert disabled("GET", "/v1/auth/options").json() == {"registration_enabled": False, "registration_email_verification_required": False, "registration_email_resend_seconds": 60}
    assert enabled("GET", "/v1/auth/options").json() == {"registration_enabled": True, "registration_email_verification_required": False, "registration_email_resend_seconds": 60}


def test_duplicate_registration_returns_conflict(api_factory) -> None:
    api = api_factory()
    register(api)

    duplicate = register(api)

    assert duplicate.status_code == 409
    assert duplicate.json() == {"detail": {"code": "EMAIL_ALREADY_REGISTERED"}}


def test_login_does_not_disclose_whether_email_exists(api_factory) -> None:
    api = api_factory()
    register(api)

    unknown_user = api(
        "POST",
        "/v1/auth/login",
        json={"email": "missing@example.test", "password": "wrong-password"},
    )
    wrong_password = api(
        "POST",
        "/v1/auth/login",
        json={"email": "notes.user@example.test", "password": "wrong-password"},
    )

    assert unknown_user.status_code == wrong_password.status_code == 401
    assert unknown_user.json() == wrong_password.json() == {
        "detail": {"code": "INVALID_CREDENTIALS"}
    }


def test_access_token_authenticates_current_user(api_factory) -> None:
    api = api_factory()
    created = register(api)
    access_token = created.json()["access_token"]

    response = api(
        "GET", "/v1/auth/me", headers={"Authorization": f"Bearer {access_token}"}
    )

    assert response.status_code == 200
    assert response.json()["user"] == created.json()["user"]


def test_current_user_rejects_an_invalid_access_token(api_factory) -> None:
    api = api_factory()

    response = api(
        "GET", "/v1/auth/me", headers={"Authorization": "Bearer not-a-jwt"}
    )

    assert response.status_code == 401
    assert response.json() == {"detail": {"code": "INVALID_ACCESS_TOKEN"}}


def test_refresh_rotates_cookie_and_rejects_replay(api_factory) -> None:
    api = api_factory()
    created = register(api)
    old_cookie = created.cookies.get("vessel_refresh")
    assert old_cookie

    refreshed = api("POST", "/v1/auth/refresh", cookies={"vessel_refresh": old_cookie})
    replayed = api("POST", "/v1/auth/refresh", cookies={"vessel_refresh": old_cookie})

    assert refreshed.status_code == 200
    assert refreshed.cookies.get("vessel_refresh") != old_cookie
    assert replayed.status_code == 401
    assert replayed.json() == {"detail": {"code": "INVALID_REFRESH_TOKEN"}}


def test_logout_revokes_refresh_session_and_returns_no_content(api_factory) -> None:
    api = api_factory()
    created = register(api)
    cookie = created.cookies.get("vessel_refresh")
    assert cookie

    response = api("POST", "/v1/auth/logout", cookies={"vessel_refresh": cookie})
    replayed = api("POST", "/v1/auth/refresh", cookies={"vessel_refresh": cookie})

    assert response.status_code == 204
    assert replayed.status_code == 401


def test_jwks_publishes_only_public_ed25519_material(api_factory) -> None:
    api = api_factory()

    response = api("GET", "/.well-known/jwks.json")

    assert response.status_code == 200
    body = response.json()
    assert len(body["keys"]) == 1
    key = body["keys"][0]
    assert key["kty"] == "OKP"
    assert key["crv"] == "Ed25519"
    assert key["alg"] == "EdDSA"
    assert key["kid"] == "test-key"
    assert "d" not in key
    json.dumps(body)


def test_development_app_has_ephemeral_signing_key_without_key_file() -> None:
    application = create_app(Settings(environment="development"))

    async def request_jwks() -> httpx.Response:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://notes.test"
        ) as client:
            return await client.get("/.well-known/jwks.json")

    response = asyncio.run(request_jwks())

    assert response.status_code == 200
    assert response.json()["keys"][0]["alg"] == "EdDSA"
