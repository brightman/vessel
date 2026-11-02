# Tencent Cloud website deployment

> 类型：发布与恢复说明 · 状态：current · 更新：2026-10-31

Canonical source: `Vessel/apps/wiselife-website/`, alongside the native App. The directory migration itself did not publish; the release below publishes the HD V2 design following the user’s explicit request.

## Current deployment

- Public URL: https://wiselife.karama.cloud
- Host: Tencent Cloud `81.71.98.127`.
- SSH identity: `root`, using the existing `~/.ssh/id_ed25519_tencent_ecs` key.
- Web server: Caddy; existing configuration `/etc/caddy/Caddyfile`.
- Document root: `/opt/wiselife-site/current` (symlink).
- Active release: `/opt/wiselife-site/releases/20261031T132507Z-hd-v2`.
- Previous release retained for rollback: `/opt/wiselife-site/releases/20261031T121307Z-hd-v2`.
- Public files: 242; all upload SHA-256 hashes verified before activation.
- Homepage SHA-256: `bfb16168bffb5021727e9706ea02624bfcbd58c4677f1fb3d3740f9c78efd728`.
- TLS certificate verification, live browser checks and video byte ranges passed. Caddy configuration and other sites were not changed; no service restart was needed.

This release adds the complete Watch case, crown and sport band in both the page and enlarged preview; it reuses the user-selected V1 hero and adds two functional tips. Product-prototype screenshots remain unchanged. The selected hero source is 1024 × 369; other imagery retains the HD checks. It uses current local source files; no Git commit or GitHub push was performed. The website is served from Tencent Cloud, not GitHub Pages.

## Page mapping

- `/` and `/index-next.html`: HD V2 homepage, generated with `python3 scripts/sync-homepage.py`.
- `/design-preview-v2/`: independent entry for the same V2 implementation.
- `/index-before-v2.html`: previous default homepage, retained for comparison.
- `/design-preview/`: V1, unchanged.
- `/compare-designs/`: V1 / V2 and reference / V2 comparison.
- `/product-demos/iphone/`, `/product-demos/watch/`, `/product-demos/mac/#knowledge`: copies of the actual current interaction prototypes, with sample data.
- `/iphone-day.html`, `/watch-recorder.html`: earlier product demonstration routes, preserved.
- `/privacy/`, `/terms/`: existing legal pages.

Keep `index.html` and `index-next.html` synchronized. Brand assets come from `apps/wrist-notes/design/brand/wiselife-icon-v1/`. The PNG screenshot masters and provenance records remain local; the public pages serve optimized WebP images.

## Release procedure

1. Validate the selected page locally: `npm run test:legal`, `npm run test:design`, and `node scripts/audit-hd-assets.cjs` with the local server running.
2. Run `python3 scripts/package-release.py`. It creates a timestamped archive, public file manifest and evidence. Only public HTML/CSS/JS/media/fonts/licenses are included; docs, scripts, tests, Git, local configuration and source PNG masters are excluded. The version comparison’s design-reference image is intentionally public.
3. Serve the packaged directory locally and check asset loading and real prototype rendering before activation.
4. Upload the archive and uniquely named SHA-256 manifest. Extract to a new directory under `/opt/wiselife-site/releases/`; verify archive and every file hash, and check readability as `caddy`.
5. Hold `/opt/wiselife-site/deploy.lock`, compare the current symlink against the expected previous release, and atomically replace it. Abort if another deployment has changed the active target.
6. Run live browser checks using `WISELIFE_ORIGIN=https://wiselife.karama.cloud`; use a new `WISELIFE_VERIFY_OUTPUT` directory. Run `WISELIFE_VERIFY_OUTPUT=docs/verification/watch-hardware-20261031 python3 scripts/verify-release.py` to compare public hashes and verify video range support. Retain the old release.

The packaging script does not deploy automatically. Deployment and rollback require authorization for their target environment.

## Rollback for this release

The user’s requested deployment retained the previous release. If rollback is needed, first verify that the active target is still the HD V2 release, then perform the guarded atomic switch:

```sh
set -e
exec 9>/opt/wiselife-site/deploy.lock
flock -x 9
test "$(readlink /opt/wiselife-site/current)" = /opt/wiselife-site/releases/20261031T132507Z-hd-v2
ln -s /opt/wiselife-site/releases/20261031T121307Z-hd-v2 /opt/wiselife-site/rollback-hd-v2
mv -Tf /opt/wiselife-site/rollback-hd-v2 /opt/wiselife-site/current
```

Recheck HTTPS and the expected homepage after switching. Never overwrite an unexpected active release.

## Verification

- [Current deployed release and HTTPS hashes](verification/watch-hardware-20261031/deployment.json): all 242 public file hashes verified on the server; root and 12 key files checked via HTTPS, including the new hero and complete Watch frame; video range returns 206.
- [Live browser results](verification/watch-hardware-20261031/live/verification.json): seven widths from 320 to 1920px, menus, dialogs, tips, keyboard history, video and product routes.
- [Live image audit](verification/watch-hardware-20261031/live/asset-audit.json): all three prototypes render; all tested imagery except the user-selected 1024 × 369 hero has at least 2× effective resolution. The hero source limitation is explicitly recorded.
- [Complete Watch and hero checks](verification/watch-hardware-20261031/live/watch-hero-check.json): full Watch bounds at five viewport widths, complete hardware in the enlarged view, both tips open their corresponding examples.
- [Public manifest](verification/watch-hardware-20261031/public-sha256.json) and [release metadata](verification/watch-hardware-20261031/release.json). Exactly seven public files changed from the preceding release; none were removed.
- Screenshots are retained alongside the reports. These are website checks, not native App or hardware acceptance tests.

## Earlier releases

- `20261031T121307Z-hd-v2`: initial HD V2 release with 240 files. [Original verification](verification/hd-v2-20261031/deployment.json).

- `20261031T060113Z`: earlier homepage and logo update, 70 files. [Original verification](verification/tencent-20261031/results.json). Previous rollback target: `1.0.1-20261022`.
- Original standalone checkout and Git history are preserved in the [directory migration backup](directory-migration.md).
