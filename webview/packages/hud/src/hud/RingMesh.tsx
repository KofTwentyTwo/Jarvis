import { useMemo, useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import * as THREE from 'three'
import { useJarvisStore } from '../store'
import { STATE_PARAMS, STATE_TO_IDX, parseHex } from './stateUniforms'
import { RingMaterial, type RingMaterialImpl } from './RingMaterial'

// Side-effect import: registers <ringMaterial> with R3F's reconciler via
// `extend({ RingMaterial })` at module load. Exported as a value so the
// unused-import linter doesn't strip it in tree-shaken builds.
void RingMaterial

/**
 * Pure easing helper exported for unit testing.
 * Advances `current` toward 1 by `delta / duration`, clamped to [0, 1].
 * When `current === 0` and `delta === duration`, returns 1.
 */
export function easeStateBlend(
  current: number,
  delta: number,
  duration: number,
): number {
  if (duration <= 0) return 1
  return Math.min(1, current + delta / duration)
}

/**
 * Per-layer configuration. Each layer renders one `<points>` with the same
 * shader but different uniforms. Stacking 4 layers with `AdditiveBlending`
 * produces the arc-reactor feel: bright cyan-white core, layered cyan
 * carrier rings, soft halo bloom.
 *
 *   layer 0 — `core`:    tight inner ring (r≈0.55), dense, white-hot center
 *   layer 1 — `inner`:   carrier ring at r≈0.85, mid density, cyan tint
 *   layer 2 — `outer`:   sparse outer arc at r≈1.15, slow contra-rotate
 *   layer 3 — `halo`:    soft diffuse glow (large point sprites, low density)
 */
type LayerConfig = {
  id: 'core' | 'inner' | 'outer' | 'halo'
  particles: number
  radiusScale: number
  pointSize: number
  intensity: number
  coreBoost: number
  phase: number
  rotateMultiplier: number   // multiplies the state-driven rotate speed
  pulseMultiplier: number    // multiplies the state-driven pulse speed
  alphaJitter: number        // small radius jitter so dense rings don't streak
}

const LAYERS: LayerConfig[] = [
  {
    id: 'core',
    particles: 384,
    radiusScale: 0.55,
    pointSize: 5.5,
    intensity: 1.4,
    coreBoost: 0.85,
    phase: 0.0,
    rotateMultiplier: 1.4,
    pulseMultiplier: 1.6,
    alphaJitter: 0.02,
  },
  {
    id: 'inner',
    particles: 512,
    radiusScale: 0.85,
    pointSize: 4.0,
    intensity: 1.0,
    coreBoost: 0.40,
    phase: 0.0,
    rotateMultiplier: 1.0,
    pulseMultiplier: 1.0,
    alphaJitter: 0.03,
  },
  {
    id: 'outer',
    particles: 256,
    radiusScale: 1.15,
    pointSize: 3.0,
    intensity: 0.65,
    coreBoost: 0.0,
    phase: Math.PI / 6,
    rotateMultiplier: -0.6,    // contra-rotate for parallax depth
    pulseMultiplier: 0.5,
    alphaJitter: 0.05,
  },
  {
    id: 'halo',
    particles: 96,
    radiusScale: 1.0,
    pointSize: 16.0,
    intensity: 0.35,
    coreBoost: 0.0,
    phase: 0.0,
    rotateMultiplier: 0.2,
    pulseMultiplier: 0.4,
    alphaJitter: 0.10,
  },
]

/**
 * Animated arc-reactor ring stack. 4 concentric rings, all rendered through
 * the same shader, stacked with `THREE.AdditiveBlending` so bright cores
 * naturally bloom without a post-processing pass.
 *
 * IMPORTANT — Pitfall 1 guard: state is read via `useJarvisStore.getState()`
 * inside `useFrame`, NOT via the subscribing hook. Subscribing here would
 * trigger React rerenders every frame and kill 60 FPS.
 *
 * IMPORTANT — Pitfall 8 guard: we do NOT dispose the useMemo'd geometries in
 * a cleanup. R3F's reconciler owns geometry lifecycle; manual dispose here
 * would cause use-after-free on double-mount.
 */
export function RingMesh({ particles = 512 }: { particles?: number }) {
  // The `particles` prop now scales the inner-layer count; other layers are
  // proportional. The default 512 keeps the existing test contract.
  const layers = useMemo(() => {
    return LAYERS.map((cfg) => ({
      ...cfg,
      particles:
        cfg.id === 'inner'
          ? particles
          : Math.max(64, Math.round((cfg.particles / 512) * particles)),
    }))
  }, [particles])

  return (
    <group>
      {layers.map((cfg) => (
        <RingLayer key={cfg.id} cfg={cfg} />
      ))}
    </group>
  )
}

function RingLayer({ cfg }: { cfg: LayerConfig }) {
  const matRef = useRef<RingMaterialImpl | null>(null)

  const geometry = useMemo(() => {
    const geo = new THREE.BufferGeometry()
    const positions = new Float32Array(cfg.particles * 3)
    const radii = new Float32Array(cfg.particles)
    const thetas = new Float32Array(cfg.particles)
    for (let i = 0; i < cfg.particles; i++) {
      const t = (i / cfg.particles) * Math.PI * 2
      // Per-layer alpha jitter expressed as a small radius perturbation so
      // dense rings don't appear as a single hard line.
      const r = 1.0 + (Math.random() - 0.5) * cfg.alphaJitter * 2
      positions[i * 3 + 0] = Math.cos(t) * r
      positions[i * 3 + 1] = Math.sin(t) * r
      positions[i * 3 + 2] = 0
      radii[i] = r
      thetas[i] = t
    }
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3))
    geo.setAttribute('aRadius', new THREE.BufferAttribute(radii, 1))
    geo.setAttribute('aTheta', new THREE.BufferAttribute(thetas, 1))
    return geo
  }, [cfg.particles, cfg.alphaJitter])

  const currentRef = useRef({ stateIdx: 0, pulse: 0, rotate: 0, blend: 1 })
  const targetIdxRef = useRef(0)

  useFrame((_, delta) => {
    if (!matRef.current) return

    const s = useJarvisStore.getState()
    const hudState = s.hudState
    const reduceMotion = s.a11y.reduceMotion
    const themeColor = s.theme.arcReactorGlow
    const p = STATE_PARAMS[hudState]
    const targetIdx = STATE_TO_IDX[hudState]

    // On state change: snapshot previous index and restart the 150ms crossfade.
    if (targetIdxRef.current !== targetIdx) {
      matRef.current.uPrevStateIdx = currentRef.current.stateIdx
      currentRef.current.stateIdx = targetIdx
      currentRef.current.blend = 0
      targetIdxRef.current = targetIdx
    }

    // 150ms eased crossfade between state uniforms.
    currentRef.current.blend = easeStateBlend(
      currentRef.current.blend,
      delta,
      0.15,
    )

    // Smooth pulse/rotate morphing so param jumps don't cause visible pops.
    const ease = Math.min(1, delta * 6)
    currentRef.current.pulse +=
      (p.pulse - currentRef.current.pulse) * ease
    currentRef.current.rotate +=
      (p.rotate - currentRef.current.rotate) * ease

    matRef.current.uTime += delta
    matRef.current.uStateIdx = currentRef.current.stateIdx
    matRef.current.uStateBlend = currentRef.current.blend
    matRef.current.uPulseSpeed = reduceMotion
      ? 0
      : currentRef.current.pulse * cfg.pulseMultiplier
    matRef.current.uRotateSpeed = reduceMotion
      ? 0
      : currentRef.current.rotate * cfg.rotateMultiplier
    matRef.current.uReduceMotion = reduceMotion ? 1 : 0
    matRef.current.uOutwardWaveAmp =
      !reduceMotion && p.densityMod === 'wave' ? 0.03 : 0

    // Per-layer constants (re-applied each frame so HMR shader edits update live).
    matRef.current.uIntensity = cfg.intensity
    matRef.current.uCoreBoost = cfg.coreBoost
    matRef.current.uPhase = cfg.phase
    matRef.current.uRadiusScale = cfg.radiusScale
    matRef.current.uPointSize = cfg.pointSize

    // Color: explicit hex OR the theme sentinel resolved from store.theme.
    const hex = p.color === 'theme' ? themeColor : p.color
    const { r, g, b } = parseHex(hex)
    matRef.current.uColorGlow.setRGB(r, g, b)
  })

  return (
    <points geometry={geometry}>
      <ringMaterial
        ref={matRef}
        transparent
        depthWrite={false}
        blending={THREE.AdditiveBlending}
      />
    </points>
  )
}
