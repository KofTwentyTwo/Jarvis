import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { attachBus } from './bus/client'
import './theme/tokens.css'

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
