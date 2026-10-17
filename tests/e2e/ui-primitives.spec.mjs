import { test, expect } from '@playwright/test';

test('shared controls preserve submit, keyboard navigation, focus and theme', async ({ page }) => {
  await page.goto('http://127.0.0.1:52004/console/tests/ui.html');
  await page.getByLabel('Name').fill('Vessel');
  await page.getByRole('button', { name: 'Submit' }).click();
  await expect(page.getByRole('status')).toHaveText('Vessel');
  await expect(page.getByRole('button', { name: 'Disabled' })).toBeDisabled();
  await page.getByRole('button', { name: 'Open dialog' }).click();
  await expect(page.getByRole('dialog', { name: 'Example dialog' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Open dialog' })).toBeFocused();
  await page.getByRole('button', { name: 'Actions' }).focus();
  await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menuitem', { name: 'Rename' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('button', { name: 'Actions' })).toBeFocused();
  await page.getByRole('button', { name: 'Help' }).hover();
  await expect(page.getByRole('tooltip')).toHaveText('More information');
  await expect(page.getByRole('button', { name: 'Submit' })).toHaveCSS('background-color', 'rgb(32, 93, 64)');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('button', { name: 'Open dialog' }).click();
  const dialogBox = await page.getByRole('dialog').boundingBox();
  expect(dialogBox.x).toBeGreaterThanOrEqual(16);
  expect(dialogBox.width).toBeLessThanOrEqual(358);
});
