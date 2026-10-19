# WiseLife website refresh verification

Date: 2026-10-19. Target: `prototype/iphone-day.html`, served at `http://127.0.0.1:8767`.
Browser: Playwright Chromium on macOS. Scope: HTML website and embedded prototype only.

## Browser checks

See [browser-results.json](browser-results.json) for all checks and the 24-entry viewport matrix.

- No video autoplay on initial load.
- Scenario tabs: arrows, Home, End, roving focus, one visible panel.
- Thought / conversation links open their actual notes; summary/transcript switch works.
- Reflection opens embedded AI.
- Ring website CTA opens the Ring detail; connection updates both-device status; disconnecting Watch retains Ring connection.
- Local/cloud explanation switches the correct panel.
- All six FAQ disclosures open and close with Enter.
- MP4 playback advances; chapter seeks work; Chinese, English and Japanese caption tracks load and show cues.
- Video pauses when scrolled off screen.
- UI language/appearance settings update the website.
- 320 / 390 / 768 / 1440 px × Chinese / English / Japanese × light / dark: no document horizontal overflow. Reduced motion: no running animations.
- No JavaScript runtime errors or failed HTTP resource responses during the interaction run.

## Inspected screenshots

- [Desktop hero](desktop-hero.png), [use cases](moments.png), [film](walkthrough.png).
- [Existing product](product.png), [hardware](hardware.png), [data ownership](ownership.png), [FAQ](questions.png).
- [320 px English](en-light-320-moments.png), [390 px Japanese](ja-light-390-hero.png), [English dark desktop](en-dark-1440-hero.png).

The screenshots document the local prototype. Chinese UI is baked into media; live site text and captions support three languages. The few representative screenshots above were visually inspected; the full 24 combinations were measured for overflow and motion.

## Static/media verification

- All scripts linked from the HTML pass `node --check`.
- Stylesheets parse with PostCSS.
- HTML IDs are unique; local sources and fragment targets resolve.
- `git diff --check -- apps/wrist-notes` passes.
- ffprobe identifies a silent H.264 MP4, 1280 × 720, approximately 27 seconds, with local WebVTT captions.

Safari and physical iPhone/Watch/Ring behavior were not tested by this website change. The page does not connect real hardware, run inference, or publish a live service.

## Device proportion correction

The previous desktop frame kept a 430 px width while reducing its height to 656 px in a 1440 × 768 window. It now uses 330 × 714 px at that viewport, and 364 × 788 px at 1440 × 900, preserving a 390:844 ratio. The device column follows this width without flex compression. Compact metrics and the camera cutout adapt to the container.

- Seven desktop/tablet/mobile viewport measurements: [phone-proportions.json](phone-proportions.json). No horizontal page overflow.
- Checked summary/transcript navigation, Ring connection and dialog alignment after resizing.
- Compact metric values remain on one line; status icons do not overlap the camera cutout.
- Visually inspected [laptop layout](product-laptop.png) and desktop layout; dark theme also rendered. CSS parses and scoped diff whitespace checks pass.

## Confirmed values, pricing and EurekaRing status

Updated the hero, scenarios, hardware, ownership, FAQ and pricing after owner confirmation. Price: US$9.9, one-time purchase, lifetime use, no subscription. Both Apple Watch and EurekaRing are supported. On-device processing and optional external AI content/fee boundaries are explicit.

- [Value/pricing browser results](value-pricing-results.json): Chinese / English / Japanese at 1440 px light, 390 px dark and 320 px light. All nine combinations load without horizontal overflow or runtime errors.
- Hero and pricing both show the confirmed price. The pricing anchor works; both hardware badges are supported; obsolete Ring planning copy is absent from the hardware section.
- English hero/pricing checked for untranslated Chinese. JavaScript syntax, stylesheet parsing and scoped diff checks pass.
- Visually inspected [Chinese hero](value-hero-zh-Hans-1440.png), [Chinese pricing](pricing-zh-Hans-1440.png) and [320 px English pricing](pricing-en-320.png).
- This confirms website presentation only. Physical Ring integration status is supplied by the owner, not tested by this browser check.
