# Brevo Registration Implementation Plan

> Execute sequentially using the executing-plans workflow. Preserve existing unrelated working-tree edits. User approved pre-registration verification and will supply the API key after development.

**Goal:** Require a short-lived, single-use email code before self-registration and send it through Brevo.

**Architecture:** SQL-backed challenge/counter state; fixed Brevo HTTPS boundary; server-only secret configuration; existing shadcn registration form. Production cannot disable verification when registration is enabled. Explicit local/test bypass supports unrelated existing fixtures.

- [x] Add failing API/provider tests covering required code, success, email binding, expiration, attempts, replay, supersession, cooldown, quotas and failure.
- [x] Add challenge/rate models, user verification timestamp, migration, settings, Brevo boundary and bounded cleanup command.
- [x] Wire send-code and atomic registration verification; persist attempts and quota reservations before returning errors/provider calls.
- [x] Add registration UI/API client and browser coverage for send/resend, errors, changed email and successful signup.
- [x] Run affected tests under 100 cases, real PostgreSQL migrations/concurrency and real HTTP browser flow with a test mail boundary; review and fix findings.
- [x] Document configuration and remaining real-delivery acceptance; do not send real mail without the supplied configuration.


## Acceptance evidence (2026-10-16)

- 58 affected backend tests passed, including code lifecycle, five attempts, supersession, quotas, provider failure/timeout, origin checks, masked configuration and bounded cleanup.
- Fresh PostgreSQL migration through 0011 passed. Real HTTP concurrency verified cooldown, one account/session/space per proof and persisted five-guess lock.
- Review found a cleanup/renewed-bucket deletion race. Reproduced it on PostgreSQL, added the shared advisory lock, and the same race test passed. Focused follow-up review found no further actionable issues.
- Real HTTP browser harness: 2 passed, covering mocked error/email-binding UI and actual registration/refresh against PostgreSQL with an injected test-only mailbox. No external email was sent by that harness.
- Local startup loads the Git-ignored Brevo config automatically via uv dotenv. Process-environment precedence confirmed. Web production build passed.
- Live Brevo account/sender checks returned 200 after authorizing the test egress IP. One real registration code was sent to the user-designated Gmail recipient through the actual HTTP endpoint: 202, challenge persisted as sent, Brevo accepted and reported delivered. No account was created for that recipient. No code/key printed or returned.
- This is local development acceptance, not production deployment. Production requires its own environment, migration and egress authorization.
