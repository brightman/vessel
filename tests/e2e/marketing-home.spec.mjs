import { test, expect } from "@playwright/test";

test("Memory on Cloud homepage explains storage and links to registration", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Your Data. Any AI." })).toBeVisible();
  await expect(page.getByText("Your AI may change. Your data stays.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Pages", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Apps", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Planned integrations" })).toBeVisible();
  await expect(page.getByRole("link", { name: /get started/i }).first()).toHaveAttribute("href", "/register");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("Memory on Cloud homepage remains usable on mobile", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto("/");
    await expect(page.getByRole("link", { name: /get started/i }).first()).toBeVisible();
    await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  } finally {
    await context.close();
  }
});
