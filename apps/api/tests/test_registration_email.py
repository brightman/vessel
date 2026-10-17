from datetime import UTC, datetime, timedelta

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import select

from vessel_service.auth.email_verification import BrevoMailer, MailDeliveryError
from vessel_service.models import User
from vessel_service.models.registration_email import RegistrationEmailChallenge, RegistrationEmailLimit
from vessel_service.settings import Settings

EMAIL = "verify@example.test"
SECRET = "isolated-test-code-secret-at-least-32-characters"

class Mailbox:
    def __init__(self):
        self.messages = []
        self.fail = False
    def ensure_configured(self):
        pass
    def send(self, email, code):
        if self.fail:
            raise MailDeliveryError()
        self.messages.append((email, code))
        return "test-message-id"

@pytest.fixture
def verified_api(api_factory):
    box = Mailbox()
    state = {}
    def configure(app):
        app.state.settings.registration_email_verification_required = True
        app.state.settings.registration_code_secret = SecretStr(SECRET)
        app.state.registration_mailer = box
        state["sessions"] = app.state.session_factory
    api = api_factory(configure_application=configure)
    return api, box, state

def send(api, email=EMAIL):
    return api("POST", "/v1/auth/registration/email-code", json={"email": email})

def signup(api, challenge=None, code=None, email=EMAIL):
    return api("POST", "/v1/auth/register", json={"name":"Verified User", "email":email, "password":"vessel-email-test-password", "challenge_id":challenge, "verification_code":code})

def test_code_required_creates_no_account(verified_api):
    api, box, state = verified_api
    assert signup(api).status_code == 422
    assert not box.messages
    with state["sessions"]() as session:
        assert session.scalar(select(User)) is None

def test_code_is_private_and_success_consumes_it_atomically(verified_api):
    api, box, state = verified_api
    response = send(api, " Verify@Example.Test ")
    assert response.status_code == 202
    payload = response.json()
    email, code = box.messages[-1]
    assert email == EMAIL and len(code) == 6 and code.isdecimal()
    assert code not in response.text
    assert payload["expires_in"] == 600 and payload["resend_after"] == 60
    created = signup(api, payload["challenge_id"], code)
    assert created.status_code == 201
    assert created.json()["access_token"] and "vessel_refresh" in created.cookies
    with state["sessions"]() as session:
        user = session.scalar(select(User).where(User.email == EMAIL))
        assert user.email_verified_at is not None
        row = session.get(RegistrationEmailChallenge, payload["challenge_id"])
        assert row.status == "consumed" and row.consumed_at is not None
        assert row.code_digest != code and code not in repr(row.__dict__)
    assert signup(api, payload["challenge_id"], code).status_code == 409

def test_five_wrong_codes_persist_and_lock_challenge(verified_api):
    api, box, state = verified_api
    challenge = send(api).json()["challenge_id"]
    correct = box.messages[-1][1]
    wrong = "000000" if correct != "000000" else "111111"
    for _ in range(5):
        assert signup(api, challenge, wrong).status_code == 422
    assert signup(api, challenge, correct).status_code == 422
    with state["sessions"]() as session:
        assert session.get(RegistrationEmailChallenge, challenge).attempts == 5
        assert session.scalar(select(User)) is None

@pytest.mark.parametrize("kind", ["expired", "wrong-email", "pending", "failed", "consumed", "superseded", "unknown"])
def test_unusable_challenges_cannot_create_user(verified_api, kind):
    api, box, state = verified_api
    challenge = send(api).json()["challenge_id"]
    with state["sessions"]() as session:
        row = session.get(RegistrationEmailChallenge, challenge)
        if kind == "expired": row.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        elif kind not in {"wrong-email", "unknown"}: row.status = kind
        session.commit()
    result = signup(api, "missing" if kind == "unknown" else challenge, box.messages[-1][1], "other@example.test" if kind == "wrong-email" else EMAIL)
    assert result.status_code == 422
    with state["sessions"]() as session:
        assert session.scalar(select(User)) is None

def expire_cooldown(state):
    with state["sessions"]() as session:
        for row in session.scalars(select(RegistrationEmailLimit).where(RegistrationEmailLimit.bucket_key.like("cooldown:%"))):
            row.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.commit()

