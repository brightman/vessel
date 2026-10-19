# WiseLife icon · 观 / The Witness

2026-10-19 · Original vector concept, version 1.

> 经历，在回望中成为理解。此刻，仍有选择的余地。

## Symbol

- **Inward spiral:** daily experience returns as reflection; understanding develops through revisiting.
- **Open ends:** the self remains unfinished and capable of change.
- **Warm point:** the present, and the person who experiences it, remains at the heart of the record.
- **Negative space:** attention and quiet; a private inner space owned by the individual.

The blue-gray ground continues WiseLife's existing identity. The pale path carries the visual weight; a restrained warm point provides contrast. No letter, microphone or literal brain is needed to carry the symbol.

## Deliverables

- `wiselife-icon.svg`: editable vector master.
- `wiselife-icon-1024.png`: opaque RGB 1024 × 1024 full-bleed square, suitable for importing into an iOS app-icon asset catalog. No pre-applied corner mask.
- `wiselife-icon-{512,180,120,60}.png`: additional PNG exports.
- `wiselife-icon-preview.png`: approximate rounded app-icon presentation; not the asset-catalog source.
- `small-size-proof.png`: 180 / 120 / 60 px inspection sheet.
- `export-check.json`: dimensions and color-mode checks.

## Production method

This delivery is an original SVG drawing rasterized with Chromium and downsampled with Pillow. It is not a model-generated image. Canva image generation was attempted but returned `UNAUTHORIZED`, requiring reauthentication. No image-generation API was called and no API key was requested or used.

Design brief: create a single quiet, philosophical WiseLife icon. An open inward-returning path represents experience and reflection, negative space represents awareness, and one warm point represents the present. Use the existing blue-gray identity with ivory and muted gold, a simple silhouette readable at 60 px, no text, and an opaque square background.

The 1024 px master is now used by both the iPhone and Apple Watch `AppIcon` asset catalogs. Website branding is managed separately. Release and TestFlight verification are tracked in `../../../docs/testflight-release-2026-10-19.md`; source integration alone does not establish device installation or App Store processing.
