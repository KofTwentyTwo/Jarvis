import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Vite 8 configuration for the Jarvis HUD package.
// base: './' is REQUIRED for file:// loading in WKWebView (Pitfall 3). Without it,
// Vite emits absolute `/assets/...` references which 404 in a bundled file:// context.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    emptyOutDir: true,
    sourcemap: 'hidden',
    rollupOptions: {
      output: {
        chunkFileNames: 'assets/[name]-[hash].js',
        entryFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  server: { port: 5174, strictPort: true },
})
