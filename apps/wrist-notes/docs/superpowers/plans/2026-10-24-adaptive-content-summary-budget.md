# Adaptive Content Summary Budget Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send a complete segment transcript in one summary request when it fits the selected model's context budget, otherwise summarize budget-sized chunks, and generate titles from the full ASR when it fits.

**Architecture:** `ContentEnrichmentService` owns transcript paging, fit checks, resumable chunk checkpoints, and hierarchical reduction. `ConfiguredContentTextModel` supplies the selected route's context window and token estimates; Apple Foundation Models uses supported runtime introspection when available and otherwise Apple's documented 4,096-token limit, custom models accept an optional configured window, and unknown routes assume 4,096 tokens. The AI settings screen exposes the optional custom-model window without changing existing authorization or provider routing.

**Tech Stack:** Swift, SwiftUI, Foundation Models, existing `swiftc` smoke scripts.

## Global Constraints

- Keep local AI as the default and preserve explicit confirmation before remote requests.
- Preserve cancellation, stale-source rejection, checkpoint restart, and explicit manual-title protection; refresh older unmarked model-generated titles.
- Count a 25% context-window safety reserve and reserve 192 output tokens for summaries.
- For unknown model windows, assume 4,096 tokens; for uncountable requests, retain the 650-character fallback.
- Leave unrelated existing worktree changes untouched.

---

### Task 1: Add model-window configuration and pure budget math

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/AIConfiguration.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/ContentEnrichmentService.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/SettingsViews.swift`
- Test: `apps/wrist-notes/Tests/ConfiguredContentModelSmoke.swift`
- Test: `apps/wrist-notes/Tests/ContentEnrichmentSmoke.swift`

**Interfaces:**
- Add `AIConfiguration.contextWindowTokens: Int?`; missing serialized values remain `nil`, interpreted as 4,096 tokens by the model router.
- Add `ContentModelBudget(windowTokens:fixedInputTokens:outputReserveTokens:tokenCount:)`, where `tokenCount` defaults to the conservative estimator, with `availableTranscriptTokens` and `chunkTargetTokens` derived from the approved formula.
- Add a conservative text-token estimator: one token per CJK character or punctuation mark, and one per three Latin/digit characters rounded up.

- [x] **Step 1: Write failing persistence and budget tests.**

Add a round-trip test that decodes JSON containing `contextWindowTokens: 8192`, re-encodes it, and verifies the value survives; also verify older JSON with no field still decodes. Add budget cases for 8,192 and 4,096 tokens:

```swift
let wide = ContentModelBudget(windowTokens: 8192, fixedInputTokens: 1400, outputReserveTokens: 192)
let compact = ContentModelBudget(windowTokens: 4096, fixedInputTokens: 1400, outputReserveTokens: 192)
expect(wide.chunkTargetTokens == 4096, "8k window targets about4k transcript tokens")
expect(compact.chunkTargetTokens == 1332, "4k window targets about1.3k transcript tokens")
```

- [x] **Step 2: Run both focused smoke scripts and confirm the expected failures.**

Run: `cd apps/wrist-notes && sh scripts/test_configured_content_model.sh && sh scripts/test_content_enrichment.sh`

Expected: compilation fails only because `contextWindowTokens` and `ContentModelBudget` are not implemented yet. Those missing production interfaces are the intended red signal for this change.

- [x] **Step 3: Implement backwards-compatible configuration and the budget helper.**

Add the optional field to `CodingKeys` and `init(from:)`, validate a configured custom window in the inclusive range 1,024–1,000,000, and make an empty setting use the 4,096 baseline. Give `ContentModelBudget` a default token estimator so the three-argument test initializer above compiles. Define the pure formula:

```swift
let safety = windowTokens / 4
let remaining = max(0, windowTokens - fixedInputTokens - outputReserveTokens - safety)
let chunkTargetTokens = min(windowTokens / 2, Int(Double(remaining) * 0.9))
```

- [x] **Step 4: Run the focused tests and verify the budget math and old-settings behavior pass.**

Run: `cd apps/wrist-notes && sh scripts/test_configured_content_model.sh && sh scripts/test_content_enrichment.sh`

Expected: both scripts pass; the 8,192-token target is 4,096, the 4,096-token target is 1,332, and older settings decode with the 4,096 baseline.

- [x] **Step 5: Add the optional custom-window field to the AI settings form.**

In `SettingsViews.swift`, place “上下文窗口（tokens，可选）” under the custom model name. Bind an empty string to `nil`, parse positive integer edits, and show helper text that an empty value assumes 4,096 tokens. Keep existing API-key storage and connection-test behavior unchanged.

---

### Task 2: Route budget information and summarize fitting transcripts whole

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/ConfiguredContentTextModel.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/ContentEnrichmentService.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/ContentSegmentation.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/ContentSegmentRepository.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AudioProcessingModel.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/SettingsViews.swift`
- Test: `apps/wrist-notes/Tests/ContentEnrichmentSmoke.swift`
- Test: `apps/wrist-notes/Tests/ConfiguredContentModelSmoke.swift`

