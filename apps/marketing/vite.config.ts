import { defineConfig } from "vite";

export default defineConfig({
  root: "apps/marketing",
  base: "/",
  build: { outDir: "../../dist/marketing", emptyOutDir: true },
});
