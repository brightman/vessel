# Memory on Cloud Homepage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve a public Memory on Cloud homepage at `/` while retaining the existing Vessel console at `/console` and registration at `/register`.

**Architecture:** Add an independently built static React marketing application under `apps/marketing`. FastAPI serves its HTML only from the root route and its immutable assets from `/assets`; the existing console bundle and all API routes remain under their current paths. The homepage contains the approved value proposition, Files/Pages/Apps explanation, use cases, FAQ, and direct registration CTAs. It names unsupported integrations and commercial plans only as planned.

**Tech Stack:** React 19, TypeScript, Vite 8, native CSS, FastAPI, pytest/httpx ASGI transport, Playwright.

## Global Constraints

- External brand name is **Memory on Cloud**; Vessel remains the internal console and API name.
- The hero headline is **Your Data. Any AI.** and the supporting statement is **Your AI may change. Your data stays.**
- `/console` and `/register` must retain their existing behavior and asset namespace.
- Homepage CTAs must use the real local `/register` route; `/console` is an account-management link.
- MCP, CLI, Skill, third-party AI compatibility, billing, paid plans, image-to-nutrition, and other autonomous agent workflows must be visibly marked **Planned** or **Coming soon**.
- Do not add a Memory storage model or claim a fourth persisted resource category.
- No third-party UI, icon, font, or tracking dependency is needed.
- The resulting layout must work at 390 px and at 1440 px widths, retain keyboard-visible focus, respect reduced-motion, and offer adequate button contrast.

---

### Task 1: Serve a separate marketing build

**Files:**
- Modify: `apps/api/src/vessel_service/main.py:17-61`
- Modify: `apps/api/tests/test_web_console.py:9-27`

**Interfaces:**
- Consumes: existing `create_app(..., web_dist_path: Path | None)`.
- Produces: `create_app(..., marketing_dist_path: Path | None)`, where `GET /` returns `marketing_dist_path/index.html` and `GET /assets/*` serves that directory'\''s assets.

- [ ] **Step 1: Write the failing server contract test**

```python
def test_marketing_homepage_and_console_use_separate_bundles(tmp_path: Path) -> None:
    console_dist = tmp_path / "console"
    marketing_dist = tmp_path / "marketing"
    (console_dist / "assets").mkdir(parents=True)
    (marketing_dist / "assets").mkdir(parents=True)
    (console_dist / "index.html").write_text('\''<script src="/console/assets/app.js"></script>'\'')
    (marketing_dist / "index.html").write_text('\''<script src="/assets/site.js"></script>'\'')
    (marketing_dist / "assets" / "site.js").write_text("window.memoryOnCloud = true;")
    app = create_app(
        settings=Settings(environment="test"),
        web_dist_path=console_dist,
        marketing_dist_path=marketing_dist,
    )
    assert asyncio.run(request("/")).status_code == 200
    assert "/assets/site.js" in asyncio.run(request("/")).text
    assert asyncio.run(request("/assets/site.js")).text == "window.memoryOnCloud = true;"
```

- [ ] **Step 2: Verify the test is red**

Run: `cd apps/api && PYTHONPATH=src .venv/bin/python -m pytest tests/test_web_console.py -q`

Expected: FAIL because `create_app` does not accept `marketing_dist_path`.

- [ ] **Step 3: Implement the smallest routing change**

```python
marketing_dist = marketing_dist_path or Path(__file__).resolve().parents[4] / "dist" / "marketing"

@application.get("/", include_in_schema=False)
def marketing_home() -> FileResponse:
    index = marketing_dist / "index.html"
    if not index.is_file():
        raise HTTPException(status_code=503, detail={"code": "MARKETING_SITE_NOT_BUILT"})
    return FileResponse(index, media_type="text/html", headers={"Cache-Control": "no-store"})

application.mount("/assets", StaticFiles(directory=marketing_dist / "assets", check_dir=False), name="marketing-assets")
```

Keep the existing console handlers and `/console/assets` mount untouched.

- [ ] **Step 4: Verify the server contract is green**

Run: `cd apps/api && PYTHONPATH=src .venv/bin/python -m pytest tests/test_web_console.py -q`

Expected: PASS.

### Task 2: Build the public homepage

**Files:**
- Create: `apps/marketing/index.html`
- Create: `apps/marketing/src/main.tsx`
- Create: `apps/marketing/src/site.css`
- Create: `apps/marketing/vite.config.ts`
- Modify: `package.json:5-9`

**Interfaces:**
- Consumes: React and ReactDOM already declared in root `package.json`; browser paths `/register` and `/console`.
- Produces: `npm run build:marketing`, which writes a standalone static site to `dist/marketing`; all browser-visible actions are anchors, with no API call or account creation.

- [ ] **Step 1: Write the failing browser specification**

