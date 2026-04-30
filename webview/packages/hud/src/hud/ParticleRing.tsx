import { Canvas, useFrame, useThree } from '@react-three/fiber'
import { RingMesh } from './RingMesh'
import { CoreGlow } from './CoreGlow'
import { SegmentedRing } from './SegmentedRing'
import { Reticle } from './Reticle'
import { useJarvisStore } from '../store'

/**
 * Wrapper component hosting the R3F `<Canvas>` plus a subtle idle camera
 * drift. The drift is what gives the ring its "holographic" feel — without
 * it, the scene looks like a static SVG. Reduce-Motion disables the drift.
 *
 * Render order (back-to-front under additive blending):
 *   1. Wide halo disc — soft glow reaching out beyond the carrier ring
 *   2. Inner-glow halo — tighter cyan halo around the core
 *   3. Structural torus — engineered "ring" defining the carrier radius
 *   4. Particle ring stack (4 layers from RingMesh) — orbital data feel
 *   5. Bright cyan-white core sphere — focal point
 */
export function ParticleRing({ particles = 512 }: { particles?: number }) {
  return (
    <Canvas
      camera={{ position: [0, 0, 3], fov: 50 }}
      gl={{ alpha: true, premultipliedAlpha: false, antialias: true }}
      dpr={[1, 2]}
    >
      <CameraDrift />
      <CoreGlow />
      <Reticle />
      <RingMesh particles={particles} />
      {/* Outer chronograph scale — major every 8 minor (every 22.5°) */}
      <SegmentedRing
        radius={1.32}
        tickCount={64}
        tickWidth={0.008}
        tickHeight={0.05}
        rotationMultiplier={0.4}
        intensity={0.85}
        majorEvery={8}
        majorBoost={1.7}
      />
      {/* Inner short-tick scale, contra-rotating — major every 4 */}
      <SegmentedRing
        radius={1.05}
        tickCount={120}
        tickWidth={0.006}
        tickHeight={0.025}
        rotationMultiplier={-0.7}
        intensity={0.65}
        majorEvery={10}
        majorBoost={1.5}
      />
    </Canvas>
  )
}

/**
 * Slowly pans the camera in a tight Lissajous-like arc around z=3 so the
 * stacked rings feel parallaxed and 3D rather than perfectly orthogonal.
 * Suspended under Reduce Motion. Amplitude is small (≤ ±0.06 units) so
 * the ring stays centered and the chat panel below doesn't appear to
 * shift.
 */
function CameraDrift() {
  const { camera } = useThree()
  useFrame((state) => {
    const reduceMotion = useJarvisStore.getState().a11y.reduceMotion
    if (reduceMotion) {
      camera.position.set(0, 0, 3)
      camera.lookAt(0, 0, 0)
      return
    }
    const t = state.clock.elapsedTime
    camera.position.x = Math.sin(t * 0.18) * 0.06
    camera.position.y = Math.cos(t * 0.22) * 0.04
    camera.position.z = 3 + Math.sin(t * 0.11) * 0.05
    camera.lookAt(0, 0, 0)
  })
  return null
}
