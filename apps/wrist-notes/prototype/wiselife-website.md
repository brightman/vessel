# WiseLife product website

Updated: 2026-10-19

Entry: [iphone-day.html](iphone-day.html)

## Design and scope

Consumer product website extending the existing graphite, cool white and muted blue prototype. Native HTML/CSS/JS; existing Lucide symbols; no additional runtime dependencies, trackers, remote fonts or image requests.

Design settings: variance 6, motion 4, density 3. Keep the blue-gray brand and live app; lead with a clear value proposition and a woodland photograph, then show concrete use cases and an original product walkthrough. Natural scrolling, keyboard controls, reduced-motion support, local media and a sticky header are retained.

1. `#welcome`: value proposition, lifestyle photograph, actual prototype overview and Watch image; direct demo and video links.
2. `#moments`: thought / conversation / reflection tabs, each with an actual prototype screenshot and a working entry into the app. Arrow keys, Home and End change tabs.
3. `#walkthrough`: approximately 27-second original screen recording. User-initiated play, native controls, chapter seeking, three caption languages, pause when offscreen or page hidden. Silent, sample-data demo; no microphone or hardware access.
4. `#product`: existing interactive app with voice summary/transcript, AI and device flows. Desktop/tablet device framing keeps a 390:844 aspect ratio at 330–390 px width; width follows available height. Small mobile screens retain the direct full-width app view. Compact metrics use the phone container width for layout, rather than the outer browser width.
5. `#hardware`: Apple Watch and EurekaRing, with an entry into the Ring connection demo. Existing always-visible Watch compatibility information retained.
6. `#ownership`: local storage, on-device models and optional user-configured external AI. Processing-mode buttons explain data flow without changing settings or transmitting content.
7. `#questions`: six accessible FAQ disclosures covering devices, offline use, data flow, sources, recording/health boundaries, and availability/cost.
8. `#pricing`: US$19.99 regular price and a one-time US$9.99 launch offer through 2026-12-31. No subscription; optional external AI provider usage is billed separately. Prototype/video links precede the photo-credit footer.

Implementation: `wiselife-story.css`, `wiselife-story.js` and `wiselife-story-locales.js` extend the existing website layer. Locale processing also translates image alternative text. The prototype remains dependency-free at runtime.

The existing Chinese/English/Japanese preference also translates the website. Existing local-storage preference keys are retained. The native Swift project is outside this change.

The website footer and embedded app settings no longer link to the old voice-notes prototype.

## Confirmed product values and price

The owner confirmed these values on 2026-10-19:

1. Reduce recording effort through quick, unobtrusive capture. Website copy describes starting a recording and carrying on with the day; it does not claim automatic always-on recording.
2. Let AI use permitted daily records for reflection and suggestions.
3. Keep data and AI on the phone in on-device mode. External AI is optional, with the content-sharing boundary stated next to that choice.
4. Support Apple Watch and EurekaRing, using hardware the customer already owns.
5. US$19.99 regular price, with a one-time US$9.99 launch offer through 2026-12-31. No subscription. Users own their data and may bring their own AI; external provider fees are separate.

These values now guide the hero, scenarios, hardware, ownership, FAQ and pricing. The prototype has no payment or App Store purchase link yet. The limited-time price was confirmed by the owner on 2026-10-20.

## Capability boundaries

- Watch recording, iPhone transfer, local transcription and configurable AI correspond to the existing app. The user previously confirmed real-device Watch transfer and ASR.
- The owner confirmed EurekaRing integration in this conversation on 2026-10-19. Both Apple Watch and EurekaRing are presented as supported. This website update does not independently test physical Ring connectivity. Hardware is not included in the app price; no additional dedicated recorder is needed when the user already owns compatible hardware.
- On-device model availability depends on device, OS, language and downloaded resources. Cloud AI sends processing content to the configured provider, whose data policies apply.
- Watch minimum deployment target: watchOS 10.0, in `WristNotes.xcodeproj/project.pbxproj` and `scripts/generate_project.rb`. iPhone deployment target: iOS 26.0.
- Watch OS compatibility range, based on Apple's current table: Series 4–12, SE generations 1–3, Ultra generations 1–4. Series 12 and Ultra 4 require a paired iPhone on iOS 27 or later. Series 4/5 and SE 1 must be on watchOS 10. Series 3 and older do not meet the minimum. This is an OS compatibility list, not evidence that every physical model has been tested.

## Sources and assets

Retrieved 2026-10-19. Product imagery remains the respective owners' material, used here for the local website prototype; publication rights have not been established by this work.

- Apple Watch SE 3 product page: https://www.apple.com/apple-watch-se/
  - Local asset: `assets/apple-watch-se.png` (516 × 616)
  - Source: https://www.apple.com/v/apple-watch-se-3/d/images/overview/contrast/contrast_se3__b0hg2fh52ily_large_2x.png
  - Illustrative hardware photo; does not imply only SE 3 is supported or any Apple partnership.
