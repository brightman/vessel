# Local Query Translation Experiment Plan

**Goal:** Add a reusable Apple on-device query translation component and measure its effect on the existing fixed bilingual retrieval benchmark.

**Authorization and scope:** The user requested “增加端上翻译功能，再进行实验” after reviewing the direct Apple embedding experiment. Implement the proposed query-expansion experiment, preserve original source records, and report results before changing the production Ask AI retrieval policy. No cloud translation, personal records, API keys, automatic index rewrite, app reinstall, or Git publication is needed.

**Architecture:** Apple `TranslationSession` translates only short queries to the corpus language. The existing Apple embedding and SQLite Vector benchmark compares direct input, translated input, and reciprocal-rank fusion of both. Each branch uses one embedding space; generated translations are never evidence or corpus records. Keep a reusable component under `Sources/iPhone`, used by the standalone experiment; app policy/UI integration is a later decision based on the measured results.

**Tech stack:** Swift, Apple Translation, NaturalLanguage, project SQLite Vector. Translation requires macOS 26 or iOS 26 for the `installedSource` initializer. The existing iPhone target is iOS 26. The iOS Simulator cannot execute Apple Translation, so use the Mac for actual inference and compile-check the component for iOS.

## Decisions

- Translate queries, not recordings: avoids a second copy of the corpus and keeps source citations unchanged.
- Preserve the original question; translation augments retrieval only.
- Missing language resources are an explicit unavailable result. Prepare them through Apple's foreground system download UI; a background query never starts downloads.
- Cancellation propagates. Failed, empty, unchanged, and wrong-language responses are recorded and fall back to the original query. No successful translations are fabricated.
- Use the same 24-topic fixture without changing the expected answers. Compare matching scenarios within the same model and corpus.
- Predeclare equal-weight reciprocal-rank fusion with k=60, stable ID tie-break, and no tuning after seeing scores.
- For mixed-language queries, translate the whole query toward the requested Chinese/English target when the other script is present; do not veto a mixed query based on its dominant language. Pure target-language queries skip translation. Retain names in original-text/structured retrieval; do not claim the translator preserves all proper nouns.

## Tasks

- [x] Inspect current benchmark, Apple Translation SDK, device runtime and installed resources.
- [x] Add behavioral tests for preserving originals, translation failures, missing resources, same-language skip, and fusion without cross-space score comparison; run them failing before implementation.
- [x] Add reusable local query expansion and Apple Translation adapter. Compile for macOS and iOS Simulator; run deterministic policy tests. Include both files in the iPhone target and build successfully without installing.
- [x] Prepare language resources with a small foreground macOS helper using `.translationTask` and `prepareTranslation()`.
- [x] Generate real translated queries, save output/status/timing, and run the fixed benchmark with direct/translated/fused branches.
- [x] Verify raw cosine calculations and original-text controls, inspect translation errors and proper-name changes, and save a dated report with exact environment and limits.

## Verification

Policy tests should fail if expansion replaces the original, treats an empty/error response as translated, attempts same-language translation, swallows cancellation, or gives a duplicate candidate two votes within one rank list. A concrete fusion fixture is original `[A,B,C]` plus translated `[B,D,A]`, expected order `[B,A,D,C]` at k=60. The real Apple adapter is tested with downloaded resources in the experiment; deterministic substitutes test only our error/fusion policy.

Artifacts: reusable Swift source, standalone tests, optional resource-preparation helper, experiment runner, JSON results and a human-readable report. No commit is requested. Work stays in this dirty checkout with task-owned file edits only; no subagents.
