import { describe, it, expect } from 'vitest'
import type { HudState } from '@jarvis/bus'
import {
  STATE_PARAMS,
  STATE_TO_IDX,
  parseHex,
} from '../src/hud/stateUniforms'
import vertexShader from '../src/hud/ring.vert.glsl?raw'
import fragmentShader from '../src/hud/ring.frag.glsl?raw'

const ALL_STATES: HudState[] = [
  'booting',
  'reconfiguring',
  'idle',
  'thinking',
  'listening',
  'speaking',
  'awaitingConfirmation',
]

// Table from RESEARCH §Particle Ring Visual Design (lines 854-862).
// pulse is Hz, rotate is rad/s. color is hex or 'theme' sentinel.
const TABLE: Array<{
  state: HudState
  pulse: number
  rotate: number
  color: string
}> = [
  { state: 'booting', pulse: 0.3, rotate: 0.1, color: '#6b7280' },
  { state: 'reconfiguring', pulse: 0.8, rotate: 0.3, color: '#F59E0B' },
  { state: 'idle', pulse: 0.0, rotate: 0.0, color: 'theme' },
  { state: 'thinking', pulse: 1.5, rotate: 1.0, color: 'theme' },
  { state: 'listening', pulse: 3.0, rotate: 0.0, color: 'theme' },
  { state: 'speaking', pulse: 2.0, rotate: 0.2, color: 'theme' },
  { state: 'awaitingConfirmation', pulse: 2.5, rotate: 0.0, color: '#F59E0B' },
]

describe('stateUniforms', () => {
  // U1
  it('STATE_PARAMS has entries for all 7 HudStates', () => {
    const keys = new Set(Object.keys(STATE_PARAMS))
    expect(keys).toEqual(new Set(ALL_STATES))
    expect(keys.size).toBe(7)
  })

  // U2
  it.each(TABLE)('STATE_PARAMS[$state].pulse === $pulse', ({ state, pulse }) => {
    expect(STATE_PARAMS[state].pulse).toBe(pulse)
  })

  // U3
  it.each(TABLE)(
    'STATE_PARAMS[$state].rotate === $rotate',
    ({ state, rotate }) => {
      expect(STATE_PARAMS[state].rotate).toBe(rotate)
    },
  )

  // U4
  it('STATE_TO_IDX assigns unique 0..6 indices across all 7 states', () => {
    const values = Object.values(STATE_TO_IDX)
    expect(new Set(values).size).toBe(7)
    expect(values.slice().sort((a, b) => a - b)).toEqual([0, 1, 2, 3, 4, 5, 6])
    for (const s of ALL_STATES) {
      expect(typeof STATE_TO_IDX[s]).toBe('number')
      expect(Number.isInteger(STATE_TO_IDX[s])).toBe(true)
    }
  })

  // U5
  it.each(TABLE)(
    'STATE_PARAMS[$state].color === $color',
    ({ state, color }) => {
      expect(STATE_PARAMS[state].color).toBe(color)
    },
  )

  it('exactly 4 states carry an explicit hex color; 3 use the "theme" sentinel', () => {
    // booting (grey), reconfiguring (amber), awaitingConfirmation (amber) = hex
    // idle, thinking, listening, speaking = theme
    // (per RESEARCH table — booting is grey, the others share amber)
    const hex = ALL_STATES.filter((s) => STATE_PARAMS[s].color !== 'theme')
    const theme = ALL_STATES.filter((s) => STATE_PARAMS[s].color === 'theme')
    expect(hex.sort()).toEqual(
      ['awaitingConfirmation', 'booting', 'reconfiguring'].sort(),
    )
    expect(theme.sort()).toEqual(
      ['idle', 'listening', 'speaking', 'thinking'].sort(),
    )
  })

  it('parseHex returns the arc-reactor-glow default for malformed hex', () => {
    const got = parseHex('nope')
    expect(got.r).toBeCloseTo(0.12)
    expect(got.g).toBeCloseTo(0.53)
    expect(got.b).toBeCloseTo(0.9)
  })

  it('parseHex round-trips a 6-hex string to 0..1 RGB', () => {
    const got = parseHex('#6b7280')
    expect(got.r).toBeCloseTo(0x6b / 255)
    expect(got.g).toBeCloseTo(0x72 / 255)
    expect(got.b).toBeCloseTo(0x80 / 255)
  })

  // U6
  it('ring.vert.glsl + ring.frag.glsl import via ?raw as non-empty strings', () => {
    expect(typeof vertexShader).toBe('string')
    expect(typeof fragmentShader).toBe('string')
    expect(vertexShader.length).toBeGreaterThanOrEqual(100)
    expect(fragmentShader.length).toBeGreaterThanOrEqual(100)
    expect(vertexShader).toContain('uniform float uTime')
    expect(fragmentShader).toContain('uniform vec3 uColorGlow')
  })
})