```javascript
test("Memory on Cloud homepage explains storage and links to registration", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Your Data. Any AI." })).toBeVisible();
  await expect(page.getByText("Your AI may change. Your data stays.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Files" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Pages" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Apps" })).toBeVisible();
  await expect(page.getByText("Planned integrations")).toBeVisible();
  await expect(page.getByRole("link", { name: /start for free/i }).first()).toHaveAttribute("href", "/register");
});
```

- [ ] **Step 2: Verify the browser specification is red**

Run: `npx playwright test tests/e2e/marketing-home.spec.mjs --reporter=line`

Expected: FAIL because the current root route is unavailable.

- [ ] **Step 3: Implement structured semantic content and navigation**

Create a React tree with a fixed header and sections for Hero, problem statement, three storage categories, three-step connection flow, four concrete use cases, honest future integration panel, FAQ, and final CTA. Use a reusable `SectionLabel`, `PrimaryLink`, and `StorageCard` component inside `main.tsx`; use anchors for same-page navigation and direct `/register` links.

Use text such as:

```tsx
<h1>Your Data. <em>Any AI.</em></h1>
<p className="hero-statement">Your AI may change. Your data stays.</p>
<a className="button button-primary" href="/register">Start for free <span aria-hidden="true">→</span></a>
<p className="availability">Files, Pages, and Apps are available in the Vessel console. Integrations are planned.</p>
```

Do not include price amounts or artificial product-statistics claims. Label the integrations area `Planned integrations` and its entries `MCP`, `CLI`, `API`, and `Agent skills` as `Coming soon`.

- [ ] **Step 4: Create the build configuration**

```ts
export default defineConfig({
  root: "apps/marketing",
  base: "/",
  build: { outDir: "../../dist/marketing", emptyOutDir: true },
});
```

Add `"build:marketing": "tsc --noEmit -p apps/marketing/tsconfig.json && vite build --config apps/marketing/vite.config.ts"` and a minimal `apps/marketing/tsconfig.json` only if the root compiler cannot infer the new JSX sources.

- [ ] **Step 5: Write responsive visual rules**

Use native CSS custom properties with a deep navy background, a single restrained aqua accent, rounded 16px content groupings and pill buttons. Use an asymmetric desktop hero with a styled mock data canvas and a stacked small-screen layout. Avoid gradient meshes, decorative emojis, third-party fonts, irrelevant product claims, and excess card grids. Add `focus-visible` outlines, `prefers-reduced-motion` handling, and explicit mobile breakpoints.

- [ ] **Step 6: Verify browser behavior and production build**

Run:

```bash
npm run build:marketing
npm run build:web
npx playwright test tests/e2e/marketing-home.spec.mjs --reporter=line
```

Expected: both builds exit 0 and the homepage test passes at the configured desktop viewport.

### Task 3: Verify local delivery and visual responsiveness

**Files:**
- Modify: `README.md:3-20`
- Test: `tests/e2e/marketing-home.spec.mjs`

**Interfaces:**
- Consumes: built `dist/marketing` and the local FastAPI application.
- Produces: documented local URLs: public site at `/`, account console at `/console`, registration at `/register`.

- [ ] **Step 1: Extend the browser specification with a narrow viewport assertion**

```javascript
test("Memory on Cloud homepage remains usable on mobile", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto("/");
  await expect(page.getByRole("link", { name: /start for free/i }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "Files" })).toBeVisible();
  await context.close();
});
```

- [ ] **Step 2: Check the red-to-green test condition**

Run: `npx playwright test tests/e2e/marketing-home.spec.mjs --reporter=line`

Expected: the new narrow viewport case passes once the responsive CSS has shipped; screenshots reveal no horizontal page scroll.

- [ ] **Step 3: Document build and routing**

Update the README introduction and Web console section to identify Memory on Cloud as the public brand, explain that Vessel is the console/API code name, and specify `npm run build:marketing && npm run build:web` before starting FastAPI. State that the immediate entry point is `http://127.0.0.1:52003/`.

- [ ] **Step 4: Run targeted checks**

Run:

```bash
cd apps/api && PYTHONPATH=src .venv/bin/python -m pytest tests/test_web_console.py -q
cd ../..
npm run build:marketing
npm run build:web
npx playwright test tests/e2e/marketing-home.spec.mjs --reporter=line
git diff --check
```

Expected: pytest, TypeScript/Vite builds, two browser tests, and whitespace check all pass.

- [ ] **Step 5: Commit the verified change**

```bash
git add README.md apps/api/src/vessel_service/main.py apps/api/tests/test_web_console.py apps/marketing package.json package-lock.json tests/e2e/marketing-home.spec.mjs docs/superpowers/plans/2026-10-15-memory-on-cloud-homepage.md
git commit -m "feat: add Memory on Cloud homepage"
```
