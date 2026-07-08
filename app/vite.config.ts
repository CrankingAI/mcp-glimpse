import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained dist/index.html — MCP App iframes are sandboxed/CSP-locked, so the view
// must make zero external requests at runtime. viteSingleFile inlines all JS/CSS into the HTML.
export default defineConfig({
  plugins: [viteSingleFile()],
  root: ".",
  build: { outDir: "dist", emptyOutDir: true, target: "esnext" },
});
