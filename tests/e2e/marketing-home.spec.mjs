import { test, expect } from "@playwright/test";

test("Karama.Cloud homepage explains storage and links to registration", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Your Data. Any AI." })).toBeVisible();
  await expect(page.getByText("Your AI may change. Your data stays.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Notes", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Apps", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Available & planned" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Sign up", exact: true }).first()).toHaveAttribute("href", "/register");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("Karama.Cloud homepage remains usable on mobile", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto("/");
    await expect(page.getByRole("link", { name: "Sign up", exact: true }).first()).toBeVisible();
    await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  } finally {
    await context.close();
  }
});

test("homepage controls retain brand colors and use shared focus and shape rules", async ({ page }) => {
  await page.goto("/");
  const primary = page.locator(".hero-actions").getByRole("link", { name: "Sign up", exact: true });
  await expect(primary).toHaveCSS("border-radius", "8px");
  await expect(primary).toHaveCSS("background-color", "rgb(30, 118, 106)");
  await expect(primary).toHaveAttribute("href", "/register");
  await primary.focus();
  await expect(primary).toBeFocused();
  expect(await primary.evaluate(element => getComputedStyle(element).boxShadow)).not.toBe("none");
  await page.locator(".hero-actions").getByRole("link", { name: "How it works" }).click();
  await expect(page).toHaveURL(/#how-it-works$/);
  const question = page.locator("summary").filter({ hasText: "Do I need a separate app?" });
  await question.focus();
  await page.keyboard.press("Enter");
  await expect(page.getByText("The management console is available now", { exact: false })).toBeVisible();
});
