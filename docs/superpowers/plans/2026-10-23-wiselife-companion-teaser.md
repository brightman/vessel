# WiseLife Companion Website Teaser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a localized prelaunch teaser for WiseLife Companion that visually presents Watch, iPhone and Mac mini as a personal local AI setup.

**Architecture:** Keep the work inside the existing static WiseLife website prototype. Generate one local campaign image, add a semantic `#mac` section with localized HTML copy, and style it with the site's existing design tokens and responsive patterns.

**Tech Stack:** HTML, CSS, existing `wiseLifeSiteCopy` locale map, built-in image generation, local Chromium/Playwright verification.

## Global Constraints

- Product name: **WiseLife Companion** (Chinese display name: **WiseLife Mac 伴侣**).
- Label the product **In development / 即将推出 / 開発中**.
- Name **Muse Glimmer 30B** as an intended single-Mac model candidate, with compatibility subject to the final tested model build, quantization, memory and context settings.
- Do not claim Muse Spark Open runs on one 32 GB Mac.
- Preserve the existing external-provider consent disclosure.
- Keep this change to the local website prototype, its styles, locale strings and one local campaign image.
- Do not modify the iOS/Watch app, build the Mac app, publish the site, add analytics, add remote assets or introduce a signup backend.

---

### Task 1: Create the campaign image

**Files:**
- Create: `apps/wrist-notes/prototype/assets/wiselife/mac-companion-teaser-first.jpg`
- Reference: `docs/superpowers/specs/2026-10-23-wiselife-mac-companion-website-design.md`

- [ ] Use the first generated wide, text-free campaign image showing Watch + iPhone + a Mac mini-style desktop connected by a closed local-AI motif.
- [ ] Inspect the complete composition and keep its caption clear that all devices are concept artwork, not an official product photo.
- [ ] Save the first generated image under a distinct local filename and use it as the page's single campaign visual.

### Task 2: Add the localized prelaunch section

**Files:**
- Modify: `apps/wrist-notes/prototype/iphone-day.html`
- Modify: `apps/wrist-notes/prototype/wiselife-site.css`
- Modify: `apps/wrist-notes/prototype/wiselife-story-locales.js`

- [ ] Add the `#mac` teaser after `#product` and before `#hardware`, with development status, WiseLife Companion name, Muse Glimmer 30B qualification, local device flow, no-WiseLife-cloud explanation, localized image alt text, and `mailto:hello@wiselife.cloud` CTA.
- [ ] Add a navigation link only if the existing header fits without overflow; preserve compact mobile navigation.
- [ ] Add responsive, dark-theme-compatible CSS using existing site tokens; do not add animation that conflicts with reduced-motion behavior.
- [ ] Add Chinese, English and Japanese entries using the existing locale mechanism without changing unrelated strings.

### Task 3: Verify the local website

**Files:**
- Read: `apps/wrist-notes/verification/wiselife-website-refresh/README.md`
- Verify: the files listed above and the new local image.

- [ ] Run `node --check` on each JavaScript file referenced by `iphone-day.html` and parse `wiselife-site.css` with the repository's available CSS parser.
- [ ] Serve `apps/wrist-notes/prototype` on `127.0.0.1:8767` and inspect `#mac` at 320, 390, 768 and 1440 px in Chinese, English and Japanese, with light and dark themes.
- [ ] Confirm there is no horizontal overflow, the `#mac` anchor and mail link work, translated section copy and alt text appear, and reduced motion leaves no running animation.
- [ ] Run `git diff --check` scoped to the changed website files; report browser limitations clearly if a full matrix cannot be run.
