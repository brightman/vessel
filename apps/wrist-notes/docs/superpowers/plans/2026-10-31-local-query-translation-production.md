# Apple local query translation: production integration

User authorization: “完成开发，我在真机上测试”. Build on the completed bilingual benchmark. Work in the current checkout; preserve unrelated changes. No agents, Git publication, cloud translation, or changes to ASR/segmentation/Watch transport.

## Accepted design

- Use Apple contextual embeddings. Missing contextual assets fall back to lexical retrieval and expose a download action; do not silently choose the weaker sentence model.
- Translate Chinese/English and mixed questions toward the configured index language, using installed Apple Translation assets. Only the semantic query changes. Original question, speaker associations, date/kind filters, FTS, evidence, citations and history stay authoritative.
- Keep a single successful expansion in memory for incremental indexing, scoped by query, language, resource revision and generation. No translated corpus or translated-query database.
- Language resources download only from the explicit settings action, through Apple's foreground translation UI. Show installed/missing/unsupported/simulator states. Missing/failed translation preserves the existing local retrieval.
- Fence cancellation and resource/source/permission changes after translation awaits. Never publish or persist late translated results after invalidation.
- Existing vector model keys ensure sentence vectors cannot mix with contextual vectors. Rebuild derived vectors incrementally; retain source records.

## Work

1. Add behavioral regression coverage for original versus translated retrieval, fallback, permissions, invalidation/cancellation and reuse.
2. Integrate translation in the semantic worker and select contextual models.
3. Add resource status and foreground preparation to the existing local semantic settings section; correct outdated indexing descriptions.
4. Run translation policy, semantic SQLite Vector and speaker regression suites; build Simulator and physical-device targets.
5. Document real-device steps and actual verification limits. The user performs hardware acceptance.

## Completion evidence

All five tasks completed. See `verification/apple-query-translation-production-2026-10-31.md` for observed red/green tests, real Mac inference through the production worker, Simulator/device builds, signing verification and the device acceptance checklist. Hardware UI/download and personal-data quality acceptance remain with the user as requested.
