# WiseLife website icon

Canonical source: Vessel `apps/wrist-notes/design/brand/wiselife-icon-v1/`.

- `wiselife-icon.svg`: editable vector master.
- `wiselife-icon-1024.png`: PNG master (1024 × 1024), used to export the website assets.

The iPhone and Watch AppIcon assets are copies of this PNG master.

These PNGs are resized from that source with Pillow LANCZOS, preserving its original colors and proportions:
- `app-icon.png`: 256 × 256, header and footer.
- `apple-touch-icon.png`: 180 × 180, home-screen bookmark.
- `favicon-32.png`: 32 × 32, browser tab.

Use the brand directory master as the source when updating; `wiselife-brand.css` applies the website corner radius.
