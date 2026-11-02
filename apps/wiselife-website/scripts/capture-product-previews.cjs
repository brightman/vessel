// Captures the current product prototype copies, without rebuilding their UI.
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const origin = process.env.WISELIFE_ORIGIN || 'http://127.0.0.1:8789';
const out = path.resolve(__dirname, '../design-preview-v2/assets/hd');

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport: { width: 430, height: 950 }, deviceScaleFactor: 3, reducedMotion: 'reduce'
    });
    await context.addInitScript(() => {
      localStorage.setItem('wisenote.appearance', 'light');
      localStorage.setItem('wisenote.interfaceLanguage', 'en');
    });
    const phone = await context.newPage();
    await phone.goto(origin + '/product-demos/iphone/', { waitUntil: 'networkidle' });
    await phone.locator('.phone-screen').screenshot({ path: out + '/iphone-day.png' });
    await phone.locator('.phone-screen [data-view=ai]').click();
    await phone.locator('.phone-screen').screenshot({ path: out + '/iphone-ai.png' });

    const watch = await context.newPage();
    await watch.goto(origin + '/product-demos/watch/', { waitUntil: 'networkidle' });
    await watch.locator('[data-scene=recording]').click();
    await watch.waitForFunction(() => document.querySelector('#recordButton').dataset.mode === 'long');
    await watch.locator('.watch').screenshot({ path: out + '/watch-recording.png' });

    const mac = await browser.newPage({
      viewport: { width: 1440, height: 1010 }, deviceScaleFactor: 3, reducedMotion: 'reduce'
    });
    await mac.goto(origin + '/product-demos/mac/#knowledge', { waitUntil: 'networkidle' });
    await mac.locator('[data-prompt]').first().click();
    await mac.waitForFunction(() => document.querySelector('.kb-layout').textContent.includes('有两件值得继续'));
    await mac.locator('.window').screenshot({ path: out + '/mac-knowledge.png' });
    console.log('Captured iPhone Day / AI, Watch recording, and Mac knowledge base at 3×.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
