# Registration email verification

Self-registration requires an emailed code before account, personal space and refresh-session creation. Existing users continue signing in normally. The browser reuses the shared shadcn controls.

## Configuration

Local secrets go in Git-ignored, owner-only `apps/api/.env.brevo`. `scripts/dev/start-api.sh` loads it with uv's dotenv support; process environment values take precedence. Use an absolute `PAGES_BREVO_CONFIG_FILE` for another file, or an empty string to disable local loading. A missing explicitly named file fails startup. Other deployments must inject the same server environment; never expose these values in Vite.

```dotenv
PAGES_BREVO_API_KEY='your-Brevo-API-key'
PAGES_BREVO_SENDER_EMAIL='hello@karama.cloud'
PAGES_BREVO_SENDER_NAME='Memory on Cloud'
PAGES_REGISTRATION_CODE_SECRET='stable-random-secret-of-at-least-32-characters'
PAGES_REGISTRATION_EMAIL_VERIFICATION_REQUIRED=true
PAGES_REGISTRATION_EMAIL_DAILY_LIMIT=300
```

Use a key from Brevo **SMTP & API → API Keys**, not SMTP Keys. Authorize the sender and authenticate its domain. If Brevo rejects an unknown caller IP, authorize the actual API server egress IP in **Settings → Security → Authorized IPs**. Test and production egress IPs can differ; keep IP security enabled.

Share a stable code secret across instances. Rotating it invalidates pending codes and changes hashed rate keys; avoid rotation during a send window. Production rejects registration with verification disabled. Only isolated local/test configuration may explicitly bypass it. Missing provider/key/code-secret configuration fails sending with 503.

Keep self-registration disabled until configured and verified for the target environment. Enable `PAGES_ALLOW_REGISTRATION=true` using the intended database/issuer; changing a local secret file does not deploy to a remote service.

## HTTP contract

- `GET /v1/auth/options`: `registration_enabled`, `registration_email_verification_required`, `registration_email_resend_seconds`.
- `POST /v1/auth/registration/email-code` with `email`: 202 with opaque `challenge_id`, `expires_in: 600`, `resend_after: 60`. Never returns the code.
- `POST /v1/auth/register`: existing name/email/password plus `challenge_id` and six-digit string `verification_code`. Consumes proof atomically with user, space and refresh-session creation. Retains the existing 201 token/cookie shape.
- Missing proof: 422 `EMAIL_VERIFICATION_REQUIRED`. Wrong, expired, consumed, wrong-email or exhausted proof: 422 `EMAIL_CODE_INVALID`.
- Cooldown/budget: 429 `EMAIL_CODE_RATE_LIMITED` with `Retry-After`. Provider/configuration error: 503 `EMAIL_DELIVERY_UNAVAILABLE`, without raw provider details. Existing registered-email conflict is 409 `EMAIL_ALREADY_REGISTERED`; disabled registration is 403 `REGISTRATION_DISABLED`.

Codes expire after ten minutes and are single use. Five incorrect guesses lock a challenge. Accepted resend supersedes prior sent challenges; a failed resend leaves the previous valid code usable. Delayed older sends cannot supersede a newer accepted challenge. Wrong guesses and failed-send quota reservations persist despite error responses.

Shared limits: 60 seconds between sends per email, five sends per email per UTC day, 20 sends per source per hour window and at most 300 app-wide per UTC day. Provider failures/ambiguous timeouts consume reservations; no automatic retry can duplicate a message. Other applications using the same Brevo account consume its independent quota too. Source identity uses the server client address, not arbitrary forwarded headers; configure trusted proxies deliberately.

## Schema and cleanup

Migration `0011_registration_email` adds nullable `users.email_verified_at` (old accounts stay null), `registration_email_challenges` and `registration_email_limits`. Codes are persisted only as keyed digests. Rate email/source keys are keyed digests too. Keys/codes are not logged or returned.

Cleanup shares the PostgreSQL reservation advisory lock so it cannot delete a concurrently renewed rate bucket. Run a bounded batch with the same database environment:

```bash
cd apps/api
PYTHONPATH=src .venv/bin/python -m vessel_service.auth.cleanup_email_codes --retention-days 7 --batch-size 1000
```

Each call deletes at most 1,000 challenges and 1,000 limits expired more than seven days ago, printing counts only. PostgreSQL is the concurrency target; SQLite is for sequential unit tests.

## Verification

Run `tests/test_registration_email.py` and affected auth/space/App/console tests. Real PostgreSQL/HTTP/browser harness (no external email):

```bash
PAGES_DATABASE_URL='postgresql+psycopg://vessel@127.0.0.1:PORT/vessel_e2e' \
PYTHONPATH=apps/api/src apps/api/.venv/bin/python scripts/dev/registration_email_http_e2e.py
```

Use a freshly migrated dedicated database named `vessel_e2e` and a built console. The harness injects its deterministic mailbox only into its own test app; production has no test-code/mailbox endpoint. It verifies cleanup/renewal, concurrent cooldown, single-use proof, concurrent failed guesses, browser registration and refresh.

Live provider acceptance differs from recipient-server delivery and inbox placement. Never report inbox receipt based only on 201/202.

Official references:
- https://developers.brevo.com/reference/send-transac-email
- https://help.brevo.com/hc/en-us/articles/5740111683858-Authorize-and-block-IP-addresses-for-API-and-SMTP-security
