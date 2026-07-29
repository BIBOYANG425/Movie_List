/**
 * Standalone vite config for the gallery smoke harness. Rooted at this
 * directory so smoke.html is the page; imports reach back into the repo
 * (components/gallery, types.ts) via relative paths, which vite serves
 * because the repo root is the workspace root.
 *
 *   npx vite --config scripts/gallery-smoke/vite.config.ts
 */
import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: here,
  server: {
    port: 5199,
    strictPort: true,
  },
});
