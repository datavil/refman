import { defineConfig } from "vite";

export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        background: new URL("src/background.ts", import.meta.url).pathname,
        content: new URL("src/content.ts", import.meta.url).pathname,
        popup: new URL("popup.html", import.meta.url).pathname,
        options: new URL("options.html", import.meta.url).pathname
      },
      output: {
        entryFileNames: "[name].js",
        chunkFileNames: "chunks/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]"
      }
    }
  },
  test: {
    environment: "jsdom"
  }
});
