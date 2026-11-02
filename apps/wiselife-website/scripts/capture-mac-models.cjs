// Capture the actual Mac prototype's loaded LLM and service state, without redrawing UI.
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const origin = process.env.WISELIFE_ORIGIN || 'http://127.0.0.1:8789';

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1010 }, deviceScaleFactor: 3, reducedMotion: 'reduce'
    });
    await page.goto(origin + '/product-demos/mac/#overview', { waitUntil: 'networkidle' });
    await page.locator('#navigation [data-page=models]').click();
    await page.evaluate(() => document.fonts.ready);
    await page.locator('#main').evaluate(main => {
      const services = main.querySelector('.api-grid').closest('.card');
      main.scrollTop = services.getBoundingClientRect().top - main.getBoundingClientRect().top - 24;
    });
    const model = page.locator('.model-card').first();
    assert((await model.innerText()).includes('Qwen3-4B'));
    assert((await model.locator('.badge.green').first().innerText()).includes('已加载'));
    assert.equal(await page.locator('.api-grid > div').first().locator('strong').innerText(), '可用');
    assert((await page.locator('#service-status').innerText()).includes('局域网服务已开启'));
    const window = page.locator('.window');
    const bounds = await window.boundingBox();
    const modelBounds = await model.boundingBox();
    assert(modelBounds.y >= bounds.y && modelBounds.y + modelBounds.height <= bounds.y + bounds.height);
    const output = root + '/design-preview-v2/assets/hd/mac-models.png';
    await window.screenshot({ path: output });
    console.log(JSON.stringify({ output, bounds, scrollTop: await page.locator('#main').evaluate(el => el.scrollTop),
      scale: 3, state: 'Actual sample prototype: Qwen3-4B loaded; LLM API available; local service enabled.' }, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
