import { Canvas, useFrame, useThree } from '@react-three/fiber'
import { RingMesh } from './RingMesh'
import { useJarvisStore } from '../store'

/**
 * Wrapper component hosting the R3F `<Canvas>` plus a subtle idle camera
 * drift. The drift is what gives the ring its "holographic" feel — without
 * it, the scene looks like a static SVG. Reduce-Motion disables the drift.
 */
export function ParticleRing({ particles = 512 }: { particles?: number }) {
  return (
    <Canvas
      camera={{ position: [0, 0, 3], fov: 50 }}
      gl={{ alpha: true, premultipliedAlpha: false, antialias: true }}
      dpr={[1, 2]}
    >
      <CameraDrift />
      <RingMesh particles={particles} />
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
