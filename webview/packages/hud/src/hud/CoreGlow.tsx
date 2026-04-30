import { useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import * as THREE from 'three'
import { useJarvisStore } from '../store'
import { STATE_PARAMS, parseHex } from './stateUniforms'

/**
 * Arc-reactor core glow — three concentric meshes that don't depend on
 * `gl_PointSize` clamping (which caps at ~63 px on macOS Metal-backed
 * WebGL and made the point-sprite rings collapse into a single band):
 *
 *   1. center sphere   — small, bright cyan-white, additive
 *   2. inner halo disc — wide soft halo using sprite-style radial alpha
 *   3. structural torus — thin defined ring at the carrier radius
 *
 * All three are emissive + additive so they bloom against the dark backdrop.
 */
export function CoreGlow() {
  const sphereRef = useRef<THREE.Mesh>(null)
  const haloRef = useRef<THREE.Mesh>(null)
  const torusRef = useRef<THREE.Mesh>(null)
  const sphereMatRef = useRef<THREE.MeshBasicMaterial>(null)
  const haloMatRef = useRef<THREE.MeshBasicMaterial>(null)
  const torusMatRef = useRef<THREE.MeshBasicMaterial>(null)

  const tmpColor = useRef(new THREE.Color())

  useFrame((state) => {
    const s = useJarvisStore.getState()
    const reduceMotion = s.a11y.reduceMotion
    const themeColor = s.theme.arcReactorGlow
    const p = STATE_PARAMS[s.hudState]
    const t = state.clock.elapsedTime

    // Per-state color resolution (theme sentinel resolves to store color).
    const hex = p.color === 'theme' ? themeColor : p.color
    const { r, g, b } = parseHex(hex)
    tmpColor.current.setRGB(r, g, b)

    // Core sphere: bright white-cyan, gentle pulse on uPulseSpeed.
    if (sphereMatRef.current) {
      // hot-mix toward white for the core
      const hot = new THREE.Color(0xebffff)
      sphereMatRef.current.color.copy(hot).lerp(tmpColor.current, 0.25)
    }
    if (sphereRef.current) {
      const pulse = reduceMotion
        ? 1.0
        : 1.0 + Math.sin(t * p.pulse * 6.2831) * 0.06
      sphereRef.current.scale.setScalar(pulse)
    }

    // Halo disc: wide soft glow tied to the resolved color, slower pulse.
    if (haloMatRef.current) {
      haloMatRef.current.color.copy(tmpColor.current)
      const intensity = reduceMotion
        ? 0.45
        : 0.45 + Math.sin(t * p.pulse * 3.1) * 0.07
      haloMatRef.current.opacity = intensity
    }

    // Torus: defined "engineered" structural ring, slow rotate.
    if (torusMatRef.current) {
      torusMatRef.current.color.copy(tmpColor.current)
      // Lerp slightly toward white so the structural ring reads bright.
      const hot = new THREE.Color(0xb0e8ff)
      torusMatRef.current.color.lerp(hot, 0.35)
    }
    if (torusRef.current) {
      torusRef.current.rotation.z = reduceMotion ? 0 : t * p.rotate * 0.4
    }
  })

  return (
    <group>
      {/* Wide soft halo — large translucent disc with radial-attenuated alpha. */}
      <mesh ref={haloRef}>
        <circleGeometry args={[1.45, 64]} />
        <meshBasicMaterial
          ref={haloMatRef}
          color={0x4FC3F7}
          transparent
          opacity={0.45}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>

      {/* Structural carrier ring — thin torus at the inner radius. */}
      <mesh ref={torusRef}>
        <torusGeometry args={[0.78, 0.014, 16, 192]} />
        <meshBasicMaterial
          ref={torusMatRef}
          color={0xb0e8ff}
          transparent
          opacity={0.85}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
        />
      </mesh>

      {/* Bright cyan-white core. Small but emissive — it's the brightest
       * thing in the scene, drawing the eye to the center. */}
      <mesh ref={sphereRef}>
        <sphereGeometry args={[0.18, 32, 24]} />
        <meshBasicMaterial
          ref={sphereMatRef}
          color={0xebffff}
          transparent
          opacity={0.95}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
        />
      </mesh>

      {/* Inner-glow halo around the core (smaller diffuse disc). */}
      <mesh>
        <circleGeometry args={[0.42, 48]} />
        <meshBasicMaterial
          color={0x9be8ff}
          transparent
          opacity={0.35}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>
    </group>
  )
}
