import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { attachBus } from './bus/client'
import './theme/tokens.css'

// `attachBus()` runs in the page's default JS world (this module loads via
// `<script type="module" src="…">` in index.html). Swift installed the real
// `window.jarvisBus` inside `JarvisBusWorld` via Injection.js — WebKit
// content worlds isolate `webkit.messageHandlers`, so the default-world
// bundle can't reach them directly. `window.jarvisBus` IS visible though,
// because WebKit keeps `window` as one cross-world object (only *variables*
// are world-scoped). The H-02 fix in `@jarvis/bus` detects the pre-existing
// `window.jarvisBus` and attaches to it instead of replacing it, which
// routes every outbound `send()` back through the JarvisBusWorld-captured
// message handler reference. See `packages/bus/src/bridge.ts` for details.
attachBus()

const rootEl = document.getElementById('root')
if (!rootEl) {
  throw new Error('[jarvis-hud] #root not found')
}
const root = createRoot(rootEl)
root.render(
  <StrictMode>
    <App />
  </StrictMode>,
)

// Post uiReady after first commit. queueMicrotask (not setTimeout) fires on the
// same tick to avoid the Pitfall 7 token-delta race.
queueMicrotask(() => {
  void window.jarvisBus?.send({ type: 'uiReady' })
})
