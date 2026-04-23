import { installJarvisBus, type BusOutbound } from '@jarvis/bus'
import { useJarvisStore } from '../store'

/**
 * Install the window.jarvisBus bridge and register an exhaustive outbound
 * dispatcher. Every BusOutbound case has a switch arm; the default branch
 * uses `const _exhaustive: never = msg` (NO `as never` cast) — adding a new
 * case to BusOutbound without a handler here fails `tsc --strict`.
 *
 * Plan 03-02 scaffolds this dispatcher. Plans 03-03 and 03-04 replace the
 * no-op arms (tokenDelta, toolCallStart/End, turnStarted/Ended, audioLevel)
 * with real store mutations without changing the switch's shape.
 */
export function attachBus(): void {
  installJarvisBus({
    onDecodeError: (e, raw) => {
      // eslint-disable-next-line no-console
      console.error('[bus] decode failed:', e, raw)
    },
  })
  window.jarvisBus.onOutbound((msg: BusOutbound) => {
    switch (msg.type) {
      case 'hello':
        // Handled by the bridge's auto-ack prior to handler registration.
        break
      case 'hudState':
        useJarvisStore.getState().setHudState(msg.state)
        break
      case 'tokenDelta':
        // Plan 03-04 wires appendTokenToLastText.
        break
      case 'audioLevel':
        // Plan 03-03 may wire an audio-reactive uniform; ignore for now.
        break
      case 'toolCallStart':
        // Plan 03-04 wires upsertToolCall.
        break
      case 'toolCallEnd':
        // Plan 03-04 wires upsertToolCall.
        break
      case 'turnStarted':
        // Plan 03-04 may push a delimiter event.
        break
      case 'turnEnded':
        // Plan 03-04.
        break
      default: {
        const _exhaustive: never = msg
        void _exhaustive
        // eslint-disable-next-line no-console
        console.warn('[bus] unknown outbound:', msg)
      }
    }
  })
}
