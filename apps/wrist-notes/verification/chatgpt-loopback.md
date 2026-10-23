# ChatGPT browser and loopback verification — 2026-10-20

## Implementation

- `ChatGPTBrowserAuthorization` uses `ASWebAuthenticationSession` and a retained presentation anchor from a foreground key window. `callbackURLScheme` is nil because the documented callback is HTTP loopback.
- `ChatGPTLoopback` binds Network.framework TCP explicitly to IPv4 `127.0.0.1` at an ephemeral port; `acceptLocalOnly` is also enabled. It is ready before the authorization URL builder receives `http://127.0.0.1:<port>/auth/callback`.
- Only bounded, ASCII `GET` request lines in HTTP/1.0 or HTTP/1.1 are accepted. The raw path must be exactly `/auth/callback`; duplicate, missing, or incorrect state is rejected. The matching URL is returned for the OAuth core's full callback validation. OAuth error callbacks with matching state also reach the core.
- Request lines are limited to 4 KiB, accumulated input to 8 KiB, simultaneous connections to eight, and each connection to three seconds. Responses contain static text, no request data, and `Cache-Control: no-store`.
- There is no request/header/code logging or credential echo. The browser session has a five-minute timeout. Cancellation, listener failure, timeout, and success clear the listener, clients, tasks, continuation, browser session, and anchor. An attempt UUID prevents queued events or cancellation from an older attempt from completing a replacement attempt.

## Verified locally

Command: `sh apps/wrist-notes/scripts/test_chatgpt_loopback.sh`

Result on 2026-10-20: exit 0; parser and real macOS loopback HTTP smoke passed, and the adapter typechecked against the iPhone Simulator 26.2 SDK with Swift 6 and `arm64-apple-ios18.0-simulator` target.

The smoke test covers valid URLs, fragmented request lines, wrong method/path/state, duplicate state, malformed percent encoding, absolute targets, fragments, invalid HTTP versions, oversized input, matching OAuth error callbacks, real HTTP rejection without authorization completion, a successful HTTP callback, no code echo in the response, a closed listener refusing later requests, and cancelled startup.

The parser test was first observed failing with `matching callback returns exact URL`, then passed after implementation. The listener test first failed with the unimplemented listener's cancellation error, then passed with the actual Network listener.

The iOS compiler check uses the real shared `ChatGPTError` definition. It verifies API availability and actor isolation; it does not launch an authorization session. UUID isolation and full browser teardown were reviewed in source and are not exercised with native UI automation.

## Physical-device boundary

No live ChatGPT login, credential exchange, browser UI automation, or real-device foreground callback has been attempted. In particular, whether the app's loopback listener continues receiving while `ASWebAuthenticationSession` is presented on an iPhone remains unverified. A simulator typecheck and macOS listener test do not establish that behavior.

Before release in an eligible distribution, test on a physical iPhone: initiate sign-in; check the system authentication browser and expected account consent; complete the exact loopback callback; cancel at the consent prompt and in the browser; cancel or disconnect while a callback is queued; begin a replacement attempt; test background/foreground interruption; and test timeout/network loss. Confirm each path dismisses the session, releases its port, and keeps old attempts from connecting an account. Do not record callback URLs, authorization codes, tokens, or account credentials in test evidence.

## Official references checked

- OpenAI sign-in specification: https://developers.openai.com/siwc/token-sharing-open-source/sign-in — requires HTTP `127.0.0.1`, stable `/auth/callback`, a running listener before opening the browser, and identical callback URI within an attempt.
- Apple Network `requiredLocalEndpoint`: https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint — a specific local IP address and port for connections and listeners.
- Installed Apple iPhone Simulator 26.2 SDK `Network.swiftinterface` confirms `requiredLocalEndpoint`, `acceptLocalOnly`, ephemeral `NWEndpoint.Port.any`, and `NWListener.port`.
- Installed Apple iPhone Simulator 26.2 SDK `ASWebAuthenticationSession.h` confirms nullable `callbackURLScheme`, required presentation context, cancellation handling, `start()` failure return, and `cancel()`.
