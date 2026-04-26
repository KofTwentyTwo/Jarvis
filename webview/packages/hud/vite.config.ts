import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'

// Strip `type="module"` and `crossorigin` from script/link tags in the
// emitted index.html. Vite hardcodes these for ES-module entry scripts even
// when rollupOptions.output.format is IIFE — they trigger CORS-mode fetching
// from the file:// null-origin in WKWebView, which silently fails the
// resource load. With an IIFE bundle, a plain `<script src=>` is what we
// want; the IIFE wraps everything in a self-executing function.
//
// Because plain `<script>` runs immediately (vs `type="module"` which is
// deferred until DOMContentLoaded), the script in <head> would execute
// before <body>'s `<div id="root">` exists — `document.getElementById('root')`
// returns null and React mounts nothing. Adding `defer` restores the
// deferred-until-parsed semantics modules had built in. Empirically
// observed: without `defer`, the IIFE runs but #root stays empty
// indefinitely (silent React no-op, no thrown error).
function stripModuleAttrs(): Plugin {
  return {
    name: 'jarvis-strip-module-attrs',
    enforce: 'post',
    transformIndexHtml(html) {
      return html
        .replace(/<script\s+type="module"\s+/g, '<script defer ')
        .replace(/\s+type="module"/g, ' defer')
        .replace(/\s+crossorigin(="[^"]*")?/g, '')
    },
  }
}

// Vite 8 configuration for the Jarvis HUD package.
// base: './' is REQUIRED for file:// loading in WKWebView (Pitfall 3). Without it,
// Vite emits absolute `/assets/...` references which 404 in a bundled file:// context.
//
// IIFE output format is REQUIRED for file:// + WKWebView. Vite's default ES-module
// output (`<script type="module">`) forces CORS-mode fetching regardless of the
// `crossorigin` attribute, and from a `file://` null-origin those fetches fail
// with type=2/code=0 resource errors — observed empirically as the JS bundle
// silently failing to load while the CSS (loaded via `<link>`) succeeded.
// Switching to IIFE drops the `type="module"` attribute on the entry script.
//
// Trade-off: IIFE disables code splitting and dynamic `import()` — the HUD must
// build as a single bundle. For the current scope (single-page R3F HUD)
// that's fine; the produced bundle is ~1.1 MB and code splitting wouldn't
// usefully shrink first-paint anyway because there are no routes.
//
// Long-term alternative: register a WKURLSchemeHandler with a custom `jarvis://`
// scheme so `'self'` resolves to a real origin and ES-module CORS works
// natively. That's a Phase 8 hardening task, not a P1 unblock.
export default defineConfig({
  base: './',
  plugins: [react(), stripModuleAttrs()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    emptyOutDir: true,
    sourcemap: 'hidden',
    rollupOptions: {
      output: {
        format: 'iife',
        // IIFE format forbids manual chunk splitting — single-bundle output.
        inlineDynamicImports: true,
        entryFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  server: { port: 5174, strictPort: true },
})