def test_cooldown_is_server_side_and_successful_resend_supersedes_old_code(verified_api):
    api, box, state = verified_api
    first = send(api).json()["challenge_id"]
    old = box.messages[-1][1]
    limited = send(api)
    assert limited.status_code == 429 and int(limited.headers["retry-after"]) > 0
    assert len(box.messages) == 1
    expire_cooldown(state)
    second = send(api).json()["challenge_id"]
    assert signup(api, first, old).status_code == 422
    assert signup(api, second, box.messages[-1][1]).status_code == 201

def test_provider_failure_keeps_previous_code_valid_and_reservation_limited(verified_api):
    api, box, state = verified_api
    first = send(api).json()["challenge_id"]
    old = box.messages[-1][1]
    expire_cooldown(state)
    box.fail = True
    assert send(api).status_code == 503
    assert send(api).status_code == 429
    assert signup(api, first, old).status_code == 201

@pytest.mark.parametrize("prefix,limit", [("global:",300), ("email-day:",5), ("ip-hour:",20)])
def test_shared_daily_and_source_limits(verified_api, prefix, limit):
    api, box, state = verified_api
    assert send(api).status_code == 202
    expire_cooldown(state)
    with state["sessions"]() as session:
        row = session.scalar(select(RegistrationEmailLimit).where(RegistrationEmailLimit.bucket_key.like(prefix + "%")))
        row.hits = limit
        session.commit()
    assert send(api, "different@example.test" if prefix != "email-day:" else EMAIL).status_code == 429
    assert len(box.messages) == 1

def test_no_key_fails_closed_and_disabled_registration_never_sends(api_factory):
    def configure(app):
        app.state.settings.registration_email_verification_required = True
        app.state.settings.registration_code_secret = SecretStr(SECRET)
    api = api_factory(configure_application=configure)
    assert send(api).status_code == 503
    assert signup(api).status_code == 422
    assert send(api_factory(allow_registration=False)).status_code == 403

def test_email_options_expose_requirements_without_configuration(verified_api):
    api, _, _ = verified_api
    body = api("GET", "/v1/auth/options").json()
    assert body["registration_email_verification_required"] is True
    assert body["registration_email_resend_seconds"] == 60
    assert SECRET not in str(body)

@pytest.mark.parametrize("status", [401, 429, 500])
def test_brevo_errors_are_normalized_without_secret_disclosure(status):
    settings = Settings(brevo_api_key=SecretStr("test-api-key"), brevo_sender_email="sender@example.test")
    mailer = BrevoMailer(settings, transport=httpx.MockTransport(lambda request: httpx.Response(status, json={"message":"test-api-key upstream detail"})))
    with pytest.raises(MailDeliveryError) as result:
        mailer.send(EMAIL, "123456")
    assert "test-api-key" not in str(result.value)

def test_brevo_uses_fixed_transactional_api_and_both_email_bodies():
    def handle(request):
        import json
        assert str(request.url) == "https://api.brevo.com/v3/smtp/email"
        assert request.headers["api-key"] == "test-api-key"
        payload = json.loads(request.content)
        assert payload["sender"]["email"] == "sender@example.test"
        assert payload["to"] == [{"email": EMAIL}]
        assert "123456" in payload["htmlContent"] and "123456" in payload["textContent"]
        return httpx.Response(201, json={"messageId":"provider-accepted-id"})
    mailer = BrevoMailer(Settings(brevo_api_key=SecretStr("test-api-key"), brevo_sender_email="sender@example.test"), transport=httpx.MockTransport(handle))
    assert mailer.send(EMAIL, "123456") == "provider-accepted-id"


def test_provider_timeout_is_not_retried():
    calls = []
    def timeout(request):
        calls.append(request)
        raise httpx.ReadTimeout("provider timeout")
    mailer = BrevoMailer(Settings(brevo_api_key=SecretStr("test-key"), brevo_sender_email="sender@example.test"), transport=httpx.MockTransport(timeout))
    with pytest.raises(MailDeliveryError):
        mailer.send(EMAIL, "123456")
    assert len(calls) == 1


