import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  resolve: { alias: { "@": new URL("./src", import.meta.url).pathname } },
  plugins: [tailwindcss()],
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
