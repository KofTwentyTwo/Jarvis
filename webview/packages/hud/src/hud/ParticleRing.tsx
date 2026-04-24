import { Canvas } from '@react-three/fiber'
import { RingMesh } from './RingMesh'

/**
 * Wrapper component that hosts the R3F `<Canvas>`. Plan 03-03 layers
 * post-processing + shader uniforms; Plan 03-04 adds overlay panels.
 */
export function ParticleRing({ particles = 512 }: { particles?: number }) {
  return (
    <Canvas
      camera={{ position: [0, 0, 3], fov: 50 }}
      gl={{ alpha: true, premultipliedAlpha: false, antialias: true }}
      dpr={[1, 2]}
    >
      <RingMesh particles={particles} />
    </Canvas>
  )
}
