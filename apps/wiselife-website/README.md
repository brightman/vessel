# WiseLife website

Canonical source: `Vessel/apps/wiselife-website/`, alongside the native App in `Vessel/apps/wrist-notes/`. All current homepage files, product demos, media, legal pages, and design alternatives are maintained here. See [documentation index](docs/INDEX.md) and [directory migration](docs/directory-migration.md).

Official website: https://wiselife.karama.cloud

iPhone beta: https://testflight.apple.com/join/HjdCdWJu

Static HTML, CSS, JavaScript and local media, served by Caddy on Tencent Cloud.

- `index.html`: selected HD V2 homepage, matching `index-next.html`. Run `python3 scripts/sync-homepage.py` after changing `design-preview-v2/index.html`.
- `iphone-day.html`: previous homepage and interactive iPhone prototype.
- `watch-recorder.html`: interactive Watch prototype.
- `assets/brand/`: website exports from the WiseLife brand master.

From the Vessel repository root, run `npm run dev:wiselife-website`. From this directory, run `npm run dev` (equivalent to `python3 -m http.server 8789 --bind 127.0.0.1`). Preview: http://localhost:8789/.

Website checks, with the server running: `npm run test:wiselife-website` from Vessel, or `npm run test:legal && npm run test:design` here. Browser verification uses the repository's installed Playwright; `PLAYWRIGHT_MODULE` can select another installation. There is no website build step or additional runtime dependency.

Website-only capture/render scripts live in `scripts/`, with policy tests in `Tests/`. App interaction prototypes and the original brand master remain with the App. This directory has no nested `.git`; changes belong to the Vessel working tree. The previous standalone website checkout, including its Git history and uncommitted files, is preserved in the backup noted in the migration record.

The embedded app is an interactive demo using sample data. See `docs/tencent-deployment.md` for deployment and rollback details.

## New local launch-page concept

Preview the independent English redesign at [`launch-preview/index.html`](launch-preview/index.html). It follows the global launch brief with eight sections and interactive product examples. This concept is preserved as an alternative; the public homepage uses HD V2.

## Design-reference preview

Preview the high-fidelity implementation of the supplied design at [`design-preview/index.html`](design-preview/index.html), or http://localhost:8789/design-preview/ when the local server is running. See [`design-preview/README.md`](design-preview/README.md) for the asset sources, interactions, and verification screenshots. This version is retained for comparison; HD V2 is the selected homepage.

## Second design-reference preview

The newer private-AI reference has an independent implementation at [`design-preview-v2/index.html`](design-preview-v2/index.html): http://localhost:8789/design-preview-v2/. Open [`compare-designs/index.html`](compare-designs/index.html) at http://localhost:8789/compare-designs/ to compare V1 / V2 or the supplied reference / V2. V2 now uses high-resolution photography, actual 3× product-prototype captures, and scalable device frames. It is selected for the public homepage; the previous default is preserved as `index-before-v2.html`. V1 remains unchanged. See [`design-preview-v2/README.md`](design-preview-v2/README.md) for asset provenance, capture commands, and checks, and [`docs/tencent-deployment.md`](docs/tencent-deployment.md) for release status.
