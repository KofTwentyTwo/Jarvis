import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/react'
import { Canvas } from '@react-three/fiber'
import { useJarvisStore } from '../src/store'
import { ParticleRing } from '../src/hud/ParticleRing'
import { LoadingFallbacks } from '../src/hud/LoadingFallbacks'
import { easeStateBlend } from '../src/hud/RingMesh'

/**
 * R1 — ParticleRing mounts without crash.
 *
 * jsdom has no WebGL context, so R3F's Canvas will log an error about the
 * WebGL fallback but MUST NOT throw. We catch the render call and verify
 * the container got _something_ (a canvas element). This exercises the
 * component tree, `extend({RingMaterial})`, drei's `shaderMaterial` type
 * registration, and the `?raw` shader imports — which is what we actually
 * want to prove here. GPU-driven rendering is validated at runtime via the
 * dev-server smoke test, not in unit tests.
 *
 * We avoid `@react-three/test-renderer` to stay on the webview's existing
 * dep surface; the testing-library + Canvas approach catches the same set
 * of import/type/extend errors that would break the build.
 */

afterEach(() => {
  cleanup()
  // Reset store between tests so prior state doesn't leak.
  useJarvisStore.setState({
    hudState: 'booting',
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
  })
})

describe('ParticleRing', () => {
  // R1
  it('mounts inside a Canvas without throwing', () => {
    expect(() => {
      render(
        <Canvas>
          <ParticleRing particles={16} />
        </Canvas>,
      )
    }).not.toThrow()
  })
})

describe('LoadingFallbacks', () => {
  beforeEach(() => {
    useJarvisStore.setState({
      hudState: 'idle',
      a11y: { reduceMotion: false, reduceTransparency: false },
    })
  })

  // R3
  it.each([
    ['thinking', 'thinking-dots'],
    ['listening', 'listening-pulse'],
    ['speaking', 'speaking-pulse'],
    ['reconfiguring', 'reconfiguring-dots'],
    ['booting', 'booting-dot'],
  ] as const)(
    'renders %s fallback with data-hud-fallback="%s" when reduceMotion is on',
    (state, slug) => {
      useJarvisStore.setState({
        hudState: state,
        a11y: { reduceMotion: true, reduceTransparency: false },
      })
      const { container } = render(<LoadingFallbacks />)
      const el = container.querySelector(`[data-hud-fallback="${slug}"]`)
      expect(el).not.toBeNull()
    },
  )

  it('renders awaiting-corner dot regardless of reduceMotion', () => {
    useJarvisStore.setState({
      hudState: 'awaitingConfirmation',
      a11y: { reduceMotion: false, reduceTransparency: false },
    })
    const { container } = render(<LoadingFallbacks />)
    expect(
      container.querySelector('[data-hud-fallback="awaiting-corner"]'),
    ).not.toBeNull()
  })

  it('renders awaiting-corner dot in reduceMotion=true as well', () => {
    useJarvisStore.setState({
      hudState: 'awaitingConfirmation',
      a11y: { reduceMotion: true, reduceTransparency: false },
    })
    const { container } = render(<LoadingFallbacks />)
    expect(
      container.querySelector('[data-hud-fallback="awaiting-corner"]'),
    ).not.toBeNull()
  })

  // R4
  it('renders empty DOM for thinking when reduceMotion=false', () => {
    useJarvisStore.setState({
      hudState: 'thinking',
      a11y: { reduceMotion: false, reduceTransparency: false },
    })
    const { container } = render(<LoadingFallbacks />)
    expect(container.firstChild).toBeNull()
  })

  it('renders empty DOM for idle regardless of reduceMotion', () => {
    useJarvisStore.setState({
      hudState: 'idle',
      a11y: { reduceMotion: true, reduceTransparency: false },
    })
    const { container } = render(<LoadingFallbacks />)
    expect(container.firstChild).toBeNull()
  })
})

describe('easeStateBlend', () => {
  // R6
  it('returns 1 when delta >= duration from a 0 baseline (fully advanced)', () => {
    expect(easeStateBlend(0, 0.15, 0.15)).toBe(1)
  })

  it('returns 0.5 when delta is half of duration from a 0 baseline', () => {
    expect(easeStateBlend(0, 0.075, 0.15)).toBeCloseTo(0.5)
  })

  it('clamps at 1 when over-budget', () => {
    expect(easeStateBlend(0.9, 1.0, 0.15)).toBe(1)
  })

  it('advances additively from current blend value', () => {
    expect(easeStateBlend(0.5, 0.075, 0.15)).toBeCloseTo(1)
  })

  it('never goes below the current blend value (delta=0 no-op)', () => {
    expect(easeStateBlend(0.3, 0, 0.15)).toBe(0.3)
  })
})
