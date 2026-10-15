import { defineConfig } from "vite";

export default defineConfig({
  root: "apps/web",
  base: "/console/",
  server: {
    host: "127.0.0.1",
    port: 52004,
    strictPort: true,
    proxy: { "/v1": "http://127.0.0.1:52003" },
  },
  build: { outDir: "../../dist/console", emptyOutDir: true },
});
