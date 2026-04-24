import type { HudState } from '@jarvis/bus'

/**
 * Per RESEARCH §Particle Ring Visual Design table (lines 854-862).
 *
 * `pulse` is the Hz of the sine term in the vertex shader.
 * `rotate` is rad/s of ring rotation.
 * `color` is either a hex "#RRGGBB" literal OR the sentinel 'theme'. In the
 * 'theme' case RingMesh resolves the value at render time from
 * `store.theme.arcReactorGlow`.
 * `densityMod` is a higher-level categorization RingMesh uses to drive
 * additional uniforms (e.g. `uOutwardWaveAmp` for `speaking`). The shader
 * itself doesn't see this enum — it only sees the resolved uniforms.
 */
export interface StateParams {
  pulse: number
  rotate: number
  color: string
  densityMod: 'none' | 'gaps' | 'wave' | 'thickness'
}

export const STATE_PARAMS: Record<HudState, StateParams> = {
  booting: { pulse: 0.3, rotate: 0.1, color: '#6b7280', densityMod: 'none' },
  reconfiguring: {
    pulse: 0.8,
    rotate: 0.3,
    color: '#F59E0B',
    densityMod: 'gaps',
  },
  idle: { pulse: 0.0, rotate: 0.0, color: 'theme', densityMod: 'none' },
  thinking: { pulse: 1.5, rotate: 1.0, color: 'theme', densityMod: 'none' },
  listening: {
    pulse: 3.0,
    rotate: 0.0,
    color: 'theme',
    densityMod: 'thickness',
  },
  speaking: { pulse: 2.0, rotate: 0.2, color: 'theme', densityMod: 'wave' },
  awaitingConfirmation: {
    pulse: 2.5,
    rotate: 0.0,
    color: '#F59E0B',
    densityMod: 'none',
  },
}

export const STATE_TO_IDX: Record<HudState, number> = {
  booting: 0,
  reconfiguring: 1,
  idle: 2,
  thinking: 3,
  listening: 4,
  speaking: 5,
  awaitingConfirmation: 6,
}

/** Arc-reactor-glow fallback (matches `useJarvisStore.theme.arcReactorGlow`). */
const DEFAULT_RGB = { r: 0.12, g: 0.53, b: 0.9 }

/** Parse `"#RRGGBB"` to `{r, g, b}` in 0..1 space for THREE.Color writes. */
export function parseHex(hex: string): { r: number; g: number; b: number } {
  const m = /^#([0-9a-f]{6})$/i.exec(hex)
  if (!m) return { ...DEFAULT_RGB }
  const n = parseInt(m[1]!, 16)
  return {
    r: ((n >> 16) & 0xff) / 255,
    g: ((n >> 8) & 0xff) / 255,
    b: (n & 0xff) / 255,
  }
}
