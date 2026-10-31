import { defineConfig } from "vite";

// Vite is only the client/asset bundler now (the pages are server-rendered). It
// content-hashes the client bundle + CSS, copies public/, and writes a manifest
// the server reads to link the hashed assets. One origin: Express serves both the
// pages and dist/, so there is no dev proxy.
export default defineConfig({
  build: {
    outDir: "dist",
    manifest: true,
    rollupOptions: { input: "src/client-entry.js" }
  }
});
