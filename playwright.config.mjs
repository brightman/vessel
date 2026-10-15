import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 90_000,
  workers: 1,
  use: {
    browserName: "chromium",
    baseURL: process.env.VESSEL_E2E_ORIGIN ?? "http://127.0.0.1:52003",
    viewport: { width: 1440, height: 900 },
  },
});
