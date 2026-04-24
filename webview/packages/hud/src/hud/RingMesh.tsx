import { useMemo } from 'react'
import * as THREE from 'three'

/**
 * Minimal 512-particle ring. Static — no state animation yet. Plan 03-03
 * replaces `<pointsMaterial>` with drei's `shaderMaterial` and wires per-state
 * uniforms (idle/listening/thinking/speaking/etc.).
 */
export function RingMesh({ particles = 512 }: { particles?: number }) {
  const geometry = useMemo(() => {
    const geo = new THREE.BufferGeometry()
    const positions = new Float32Array(particles * 3)
    for (let i = 0; i < particles; i++) {
      const t = (i / particles) * Math.PI * 2
      const r = 1.0 + (Math.random() - 0.5) * 0.05
      positions[i * 3 + 0] = Math.cos(t) * r
      positions[i * 3 + 1] = Math.sin(t) * r
      positions[i * 3 + 2] = 0
    }
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3))
    return geo
  }, [particles])

  return (
    <points geometry={geometry}>
      <pointsMaterial
        size={0.03}
        color="#1E88E5"
        sizeAttenuation
        transparent
        depthWrite={false}
      />
    </points>
  )
}
