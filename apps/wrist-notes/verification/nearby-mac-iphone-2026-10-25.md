# iPhone nearby Mac LLM integration — 2026-10-25

## Delivered

Settings → AI 模型 → 连接本地 Mac 模型, immediately below Apple local model.
Scan or paste a fresh WiseLife Mac Companion AI pairing code on the same network.
Pairing selects the Mac; reconnect/check readiness, test synthetic summary/Q&A/title,
and revoke pairing (or remove locally when offline) are available.

Uses the Companion Bonjour /pair, /v1/models and /v1/chat/completions contract.
TLS leaf identity is pinned from the pairing QR; paired credentials stay in Keychain.
Notes summary/title, Ask AI, recap, insight, action extraction and content enrichment
explicitly route to the selected Mac. Existing external-send confirmation preference
still applies. No automatic local/cloud fallback. ASR is unchanged.

## Verification

- iOS Simulator full workspace Debug build: passed, arm64 and x86_64.
- test_nearby_mac.sh: passed. Strict QR parsing/expiry, old configuration migration,
  context-window roundtrip, current-request and async authorization guards,
  summary/question/title Mac failure without fallback, real synthetic TLS transport,
  wrong-pin rejection, redirect isolation, cancellation, bounded HTTP framing.
- test_daily_recaps.sh: passed. Evidence/database, consent/staleness/retry,
  bounded service batching and citations (stub transport).
- test_configured_content_model.sh: passed. Existing provider routing and
  authorization; both content APIs fail on invalid Mac identity without reading
  a custom key or falling back to iPhone/ChatGPT.
- ProjectSourceMembershipSmoke.rb: passed.
- git diff --check: passed.

## Device acceptance remaining

No physical iPhone-to-Companion pairing or camera/UI acceptance was performed
for this change. Synthetic TLS tests are not physical device connectivity evidence.
On device: allow local network/camera, scan a fresh Mac AI QR, load a model, run
“测试连接与总结”, then test Ask AI and a note summary. Pause/offline/revoke on Mac
and confirm explicit failure; resume and retry. Verify sending confirmation and
“下次不再提示” behavior with actual records.

Source integration adapted from origin/dev-desktop, preserving this checkout's
newer content pipeline and unrelated pending audio work. No commit or push.

The optional full test_local.sh suite was stopped during streaming-recording
tests after targeted integration checks passed. Its completed recording/store
checks passed, but the full suite is NOT claimed as passed.