**Interfaces:**
- `ConfiguredContentTextModel.summaryBudget(context:) -> ContentModelBudget` returns an injected local-model budget, the configured-or-4,096 size for custom mode, and the 4,096 baseline for ChatGPT mode. Its default local budget is 4,096; when supported by the SDK, the iOS call site may inject Apple's actual context size and token counter.
- `ContentEnrichmentService` accepts an async budget provider keyed by observed context; its default provider returns the unknown-model 4,096-token budget.
- Full-transcript fit uses `availableTranscriptTokens`; over-budget input uses `chunkTargetTokens` and existing durable checkpoint layers. Fitting transcripts are also passed directly to title generation; oversized transcripts use their final content-derived summary.

- [x] **Step 1: Add failing orchestration tests for one-shot and adaptive chunks.**

Add a single-segment fixture with a 1,200-character Chinese transcript and assert exactly one `.summary` model call under the unknown 4,096-token baseline. Add a second fixture whose token estimate exceeds `availableTranscriptTokens` and assert every first-level summary input stays within the injected 1,332-token chunk target, reduction terminates, and the final summary is stored.

- [x] **Step 2: Run `sh ./scripts/test_content_enrichment.sh` and verify the one-shot assertion fails against current 650-character slicing.**

Expected: the one-shot case observes multiple summary requests; current baseline behavior is the failure, not a compile error.

- [x] **Step 3: Add budget routing and a bounded two-pass transcript read.**

Preflight the complete segment using paged transcript spans and stop retaining the candidate once it exceeds the one-shot transcript budget. If it fits, issue one summary request and checkpoint its result. If it exceeds the budget, reread the spans and build chunks up to `chunkTargetTokens`, preferring span/sentence boundaries; persist each partial and retain the existing pairwise reduction. Avoid holding an unbounded recording transcript in memory.

- [x] **Step 4: Provide budgets from the selected adapter and remove the universal 650-character request rejection.**

Use `SystemLanguageModel.default.contextSize` and Foundation Models token counting for the local route when exposed by the build SDK; with Xcode 26.3/iOS 26.2, use the documented 4,096 window and conservative estimator. For custom models use `contextWindowTokens ?? 4096` with the conservative estimator; ChatGPT uses 4,096 because its current model catalog exposes only identifiers and display names. Keep the 650-character fallback only when input counting fails. Update `AudioProcessingModel` to pass the router's budget provider into enrichment.

- [x] **Step 5: Version the enrichment identity and preserve existing safeguards.**

Bump `ContentEnrichmentService.algorithmVersion` so old fixed-chunk checkpoints cannot be reused as adaptive results. Keep remote authorization checks around every model call, cancellation checks during both span passes, source-revision checks before checkpoint writes, and the current rule that user-authored titles are not overwritten.

- [x] **Step 6: Run focused tests and inspect the exact changed paths.**

Run: `cd apps/wrist-notes && sh scripts/test_content_enrichment.sh && sh scripts/test_configured_content_model.sh`

Expected: the one-shot, adaptive chunk, 650-character fallback, and transcript-based title tests pass; checkpoint restart avoids duplicate work; old generated titles refresh while explicitly manual titles remain protected; configured model consent/route tests remain green. Review `git diff --check` and `git status --short`; do not stage or alter unrelated dirty files.
