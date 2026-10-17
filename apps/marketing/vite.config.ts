import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss()],
  root: "apps/marketing",
  base: "/",
  build: { outDir: "../../dist/marketing", emptyOutDir: true },
});
