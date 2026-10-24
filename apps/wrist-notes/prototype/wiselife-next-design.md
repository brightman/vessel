# WiseLife alternate homepage

Date: 2026-10-24. Scope: an independent `index-next.html` comparison page; original homepage and deployment unchanged.

## Design

Consumer personal AI, cool white / graphite / restrained blue. Native HTML/CSS/JS, system typography, existing local photographs and product screenshots. Natural scrolling, 10 chapters, consistent navigation CTA to acquisition. No new runtime libraries or tracking. Visual settings: variance 6, motion 3, density 4.

1. Personal on-device AI: privacy-first headline, Apple ecosystem concept image, Watch/iPhone/Mac roles. Expandable compatibility and memory/model selector.
2. Overview: capture → insight → action, existing original demo video.
3. Capture: flash thought and longer recordings; explicit user start, lightweight ongoing capture.
4. Insight: Ask AI, grounded answers, review source; existing prototype link.
5. Action: suggestions become editable tasks, reminders and calendar events after confirmation.
6. Hardware: supported Apple Watch and EurekaRing; no additional hardware needed if already owned.
7. Ownership: phone/local Mac/external AI routing explanation and consent boundaries.
8. Acquisition/pricing: App one-time launch US$9.99, regular US$19.99, existing 2026-12-31 expiry. App and Ring crowdfunding planned; no invented Ring price, funding totals or launch date.
9. Downloads: explicit unavailable App Store/TestFlight/Mac links, working prototype instead. Configuration object for real URLs when supplied.
10. FAQ: recording, hardware, offline use, AI hardware, Mac optionality, privacy, funding.

First screen headline: “你的数据。你的 AI。都在你的设备上。” No unsubstantiated market-first or absolute security promise. Mac Companion remains development/planned. iPhone app compatibility is distinct from Foundation Models eligibility. Model suggestions are resource estimates for local runtimes, not WiseLife integration certification or global benchmark rankings.

## Models and sources

Checked 2026-10-24 using Apple support and Ollama library pages:
- https://support.apple.com/en-us/118490 (watch pairing)
- https://support.apple.com/en-us/121115 (Apple Intelligence eligible devices and region limits)
- https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-26-iphe3fa5df43/ios (current iPhone guide)
- https://docs.ollama.com/macos (local runtime requirements)
- https://ollama.com/library/qwen3.5 (4B 3.3–4GB, 9B 6.6–7.6GB, 27B 17–20GB)
- https://ollama.com/library/qwen3.6 (27B 18–19GB, 35B 23–24GB)
- https://ollama.com/library/gemma4 (E2B 4.6–7.5GB, E4B 6.6–9.5GB, 12B 7.7–8GB, 26B 16–19GB, 31B 19–20GB)
- https://ollama.com/library/gpt-oss (20B 14GB; 120B 65GB excluded from 64GB recommendation)

16GB: Qwen3.5 4B / Qwen3.5 9B / Gemma4 E2B (lightweight start; 9B secondary).
24GB: Qwen3.5 9B / Gemma4 12B / gpt-oss 20B (last one short context only).
32GB: Qwen3.6 27B / Gemma4 26B / gpt-oss 20B (resource estimate; start 4K context).
64GB: Qwen3.6 35B-A3B / Gemma4 31B / Qwen3.6 27B (quality/latency tradeoffs, no maximum-context guarantee).

Model size is downloaded artifact range, not memory requirement. Leave room for OS, KV cache and inference runtime; one model at a time, conservative 4K context as starting point; actual performance untested. Some model families are open-weight under specific licenses; do not equate downloadable weights with unrestricted open source.

## Implementation / verification plan

- [x] Build independent semantic HTML and CSS; all links target existing demo or supplied destinations.
- [x] Add accessible model selector, data-route selector, mobile menu and progressive enhancements.
- [x] Check HTML/CSS local resources, JavaScript syntax, CTA states and all four memory options.
- [x] Render at 1440, 768, 390 and 320px, keyboard navigation, reduced motion; inspect screenshots.
- [x] Save verification evidence and copy new files to Vessel prototype for comparison. No push or homepage replacement in this iteration.
