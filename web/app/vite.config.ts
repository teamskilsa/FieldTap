// A plain, static Vite SPA. There is no server: `vite build` writes a dist/ that can be served from any file
// host, and nothing in the app talks to the network at runtime. The only cross-package dependency is the
// analysis engine next door, reached through the '@engine' alias so the contract types have exactly one home.
import { fileURLToPath } from 'node:url';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@engine': here('../engine/src'),
      '@': here('./src'),
    },
  },
  server: {
    port: 5273,
    strictPort: true,
    // The engine lives outside this package's root, so Vite has to be allowed to read it.
    fs: { allow: [here('.'), here('../engine')] },
  },
  worker: { format: 'es' },
  build: {
    target: 'es2022',
    sourcemap: false,
    // Vite's modulepreload polyfill fetches the app's own chunks on older browsers. Every browser that can run
    // this engine supports modulepreload natively, and dropping the polyfill leaves the bundle with no `fetch`
    // at all — which is the point: the app makes no network request at runtime.
    modulePreload: { polyfill: false },
  },
});
