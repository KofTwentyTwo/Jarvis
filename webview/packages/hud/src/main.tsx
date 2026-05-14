import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { attachBus } from './bus/client'
import './theme/tokens.css'

// `attachBus()` runs in the page's default JS world (this module loads via
// `<script type="module" src="…">` in index.html). Swift's
// `WebviewBridge.installScriptHandlers` (since `fb41c5f`) registers the
// message handler on the same `WKContentWorld.page`, and Injection.js — also
// in the page world — has already stamped a minimal `window.jarvisBus` at
// document-start. `installJarvisBus()` here detects that pre-existing
// instance via a duck-type shape guard and returns early, leaving the
// Injection.js bus untouched so its captured handshake state and queued
// early messages are preserved. See `packages/bus/src/bridge.ts` for the
// full defensive-double-install rationale.
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
