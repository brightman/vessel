# Sign in with ChatGPT native implementation

**Goal:** Implement the approved ChatGPT provider in WiseLife iPhone settings, Ask AI and manually requested summaries, keeping Apple local as the default.

**Architecture:** A dedicated OAuth/Responses client, Keychain-backed account coordinator and system-browser authorization adapter. AI settings retain a provider choice independently from account connection. Remote sends use existing text-confirmation and stale-input guards. No WiseLife server, imported credentials, API keys or ChatGPT private endpoints.

**Authorization boundary:** OpenAI currently permits this public-client flow for open-source clients and selected private clients. Commercial eligibility is unresolved. A release configuration must explicitly enable the documented public-client flow only for an eligible distribution; default is disabled with an explanatory settings state. The user has been asked which eligibility applies. No live account login is attempted by the coding agent.

**Workspace:** Continue in the existing feature checkout because it contains the approved prototype and native changes, including untracked required sources. Preserve every unrelated change. No commits/pushes, broad staging, Ring SDK changes or native Simulator UI automation.

## Tasks

- [x] OAuth and inference core: bounded redirect-free requests, state/nonce/PKCE, validated RSA-signed ID tokens with official JWKS, granted-scope checks, account-specific model list, strict SSE terminal success, typed recovery errors; focused offline tests.
- [x] Native account lifecycle: protected atomic Keychain credential records, stable per-device host ID, saved registration selection, serial token refresh, cancellation/generation guards, disconnect/revocation, first-plan confirmation, iOS loopback listener and system authorization session.
- [x] Integrate configuration/settings, Ask AI and explicit summary confirmation. Historical Ask AI responses keep provider provenance; no automatic cloud fallback or background remote summaries. Configuration and account revisions invalidate stale preview/results.
- [x] Build/test: core smoke tests, existing AI/assistant regressions, iPhone simulator build with existing Ring feature configuration; localized copy; document release eligibility and physical-device login verification limits.

## Delivery status

Native client implementation and offline/build verification complete. The independent review's stale-consent and storage-recovery findings are resolved. All three ChatGPT scripts, the complete local regression script, and the iPhone simulator build passed. See `apps/wrist-notes/verification/chatgpt-native.md` for commands and limitations. Release eligibility and physical-device authorization/inference validation remain pending; the gate remains disabled. No commits or publication performed.

## Core interface

`ChatGPTModel: Codable, Equatable, Identifiable` has `id: String` (slug), `displayName: String`.

`ChatGPTCredential: Codable, Equatable` has `clientID`, `subject`, `email: String?`, `hostID`, `idToken`, `accessToken`, `refreshToken: String?`, `expiresAt: Date`, `scopes: Set<String>` and computed `canUsePlan`.

`ChatGPTAuthorizationAttempt` has `callbackURL: URL`, `clientID: String?`, `hostID: String`, `state`, `nonce`, `verifier`, optional `idTokenHint`, `loginHint`, `expectedSubject`; initializer creates cryptographically random attempt secrets. A nil client ID denotes initial dynamic registration.

`ChatGPTAPI` provides `authorizationURL(attempt:)`, async `exchange(callbackURL:attempt:)`, `refresh(_:)`, `models(accessToken:)`, `complete(instruction:content:model:accessToken:)`, and `revoke(_:)`. Only `response.completed` with valid nonempty text is success. Endpoint failures never include returned body text or tokens in UI errors.

## Sources verified 2026-10-20

- https://developers.openai.com/siwc/quickstart
- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/token-reference
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
- https://developers.openai.com/siwc/request-client-id

The public-client authorization endpoint is `https://auth.openai.com/api/accounts/authorize`; code/refresh exchange is `https://auth.openai.com/api/accounts/oauth/token`. The documented callback is HTTP on `127.0.0.1` with stable `/auth/callback` path and per-attempt port. Inference uses only `https://api.openai.com/v1/responses`, `store:false`, `stream:true`; model catalog is account-specific `models`, filtered by `visibility:list`.
