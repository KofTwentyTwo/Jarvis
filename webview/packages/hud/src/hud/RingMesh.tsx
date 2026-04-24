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
 * Animated particle ring. One `<points>`, one material, all 7 HudStates are
 * the same shader with different uniforms.
 *
 * IMPORTANT — Pitfall 1 guard: state is read via `useJarvisStore.getState()`
 * inside `useFrame`, NOT via the subscribing hook. Subscribing here would
 * trigger React rerenders every frame and kill 60 FPS. See RESEARCH §Pitfall 1.
 *
 * IMPORTANT — Pitfall 8 guard: we do NOT dispose the useMemo'd geometry in a
 * cleanup. R3F's reconciler owns the geometry lifecycle; manual dispose
 * here would cause use-after-free on double-mount.
 */
export function RingMesh({ particles = 512 }: { particles?: number }) {
  const matRef = useRef<RingMaterialImpl | null>(null)

  const geometry = useMemo(() => {
    const geo = new THREE.BufferGeometry()
    const positions = new Float32Array(particles * 3)
    const radii = new Float32Array(particles)
    const thetas = new Float32Array(particles)
    for (let i = 0; i < particles; i++) {
      const t = (i / particles) * Math.PI * 2
      const r = 1.0 + (Math.random() - 0.5) * 0.05
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
  }, [particles])

  // Frame-local memory. Kept in refs so useFrame doesn't rerender.
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
    matRef.current.uPulseSpeed = reduceMotion ? 0 : currentRef.current.pulse
    matRef.current.uRotateSpeed = reduceMotion ? 0 : currentRef.current.rotate
    matRef.current.uReduceMotion = reduceMotion ? 1 : 0
    matRef.current.uOutwardWaveAmp =
      !reduceMotion && p.densityMod === 'wave' ? 0.03 : 0

    // Color: explicit hex OR the theme sentinel resolved from store.theme.
    const hex = p.color === 'theme' ? themeColor : p.color
    const { r, g, b } = parseHex(hex)
    matRef.current.uColorGlow.setRGB(r, g, b)
  })

  return (
    <points geometry={geometry}>
      <ringMaterial ref={matRef} transparent depthWrite={false} />
    </points>
  )
}
