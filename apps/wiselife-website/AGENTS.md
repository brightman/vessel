# WiseLife website

- This directory is the canonical WiseLife website source, alongside `../wrist-notes/` (the native App). Do not place new website implementation in the App's `prototype/` directory.
- Read `README.md` and `docs/INDEX.md` for page versions, preview commands, migration and deployment records. Follow the repository's documentation rules in `../../docs/documentation-rules.md`.
- The site uses static HTML/CSS/JavaScript and local assets. It does not need the Vessel HTTP API or an App build.
- Keep `index.html` and `index-next.html` synchronized. Preserve the independent `launch-preview/`, `design-preview/`, `design-preview-v2/` and `compare-designs/` entries until a version is explicitly selected as the homepage.
- The copies in this site's product demos are presentation fixtures. The native App and its current interaction prototypes remain under `../wrist-notes/`.
- Preserve historical screenshots and reports. Write new migration checks to the migration evidence directory using `WISELIFE_VERIFY_OUTPUT`.
