# Adaptive Content Summary Budget

## Problem

Content enrichment currently breaks every transcript into fixed 650-character chunks before summarization. The same limit is enforced by all model adapters, so a model with enough context still receives only fragments. Repeated hierarchical compression can omit the relationships needed for a useful segment title and summary.

## Decision

Choose the input strategy from the selected model route's available context budget. First estimate the complete summary request, including instructions, observed context, reserved output, and a safety margin. If it fits, summarize the segment's complete ASR transcript in one request. If it does not fit, retain the existing 650-character leaf chunks and hierarchical reduction.

- Apple Foundation Models uses its reported context size and framework token-counting support when available.
- Custom models gain an optional context-window size in tokens. Since compatible endpoints do not expose a common tokenizer, estimate conservatively and reserve room for instructions and output.
- A route without trustworthy window metadata keeps the 650-character fallback.
- The model adapter remains the source of budget information; enrichment orchestration does not guess a window from model-name strings.

## Data flow and persistence

Read the selected segment's transcript spans and observed context, then preflight the full request against the selected adapter's budget. A fitting transcript produces one summary checkpoint; an over-budget transcript follows the existing resumable 650-character chunk and pairwise reduction flow. Titles continue to derive from the final summary and preserve user-authored titles.

Increment the enrichment algorithm identity so checkpoints created under fixed chunking cannot be mistaken for results from adaptive input selection. Existing authorization, cancellation, stale-source checks, and local-only defaults remain in effect.

## Failure handling

Missing or invalid window metadata uses the conservative 650-character path. Inputs that cannot be safely counted or bounded also fall back to chunking. Model errors and cancellation retain the current failure and checkpoint behavior; the feature does not silently change provider or send data to another route.

## Verification

Smoke tests will prove that a transcript which fits the injected model budget is summarized in a single request, an over-budget transcript uses 650-character chunks and hierarchical reduction, an unknown budget retains the safe fallback, and custom context-window configuration decodes older saved settings without a value. Existing enrichment and configured-model smoke scripts must pass.
