# Sign in with ChatGPT prototype plan

**Goal:** Add the user-approved ChatGPT account option to the latest `iphone-day.html` prototype, including account lifecycle and Ask AI integration.

**Architecture:** A separate `daybook-chatgpt.js` module owns an in-memory demo connection. Existing model settings keep the selected provider; Ask AI reads that provider and snapshots selected text before confirming each remote request. All answers remain deterministic examples. Existing styling and locale dictionaries are extended with scoped additions.

**Scope:** HTML/CSS/JS prototype and documentation only. Preserve all unrelated dirty changes. No Swift changes, real authentication, credentials, provider requests, account persistence, commits or pushes. The user's request approves producing the interactive design now.

## Design decisions

- Keep Apple local as the default. Add ChatGPT between Apple and custom providers in AI settings, rather than creating another global account system.
- Use the `Continue with ChatGPT` action. Show simulated authorization and a first-use plan notice; never imitate a provider password page.
- Connected card shows an explicitly fictitious demo account, an account-returned model placeholder, plan-usage management and disconnect confirmation. Saving the model choice is separate from connecting the account.
- Support cancellation, network failure, unavailable eligibility, expired authorization and usage limit. Failed connections never enable saving; unavailable selected providers do not silently fall back.
- Ask AI shows the selected provider and keeps per-answer provenance. Remote requests preview the exact question and approved record text; cancellation retains the question. No raw audio/images or voice profile are sent even in the proposed flow.
- Document that actual availability depends on OpenAI authorization, app eligibility and account access. WiseLife's one-time purchase does not imply unlimited ChatGPT usage or include a ChatGPT subscription.

## Tasks

- [x] Add isolated connection states and settings card in `daybook-chatgpt.js` / `.css`; integrate with `daybook-model-settings.js` and `iphone-day.html`.
- [x] Add provider indicator, per-request text preview and failure recovery to `daybook-ai.js`; wire provider access in `daybook.js`.
- [x] Add zh/en/ja copy through the existing localization extension and update `settings-design.md` with the official-source boundary.
- [x] Verify browser interaction for connect/cancel/failure/expiry/limit/disconnect; model save/cancel; preview/answer; refresh reset; local/custom/voice settings regressions. Inspect screenshots at normal/narrow widths in light/dark and translate new UI. Save evidence in `verification/chatgpt-prototype/`.

## Sources checked

- https://developers.openai.com/siwc/quickstart
- https://developers.openai.com/siwc/ui-ux-guidelines
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference

These establish the account/plan usage concept and UX requirements, not WiseLife's actual production eligibility. No real authorization is attempted by this prototype.
