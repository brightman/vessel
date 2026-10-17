import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "ui-primitives.spec.mjs",
  use: { browserName: "chromium", viewport: { width: 1440, height: 900 } },
  webServer: { command: "npm run dev:web", url: "http://127.0.0.1:52004/console/", reuseExistingServer: !process.env.CI },
});
