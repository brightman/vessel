// Run from repository root with the prototype served on localhost:8767.
// Captures our own interactive prototype, without microphone or device access.
import { chromium } from 'playwright';
import { mkdir, copyFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const output = resolve('apps/wrist-notes/prototype/assets/wiselife');
const scratch = '/private/tmp/wiselife-website-media';
await mkdir(output, { recursive: true });
await mkdir(scratch, { recursive: true });
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 390, height: 844 }, colorScheme: 'light', reducedMotion: 'reduce',
  recordVideo: { dir: scratch, size: { width: 390, height: 844 } }
});
const page = await context.newPage();
await page.goto('http://127.0.0.1:8767/iphone-day.html', { waitUntil: 'networkidle' });
const captureStyle = `
  html,body{scroll-behavior:auto!important;scrollbar-gutter:auto!important}
  .site-header,.site-footer,.design-note,.design-index,.site-main>section:not(#product){display:none!important}
  .wiselife-site .design-stage{display:block!important;padding:0!important;min-height:0!important}
  .wiselife-site .phone-shell{height:844px!important;min-height:0!important;width:390px!important;padding:0!important;border:0!important;border-radius:0!important}
  .wiselife-site .phone-screen{border:0!important;border-radius:0!important}
`;
await page.addStyleTag({ content: captureStyle });
await page.evaluate(() => window.scrollTo(0, 0));
const cueStart = Date.now();
const cues = [];
const shot = async (name) => page.screenshot({ path: `${scratch}/${name}.png` });
const hold = async (label, duration) => { cues.push({ label, at: (Date.now() - cueStart) / 1000 }); await page.waitForTimeout(duration); };
await shot('day-overview');
await hold('回看一天', 4500);
await page.locator('#homeMoments [data-record="review"]').click();
await shot('note-summary');
await hold('抓住重点', 4500);
await page.locator('#recordTextTab').click();
await shot('note-transcript');
await hold('回到原文', 4000);
await page.locator('#closeSheet').click();
await page.locator('[data-view="ai"]').click();
await page.locator('#aiPrompts [data-ai-ask="这一天最值得跟进什么？"]').click();
await page.locator('.ai-answer').waitFor();
await page.locator('#aiConversation').scrollIntoViewIfNeeded();
await shot('ai-answer');
await hold('带着依据追问', 5500);
await page.locator('.ai-sources [data-record="review"]').first().click();
await hold('沿着来源找回细节', 3500);
await page.locator('#closeSheet').click();
await page.locator('[data-view="today"]').click();
await page.locator('#watchButton').click();
await page.locator('#sheet [data-hardware="ring"]').click();
await page.locator('[data-hardware-action="connect"]').click();
await shot('ring-connected');
await page.locator('[data-hardware-action="list"]').click();
await shot('hardware-connected');
await hold('连接你的随身设备', 3500);
const video = page.video();
await context.close();
await copyFile(await video.path(), `${scratch}/walkthrough-raw.webm`);
await writeFile(`${scratch}/cues.json`, JSON.stringify(cues, null, 2));
const thoughtPage = await browser.newPage({viewport:{width:390,height:844},colorScheme:'light',reducedMotion:'reduce'});
await thoughtPage.goto('http://127.0.0.1:8767/iphone-day.html', {waitUntil:'networkidle'});
await thoughtPage.addStyleTag({content:captureStyle});
await thoughtPage.locator('#allMomentsButton').click();
await thoughtPage.locator('#libraryMoments [data-record="thought-morning"]').click();
await thoughtPage.locator('#recordTextTab').click();
await thoughtPage.screenshot({path:`${scratch}/thought-transcript.png`});
await browser.close();
console.log(`Saved screenshots and video source to ${scratch}. Run render_website_media.py to build ${output}.`);
