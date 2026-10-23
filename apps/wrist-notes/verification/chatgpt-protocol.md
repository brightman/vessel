# ChatGPT OAuth and Responses core verification

Date: 2026-10-20. Scope: `ChatGPTProtocol.swift`, `ChatGPTIDToken.swift`, `ChatGPTAPI.swift` and their offline smoke suite. Account persistence, browser integration and UI have separate verification.

## Executed checks

From `apps/wrist-notes`:

```sh
./scripts/test_chatgpt_protocol.sh
```

Result: exit 0 with:

```text
ChatGPT protocol smoke passed: OAuth, RSA identity, refresh, account models, terminal SSE and safe recovery
```

Toolchain: Apple Swift 6.2.4, arm64 macOS 26.0. The script builds a temporary executable with Foundation, Security and CryptoKit; its `URLProtocol` fixture intercepts every HTTP request. Test RSA private keys and signed synthetic ID tokens are generated in memory. No live authentication, stored credentials, or inference requests were used.

Test-first evidence: the initial suite failed because the three core implementation files did not exist. Later recovery regressions first failed for HTTP 401 incorrectly expiring credentials and for a structured route error losing its code. A CR-only SSE fixture first failed as incomplete; after implementing standard CR/LF handling, the complete suite passed.

## Covered behaviors

- Fresh cryptographically random state, nonce and S256 PKCE verifier/challenge; full documented scope/resource request; `dynamic_agent_client` and agent name only on initial registration.
- Exact `http://127.0.0.1:<port>/auth/callback`; `localhost` and wrong path rejected. State mismatch, missing initial issued client ID, duplicate callback fields and returning client-ID mismatch rejected before token exchange. Returning callbacks may omit the issued client ID. Valid declined-consent callbacks stop without exchange.
- Real RSA/SHA-256 signature verification using a 2048-bit generated key. Rejects invalid signature, issuer, audience, expiry, nonce and returning subject. ID-token claims become identity only after verification; access and refresh tokens remain opaque.
- Discovery issuer and JWKS HTTPS host allowlist. An off-host JWKS URI is rejected before any off-host request. Identity-only grants persist with `canUsePlan == false`.
- Refresh returns a complete replacement record, preserves absent optional ID/refresh/scope fields, verifies any returned ID-token subject, and rejects grant expansion. Caller owns atomic persistence and serialization.
- Account-specific `models` response, `visibility:list` filtering and original server order.
- Public Responses route with `store:false`, `stream:true`; incremental bounded SSE. Valid terminal completed response succeeds; deltas alone, incomplete response, unterminated final event, empty completed text, post-terminal events and streamed usage-limit failure reject. CR and LF line terminators are handled.
- Bounded response reading (including an oversized models fixture), known terminal refresh error handling, temporary failures retaining credentials, HTTP 401 admission errors retaining credentials, safe exact route diagnostics, and suppression of unknown body/error strings.
- Discovery-driven refresh-token revocation accepts an empty HTTP 200 and uses the issued client ID.

## Security controls inspected

The production URLSession is ephemeral with cookie storage, credential storage and cache disabled. Each request disables cookie handling/cache reuse. Every data/stream task receives the delegate that refuses HTTP redirects. Identity metadata endpoints require HTTPS on `auth.openai.com` without embedded credentials, fragment, query or a nonstandard port. Endpoint bodies and tokens are never added to error descriptions or logs. Chinese error descriptions use localized catalog keys.

Bounds: token/discovery/JWKS response 256 KiB; models 1 MiB; inference stream 4 MiB; each SSE line/event and final text 256 KiB; combined instruction/content input 1 MiB. Requests use 60-second request and 120-second resource timeouts. No automatic retry or billing fallback is performed by the core.

## Not established by this suite

Actual OpenAI registration eligibility, physical-device loopback/browser behavior, live discovery/JWKS compatibility, live account-specific catalogs, renewable-session rotation/revocation and real Responses completion are unverified. HTTP redirect rejection was inspected in the task delegate; the fixture suite does not perform a live redirected request. Keychain atomicity and concurrent refresh coordination belong to the account layer. This report does not claim an end-to-end login or device test.

The typed recovery categories intentionally give UI recovery states. For unclassified HTTP failures the error retains HTTP status and a sanitized request ID; documented unsupported-capability/route failures retain their exact code. Raw server bodies are discarded and categorized recovery cases do not carry raw diagnostic payloads.

## Official source contract

Rechecked public documentation while implementing:

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
