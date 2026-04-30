import { useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import * as THREE from 'three'
import { useJarvisStore } from '../store'
import { STATE_PARAMS, parseHex } from './stateUniforms'

/**
 * Center reticle — four short crosshair tick marks at the cardinal axes
 * just outside the core sphere. Reads as a "targeting" element and is the
 * second-most-recognizable Jarvis HUD signature after the segmented ring.
 *
 * Crosshair length scales gently with HudState so it "breathes" with the
 * agent; rotates a quarter turn between idle and listening for tactile
 * feedback on state transitions.
 */
export function Reticle({ innerRadius = 0.32, length = 0.12, thickness = 0.012 }) {
  const groupRef = useRef<THREE.Group>(null)
  const matRef = useRef<THREE.MeshBasicMaterial>(null)

  useFrame((state) => {
    const s = useJarvisStore.getState()
    const reduceMotion = s.a11y.reduceMotion
    const themeColor = s.theme.arcReactorGlow
    const p = STATE_PARAMS[s.hudState]
    const t = state.clock.elapsedTime

    // Color
    const hex = p.color === 'theme' ? themeColor : p.color
    const { r, g, b } = parseHex(hex)
    if (matRef.current) {
      matRef.current.color.setRGB(r, g, b).lerp(new THREE.Color(0xebffff), 0.4)
    }

    // Slow per-state rotation so the four ticks sweep gently.
    if (groupRef.current) {
      groupRef.current.rotation.z = reduceMotion
        ? 0
        : t * p.rotate * 0.6
      const breath = reduceMotion ? 1 : 1 + Math.sin(t * p.pulse * 6.2831) * 0.04
      groupRef.current.scale.setScalar(breath)
    }
  })

  // Position 4 boxes around the inner radius at 0/90/180/270.
  return (
    <group ref={groupRef}>
      {[0, 90, 180, 270].map((deg) => {
        const rad = (deg * Math.PI) / 180
        const x = Math.cos(rad) * (innerRadius + length / 2)
        const y = Math.sin(rad) * (innerRadius + length / 2)
        return (
          <mesh
            key={deg}
            position={[x, y, 0]}
            rotation={[0, 0, rad]}
          >
            <boxGeometry args={[length, thickness, 0.005]} />
            <meshBasicMaterial
              ref={matRef}
              color={0xc8f5ff}
              transparent
              opacity={0.95}
              blending={THREE.AdditiveBlending}
              depthWrite={false}
            />
          </mesh>
        )
      })}
    </group>
  )
}
