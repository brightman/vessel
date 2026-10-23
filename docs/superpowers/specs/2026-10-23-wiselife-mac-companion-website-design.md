# WiseLife Companion prelaunch website section

- **Status:** Approved for local website implementation
- **Date:** 2026-10-23
- **Scope:** Local WiseLife website prototype at `apps/wrist-notes/prototype/iphone-day.html`

## Goal

Introduce the upcoming Mac companion as the local-model extension to WiseLife on iPhone. Explain the device-to-device flow and data boundary, name one model that can fit a single 32 GB Apple-silicon Mac, and invite interested users to contact WiseLife without implying that the app is available today.

## Product name and model claim

- Product name: **WiseLife Companion** (Chinese display name: **WiseLife Mac 伴侣**).
- Label the product **In development / 即将推出 / 開発中**. Do not show a download button, release date, waitlist form, or claim that this app has shipped.
- Name **Muse Glimmer 30B** as an intended single-Mac model candidate, with compatibility subject to the final tested model build, quantization, memory and context settings. Do not call it the latest Muse model overall and do not claim that one 32 GB Mac can run Muse Spark Open.
- Keep the claims bounded to the current proposed companion design. Model versions, minimum macOS/hardware, and inference performance remain unverified until implementation and device testing.

## Placement and experience

Add a dedicated prelaunch section immediately after the interactive iPhone product experience and before the hardware section. The campaign visual must show Watch + iPhone + Mac mini together as one personal, private AI setup. Use the first generated complete trio composition, showing Watch, iPhone and a silver Mac mini-style desktop connected by a closed local loop. Treat the entire visual as product concept artwork rather than an official Apple product photo. Use the existing graphite, cool-white and muted-blue visual language and no cloud or global-network motif. Do not bake text into the artwork; render copy as localized HTML. Keep responsive spacing, reduced-motion behavior, and local assets only. Add a desktop navigation link to the section only if it fits the existing header; keep compact mobile navigation from overflowing.

The section should describe WiseLife Companion as a complete personal private AI solution across devices, without suggesting that the Mac app has shipped. It should communicate a three-step flow:

1. Record and transcribe on iPhone using the existing on-device path.
2. When the user selects the Mac model, send the text request from iPhone to the paired Mac over the local network; the Mac runs the model locally.
3. Return the result to WiseLife on iPhone for storage and review.

State that WiseLife provides no cloud service and that this planned local-model path does not send prompts through WiseLife servers. Downloading model weights requires fetching model files from their upstream source; this does not mean user records are uploaded there. Preserve the existing disclosure that user-selected external AI providers receive selected text only after the user confirms sending it.

Use `mailto:hello@wiselife.cloud` as the single interest CTA. It opens the user's email client and must not collect or transmit information in the page itself. Add concise campaign copy around the promise “your devices, your model, your data”, but preserve the external-provider consent disclosure elsewhere on the page.

## Localization and implementation boundary

Provide equivalent Chinese, English and Japanese copy through the website's existing locale mechanism, including the image alternative text. Keep this change to the local website prototype, its styles, locale strings and one local campaign image. Do not modify the iOS/Watch app, build the Mac app, publish the site, add analytics, add remote assets or introduce a signup backend.

## Acceptance checks

- The new section has a unique `#mac` anchor, a clear development status, product name, model qualifier, device flow, privacy wording and working mailto CTA.
- No copy implies that Muse Spark Open runs on one 32 GB Mac or that WiseLife Companion is already downloadable.
- Chinese, English and Japanese strings switch with the existing language preference.
- At 320, 390, 768 and 1440 px, the section and navigation have no horizontal overflow in light and dark appearances; reduced-motion settings do not add animation.
- Existing page behavior, links, and interactive prototype remain unchanged.

## Evidence and limitations

- Meta's Muse Glimmer model card describes its 30B model, local deployment and quantized builds for consumer memory envelopes: <https://huggingface.co/meta-models/Muse-Glimmer-30B>.
- Apple's distributed-inference demonstration identifies Muse Spark Open as a multi-Mac workload: <https://machinelearning.apple.com/research/mlx-distributed-inference>.
- The WiseLife Mac companion remains a proposal. This section is a prelaunch advertisement, not evidence of a shipped app, supported model, measured speed, or verified privacy implementation.
