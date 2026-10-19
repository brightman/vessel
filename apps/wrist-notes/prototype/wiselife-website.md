# WiseLife product website

Updated: 2026-10-19

Entry: [iphone-day.html](iphone-day.html)

## Design and scope

Consumer product website extending the existing graphite, cool white and muted blue prototype. Native HTML/CSS/JS; existing Lucide symbols; no additional runtime dependencies, trackers, remote fonts or image requests.

Design settings: variance 5, motion 3, density 3. Retain the live app in the first section, use product photography for hardware, then four concise ownership features and an interactive explanation of local/cloud processing. The page uses one adaptive theme, sticky navigation and natural document scrolling. Small screens stack the hardware cards. Reduced motion disables reveals and smooth scrolling.

1. `#product`: the existing interactive app, with an AI demo entry point.
2. `#hardware`: Apple Watch and EurekaRing, with equal-height image and introduction areas. Watch models are always visible inside its introduction, as requested; there is no disclosure or dropdown.
3. `#ownership`: local storage, on-device models, user-configured cloud/AI and privacy. The two processing-mode buttons explain data flow; they do not change app settings or transmit data. The model-settings CTA returns to the live prototype.

The existing Chinese/English/Japanese preference also translates the website. Existing local-storage preference keys are retained. The native Swift project is outside this change.

The website footer and embedded app settings no longer link to the old voice-notes prototype.

## Capability boundaries

- Watch recording, iPhone transfer, local transcription and configurable AI correspond to the existing app. The user previously confirmed real-device Watch transfer and ASR.
- EurekaRing integration and user-owned cloud storage are marked **coming soon**, since they are not implemented in the inspected Apple app. Ring hardware is also awaiting launch according to the official page.
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

## Verification

- Node syntax checks for all linked prototype scripts passed.
- PostCSS parsed the website stylesheet successfully.
- HTML checks found exactly three website sections, unique IDs, valid local asset and fragment targets, four ownership features and no Watch disclosure.
- `git diff --check` passed for prototype changes.
- Chrome desktop screenshots inspected for the app hero, hardware imagery and ownership/data-flow content. Accessibility output confirmed simplified always-visible Watch compatibility and both processing-mode states.
- Mobile breakpoints, dark theme and added English/Japanese strings are implemented. Their complete rendered review remains unverified because the browser control session was repeatedly interrupted by concurrent UI changes. No mobile or physical-device validation is claimed for this website change.
- The local preview uses `python3 -m http.server 8796 --bind 127.0.0.1 --directory apps/wrist-notes/prototype`.
