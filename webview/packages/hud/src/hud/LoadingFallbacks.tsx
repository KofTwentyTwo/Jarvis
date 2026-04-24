import { useJarvisStore } from '../store'
import './loading-fallback.css'

/**
 * DOM-based state affordances for users with Reduce Motion enabled.
 *
 * The shader's `uReduceMotion` uniform zeros the ring's pulse + rotation,
 * so without these fallbacks users would see no indication of state. These
 * elements render alongside the Canvas, driven off the same store state.
 *
 * Subscribing via the hook here is fine — this is the LOW-frequency render
 * path (rerenders on hudState change, not 60 Hz). The Pitfall 1 guard only
 * applies inside `useFrame`.
 */
export function LoadingFallbacks() {
  const hudState = useJarvisStore((s) => s.hudState)
  const reduceMotion = useJarvisStore((s) => s.a11y.reduceMotion)

  // Persistent affordance regardless of reduceMotion — user waiting for
  // consent needs a visible indicator even if they don't have Reduce Motion on.
  if (hudState === 'awaitingConfirmation') {
    return (
      <div
        className="hud-fallback__corner-dot"
        data-hud-fallback="awaiting-corner"
        aria-label="Jarvis, waiting for your confirmation"
      />
    )
  }

  // Motion-allowed: the shader carries the full signal, no DOM needed.
  if (!reduceMotion) return null

  switch (hudState) {
    case 'thinking':
      return (
        <div
          className="hud-fallback__three-dots"
          data-hud-fallback="thinking-dots"
          aria-label="Jarvis, thinking"
        >
          <span />
        </div>
      )
    case 'listening':
      return (
        <div
          className="hud-fallback__pulse-dot"
          data-hud-fallback="listening-pulse"
          aria-label="Jarvis, listening"
        />
      )
    case 'speaking':
      return (
        <div
          className="hud-fallback__speaking-pulse"
          data-hud-fallback="speaking-pulse"
          aria-label="Jarvis, speaking"
        />
      )
    case 'reconfiguring':
      return (
        <div
          className="hud-fallback__three-dots hud-fallback__three-dots--warm"
          data-hud-fallback="reconfiguring-dots"
          aria-label="Jarvis, reconfiguring audio"
        >
          <span />
        </div>
      )
    case 'booting':
      return (
        <div
          className="hud-fallback__single-dot"
          data-hud-fallback="booting-dot"
          aria-label="Jarvis, starting up"
        />
      )
    case 'idle':
      return null
    default: {
      // Exhaustiveness check. `awaitingConfirmation` is handled above.
      const _exhaustive: never = hudState
      void _exhaustive
      return null
    }
  }
}
