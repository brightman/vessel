import { chromium, expect } from '@playwright/test';
import assert from 'node:assert/strict';

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, reducedMotion: 'reduce' });
const errors = [];
page.on('pageerror', error => errors.push(error.message));

async function swipe(locator, direction) {
  const box = await locator.boundingBox();
  assert.ok(box, 'swipe row is visible');
  const startX = direction === 'left' ? box.x + box.width - 24 : box.x + 24;
  const endX = direction === 'left' ? startX - 115 : startX + 90;
  const y = box.y + Math.min(50, box.height / 2);
  await page.mouse.move(startX, y);
  await page.mouse.down();
  await page.mouse.move(endX, y, { steps: 8 });
  await page.mouse.up();
}

try {
  const url = process.env.WISELIFE_PROTOTYPE_URL ?? 'http://127.0.0.1:8766/iphone-day.html#demo';
  await page.goto(url);
  const rows = page.locator('#homeMoments [data-swipe-row]');
  await expect(rows).toHaveCount(4);

  const nonRecording = page.locator('#homeMoments [data-swipe-row="suzhou-arrival"]');
  await swipe(nonRecording, 'left');
  await nonRecording.locator('[data-swipe-action="delete"]').click();
  await expect(page.locator('#sheetTitle')).toContainText('删除');
  await page.locator('[data-confirm-delete]').click();
  await expect(page.locator('#homeMoments [data-record="suzhou-arrival"]')).toHaveCount(0);

  await page.reload();
  const first = page.locator('#homeMoments [data-swipe-row="merge-continuation"]');
  const second = page.locator('#homeMoments [data-swipe-row="merge-first"]');
  await swipe(first, 'right');
  await first.locator('[data-swipe-action="select"]').click();
  await expect(page.locator('[data-merge-toolbar]')).toContainText('1');
  await expect(page.locator('[data-merge-submit]')).toBeDisabled();
  await swipe(second, 'right');
  await second.locator('[data-swipe-action="select"]').click();
  await expect(page.locator('[data-merge-submit]')).toBeEnabled();
  await page.locator('[data-merge-submit]').click();
  await expect(page.locator('#sheetBody')).toContainText('原型演示');
  await page.locator('[data-confirm-merge]').click();
  await expect(page.locator('#homeMoments [data-merged-record]')).toHaveCount(1, { timeout: 5000 });
  await expect(page.locator('#homeMoments [data-record="merge-first"], #homeMoments [data-record="merge-continuation"]')).toHaveCount(0);
  await expect(page.locator('#toast')).toContainText('模拟合并完成');
  await page.locator('#homeMoments [data-merged-record] [data-record]').click();
  await expect(page.locator('#recordContent')).toContainText('模拟重新生成的摘要');
  await page.locator('#recordTextTab').click();
  await expect(page.locator('#recordContent')).toContainText('模拟重新生成的全文');

  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ passed: ['left swipe delete confirmation', 'right swipe adjacent long-recording selection', 'merge replaces sources with simulated regenerated item'], errors }, null, 2));
} finally {
  await browser.close();
}
