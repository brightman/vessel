# Adaptive Content Summary Budget

## Problem

Content enrichment currently breaks every transcript into fixed 650-character chunks before summarization. The same limit is enforced by all model adapters, so a model with enough context still receives only fragments. Repeated hierarchical compression can omit the relationships needed for a useful segment title and summary.

## Decision

Choose the input strategy from the selected model route's available context budget. First estimate the complete summary request, including instructions, observed context, reserved output, and a safety margin. If it fits, summarize the segment's complete ASR transcript in one request. If it does not fit, split into budget-sized leaf chunks and use the existing hierarchical reduction.

- Apple Foundation Models uses supported runtime context-size and token-count APIs when available; with the current iOS 26.2 SDK it uses Apple's documented 4,096-token limit and the conservative estimator.
- Custom models gain an optional context-window size in tokens. Since compatible endpoints do not expose a common tokenizer, estimate conservatively and reserve room for instructions and output.
- A route without trustworthy window metadata assumes the minimum supported window of 4,096 tokens.
- The model adapter remains the source of budget information; enrichment orchestration does not guess a window from model-name strings.

## Chunk sizing

For a model with an 8,192-token window, a 650-character Chinese excerpt is roughly 650 tokens, or about 8% of the raw window before prompt overhead. That is unnecessarily small. Size chunks in estimated tokens using:

`target = min(0.5 × window, 0.9 × max(0, window - prompt/context - output reserve - safety reserve))`

Use a safety reserve of 25% of the context window, and reserve 192 output tokens for a summary. With up to 1,200 tokens of observed context plus roughly 200 tokens of instructions, this gives a target near 4,000 Chinese characters for an 8,192-token model. For Apple's 4,096-token model, the same formula gives about 1,300 characters. Unknown-window models use this 4,096-token baseline, which also gives a target near 1,300 characters. The complete transcript still gets one request whenever it fits the calculated budget; chunk sizing applies only when it does not.

The custom-model token estimate is conservative: count CJK characters and punctuation as one token each, and Latin/digit runs as one token per three characters, rounded up; include serialized prompt structure. Keep chunk boundaries at transcript-span or sentence boundaries when possible. If the calculated budget is below 650 tokens, use that smaller budget. If the request itself cannot be counted safely, use the 650-character fallback.

## Data flow and persistence

Read the selected segment's transcript spans and observed context, then preflight the full request against the selected adapter's budget. A fitting transcript produces one summary checkpoint; an over-budget transcript follows the resumable budget-sized chunk and pairwise reduction flow. When the transcript fits, generate its title directly from ASR rather than the compressed summary. For longer recordings, title from the content-derived final summary. Treat existing titles without a manual-edit marker as model-generated so the new algorithm refreshes stale ones; preserve titles explicitly marked as user-edited.

Persist the optional title-manual-edit marker without breaking older stores. Apple Foundation Models uses its documented 4,096-token context limit and conservative estimator unless the build SDK exposes supported runtime context and token-count APIs.

Increment the enrichment algorithm identity so checkpoints created under fixed chunking cannot be mistaken for results from adaptive input selection. Existing authorization, cancellation, stale-source checks, and local-only defaults remain in effect.

## Failure handling

Missing window metadata uses the 4,096-token baseline. Invalid or uncountable requests use the conservative 650-character fallback. Model errors and cancellation retain the current failure and checkpoint behavior; the feature does not silently change provider or send data to another route.

## Verification

Smoke tests will prove that a transcript which fits the injected model budget is summarized in a single request, an over-budget transcript uses the calculated chunk size and hierarchical reduction, an unknown window uses the 4,096-token baseline, uncountable requests retain the 650-character fallback, the 8,192-token and 4,096-token examples produce the expected targets, and custom context-window configuration decodes older saved settings without a value. Existing enrichment and configured-model smoke scripts must pass.