- Watch compatibility: https://support.apple.com/en-us/118490
- EurekaRing: https://eurekamind.ai/products/eureka-ring
  - Local asset: `assets/eureka-ring.webp` (1448 × 1086)
  - Source: https://eurekamind.ai/images/products/eureka-ring.webp
  - Official features referenced: voice input, seven touch gestures, three haptic patterns. No unverified battery, weight, waterproofing or sensor specifications added.

## New media and provenance

- Lifestyle photograph: [Ilse / iml on Unsplash](https://unsplash.com/photos/pathway-between-green-trees-during-daytime-aZRU_SAUnmA), downloaded 2026-10-19 under the [Unsplash License](https://unsplash.com/license). Local asset: `assets/wiselife/morning-walk.webp`, 1600 × 1000. Attribution is also visible in the footer.
- Screen images, poster and video: produced from our own interactive prototype with its sample records. They are product demonstrations, not footage of real device synchronization. Screenshot UI and baked video text are Chinese; website copy and selectable captions support Chinese, English and Japanese.
- Reference site: [Auday](https://auday.ai/). Borrowed presentation principles; no Auday text, photographs, videos, 3D assets or code reused.
- Existing Apple / Eureka product image provenance and limitations remain above.
- Canva image generation was unavailable due to reauthentication; no generated image is included.

### Regenerate the product media

From the repository root, serve the prototype in one terminal:

```sh
python3 -m http.server 8767 --bind 127.0.0.1 --directory apps/wrist-notes/prototype
```

In another terminal (Playwright, Pillow and ffmpeg required):

```sh
node apps/wrist-notes/scripts/capture_website_media.mjs
python3 apps/wrist-notes/scripts/render_website_media.py
```

The capture script writes source PNGs, raw WebM and cue timings to `/private/tmp/wiselife-website-media`. The renderer creates WebP screenshots, a rounded-screen poster and a silent 1280 × 720 H.264 MP4 with fast-start metadata. On non-macOS machines, supply `--font /path/to/cjk-font.ttc`. If capture timing changes substantially, use `cues.json` to adjust the initial 1.9-second trim, chapter offsets and the three WebVTT files.

## Verification

- Browser interaction checks passed: scenario tabs and note links, summary/full text, AI entry, independent Watch/Ring states, local/cloud explanation, all six FAQ disclosures, video start/seek/offscreen pause and all three caption tracks.
- Rendered layout checked at 320, 390, 768 and 1440 pixels in Chinese, English and Japanese, with both themes: 24 combinations, no document horizontal overflow and no running animations under reduced motion.
- Representative desktop, small mobile, Japanese and dark-theme screenshots inspected. The browser matrix is Chromium on macOS; Safari, physical iPhone playback and real hardware are outside this website verification.
- No browser runtime or HTTP asset errors in the interaction run. Linked JavaScript syntax, CSS parsing, local assets, IDs/fragments and scoped diff whitespace checked.
- Evidence: [verification record](../verification/wiselife-website-refresh/README.md).
- Design comparison: [Auday review](../docs/2026-10-19-wiselife-auday-review.md).
- Preview: http://127.0.0.1:8767/iphone-day.html . Changes are local HTML prototype work; not deployed.

## App Store legal pages and launch pricing (2026-10-20)

- Added standalone `privacy/index.html` and `terms/index.html` pages with shared responsive styling, and linked both from the site footer. The app's About screen links to `https://wiselife.cloud/privacy`, `https://wiselife.cloud/terms`, and `mailto:hello@wiselife.cloud`.
- Policy copy reflects current app behavior: local-first records, optional HealthKit/calendar/location access, explicit confirmation before user-selected external AI receives text, deletion controls, third-party boundaries, and the reduced iCloud backup scope for Application Support data.
- Pricing copy now says US$19.99 regular price and US$9.99 one-time launch offer through 2026-12-31, with App Store regional pricing governing.
- These pages are local source only and are not deployed. The privacy URL must be publicly reachable before App Store submission.
- `python3 -m unittest apps/wrist-notes/Tests/test_website_legal_pages.py` passes (4 tests); visual browser review and production URL check are still required after deployment.

## Cloud-service wording (2026-10-20)

- The site and privacy policy now state plainly that the WiseLife app provides no cloud service, account, cloud storage or sync; app-created records, transcripts, photos, summaries and insights default to iPhone storage, and Apple Watch recordings transfer to the paired iPhone for storage.
- The copy distinguishes third-party AI from WiseLife infrastructure: selected text leaves the device only when the user chooses an external AI provider and confirms sending. Recordings and photos are not sent to external AI. Apple device backup remains separately controlled by Apple settings.
- Chinese, English and Japanese homepage strings were updated together. Local source and tests are updated; production deployment and public URL verification remain pending.
