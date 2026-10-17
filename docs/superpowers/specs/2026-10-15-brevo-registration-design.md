# Brevo registration email verification

Status: approved for development; implementation is in progress in the current worktree. The chosen flow verifies a six-digit email code before account creation. Migration, API, Brevo adapter, and registration UI have been added; final tests, live delivery with an approved sender, and production deployment remain separate acceptance steps.

## Recommended registration flow

Keep existing account/password login and existing users. New self-registration first requests an email code; only a valid code allows account, personal space and refresh session creation. Do not create a partially active account. Existing registrations must not silently bypass verification when the email service is unavailable.

The registration form keeps Name, Email and Password, adds a six-digit code Input and a Send code Button, and exposes a 60-second resend countdown. Browser-side timers are informational; all limits and validation are enforced by the API. Changing the email invalidates the form's current challenge. Preserve the approved shadcn controls and console palette.

The chosen flow does not create an inactive account before verification.

## HTTP contract

- `GET /v1/auth/options` additionally describes whether registration email verification is required and the resend interval. It must not expose provider configuration or secrets.
- `POST /v1/auth/registration/email-code` takes a normalized email and returns 202 with an opaque `challenge_id`, `expires_in: 600` and `resend_after: 60` after provider acceptance. The code never appears in the response. Registered emails retain the existing explicit conflict behavior. Disabled registration returns 403.
- `POST /v1/auth/register` takes the existing name/email/password plus `challenge_id` and `verification_code`. The challenge is bound to the normalized email and purpose. Account creation, challenge consumption, personal space creation and refresh-session creation commit atomically.
- Invalid, expired, consumed or exhausted codes cannot create accounts or sessions. Preserve existing 201 success and token/cookie shapes for successful registration.
- New stable errors distinguish missing/invalid verification, cooldown/attempt/quota limits and unavailable delivery; do not return raw provider responses. Rate-limited responses include a bounded `Retry-After`.

## Codes and concurrency

Generate six decimal digits using a cryptographic generator. Store a keyed digest bound to challenge ID/email/purpose with expiry, attempts, delivery status and consumption time; never store or log plaintext codes. A separate server secret protects the small code space against offline guessing of database rows.

A code lasts 10 minutes, may be submitted at most five times, and is single use. A new accepted code supersedes the previous challenge. Use database transactions and row locks or conditional atomic updates so concurrent sends cannot bypass cooldowns and concurrent registrations cannot replay the same code. Persist failed attempt counts even when returning an error.

The email boundary sends through Brevo HTTPS transactional API with a finite timeout and no automatic retry after ambiguous delivery. Persist reservation before provider I/O, and mark it delivered only on provider acceptance. A failed or ambiguous send must never authorize registration, and rate reservations remain bounded against spam/retry storms.

Use shared database counters for per-email cooldown/daily limits, per-source request limits and a configurable app-wide daily send cap no higher than 300 by default. All instances share the counters. Count attempted sends conservatively; Brevo may also have usage from other applications. Do not trust arbitrary forwarded IP headers. Expired challenge/counter rows have a documented bounded cleanup path.

## Provider and configuration

Use the existing Python HTTP client dependency and the fixed endpoint `https://api.brevo.com/v3/smtp/email`. Send a branded transactional subject plus HTML and plain-text bodies containing the code, expiry and ignore-if-unrequested guidance. Do not subscribe recipients to marketing lists.

API key and verification-digest secret come from server-side environment or an explicitly configured local secret file. Confirm the existing configuration file path and verified sender email with the user. Do not commit keys, expose them to Vite or print them. Do not create a paid subscription or change sending-domain DNS as part of this implementation.

Verification should be enabled for actual self-registration. Any bypass needed by existing unrelated fixtures must be explicit and limited to isolated test/development configuration; production must reject an insecure registration configuration. Existing accounts remain valid without a retrospective verification requirement.

## Data and rollout

Add an Alembic migration after the current migration head for challenge and rate-limit state. Add an email verification timestamp for newly verified users without labeling existing users verified. Retain existing credentials, accounts, personal spaces and role rules. Document enabling configuration and failure behavior; implementation and live delivery verification do not imply production deployment.

## Acceptance

1. A code can be requested and used once to create an account and log in.
2. No account/session is created for absent, wrong, expired, reused, wrong-email or exhausted codes.
3. Cooldown, five-attempt limit and daily/IP limits persist across workers and concurrent requests.
4. Provider auth/rate/timeout/failure responses do not leak secrets or permit registration.
5. Registered-email conflict, disabled registration, login and refresh behavior remain coherent.
6. Frontend send/resend, changed email, validation errors and keyboard use have browser coverage.
7. Run provider contract tests with mocked HTTP, affected auth tests, real PostgreSQL migration/concurrency checks and a real HTTP browser registration flow with a controlled test mail boundary.
8. Send a real Brevo acceptance email only once a verified sender, usable configuration and intended recipient are identified. Provider acceptance is distinct from inbox delivery; report each accurately.

References checked 2026-10-15:
- https://developers.brevo.com/reference/send-transac-email
- https://developers.brevo.com/docs/getting-started-with-senders-and-domains
- https://help.brevo.com/hc/en-us/articles/208580669-FAQs-What-are-the-limits-of-the-Free-plan