def test_cross_origin_send_and_signup_are_rejected(verified_api):
    api, box, _ = verified_api
    result = api("POST", "/v1/auth/registration/email-code", headers={"Origin":"https://attacker.test"}, json={"email": EMAIL})
    assert result.status_code == 403 and not box.messages
    result = api("POST", "/v1/auth/register", headers={"Origin":"https://attacker.test"}, json={"email":EMAIL, "name":"Test", "password":"test-password"})
    assert result.status_code == 403


def test_configuration_masks_secrets_and_prevents_production_bypass():
    from pydantic import ValidationError
    with pytest.raises(ValidationError, match="requires email verification"):
        Settings(environment="production", allow_registration=True, registration_email_verification_required=False)
    with pytest.raises(ValidationError, match="32 characters"):
        Settings(registration_code_secret=SecretStr("short"))
    with pytest.raises(ValidationError):
        Settings(registration_email_daily_limit=301)
    assert SECRET not in repr(Settings(registration_code_secret=SecretStr(SECRET)))


def test_email_settings_accept_unprefixed_names(monkeypatch):
    unprefixed = {
        "BREVO_API_KEY": "unprefixed-api-key",
        "BREVO_SENDER_EMAIL": "sender@example.test",
        "BREVO_SENDER_NAME": "Karama",
        "BREVO_TIMEOUT_SECONDS": "12",
        "REGISTRATION_CODE_SECRET": SECRET,
        "REGISTRATION_EMAIL_VERIFICATION_REQUIRED": "false",
        "REGISTRATION_EMAIL_DAILY_LIMIT": "123",
    }
    for name, value in unprefixed.items():
        monkeypatch.setenv(name, value)
    settings = Settings(_env_file=None)
    assert settings.brevo_api_key.get_secret_value() == "unprefixed-api-key"
    assert settings.brevo_sender_email == "sender@example.test"
    assert settings.brevo_sender_name == "Karama"
    assert settings.brevo_timeout_seconds == 12
    assert settings.registration_code_secret.get_secret_value() == SECRET
    assert settings.registration_email_verification_required is False
    assert settings.registration_email_daily_limit == 123

    for name in unprefixed:
        monkeypatch.delenv(name)


def test_email_settings_ignore_pages_prefixed_names(monkeypatch):
    legacy = {
        "PAGES_BREVO_API_KEY": "legacy-api-key",
        "PAGES_BREVO_SENDER_EMAIL": "legacy@example.test",
        "PAGES_BREVO_SENDER_NAME": "Legacy",
        "PAGES_BREVO_TIMEOUT_SECONDS": "14",
        "PAGES_REGISTRATION_CODE_SECRET": SECRET,
        "PAGES_REGISTRATION_EMAIL_VERIFICATION_REQUIRED": "false",
        "PAGES_REGISTRATION_EMAIL_DAILY_LIMIT": "234",
    }
    for name, value in legacy.items():
        monkeypatch.setenv(name, value)
    settings = Settings(_env_file=None)
    assert settings.brevo_api_key is None
    assert settings.brevo_sender_email == ""
    assert settings.brevo_sender_name == "Karama"
    assert settings.brevo_timeout_seconds == 10
    assert settings.registration_code_secret is None
    assert settings.registration_email_verification_required is True
    assert settings.registration_email_daily_limit == 300


def test_cleanup_removes_only_a_bounded_expired_batch(verified_api):
    from vessel_service.auth.cleanup_email_codes import cleanup
    api, box, state = verified_api
    challenge = send(api).json()["challenge_id"]
    with state["sessions"]() as session:
        session.add(RegistrationEmailChallenge(challenge_id="old-challenge", email="old@example.test", code_digest="x" * 64, status="failed", attempts=0, created_at=datetime.now(UTC)-timedelta(days=10), expires_at=datetime.now(UTC)-timedelta(days=9)))
        session.add(RegistrationEmailLimit(bucket_key="old-limit", hits=1, expires_at=datetime.now(UTC)-timedelta(days=9)))
        session.commit()
        assert cleanup(session, batch_size=1) == {"challenges":1, "limits":1}
        assert session.get(RegistrationEmailChallenge, challenge) is not None
    assert signup(api, challenge, box.messages[-1][1]).status_code == 201
