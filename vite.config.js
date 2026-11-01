import { defineConfig } from "vite";
import OpenProps from "open-props";
import jitProps from "postcss-jit-props";
import customMedia from "postcss-custom-media";

// Vite is only the client/asset bundler now (the pages are server-rendered). It
// content-hashes the client bundle + CSS, copies public/, and writes a manifest
// the server reads to link the hashed assets. One origin: Express serves both the
// pages and dist/, so there is no dev proxy.
export default defineConfig({
  // Emit only the Open Props variables src/styles actually uses, and resolve
  // its named breakpoints (@media (--md-n-below)).
  css: { postcss: { plugins: [jitProps(OpenProps), customMedia()] } },
  build: {
    outDir: "dist",
    manifest: true,
    rollupOptions: { input: "src/client-entry.js" }
  }
});
