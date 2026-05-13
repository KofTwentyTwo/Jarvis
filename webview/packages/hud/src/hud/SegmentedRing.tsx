import { useMemo, useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import * as THREE from 'three'
import { useJarvisStore } from '../store'
import { STATE_PARAMS, parseHex } from './stateUniforms'

/**
 * Iron Man HUD signature element: a segmented ring of radial tick marks at
 * a fixed radius, rotating together. Two of these stacked at slightly
 * different radii + counter-rotation = the recognizable Jarvis "scale ring".
 *
 * Implemented as a single InstancedMesh of small box meshes — each instance
 * is one tick. Rotation animates via group transform (cheap), color from
 * the resolved state palette.
 */
type SegmentedRingProps = {
  radius: number
  tickCount: number
  tickWidth: number
  tickHeight: number
  tickDepth?: number
  rotationMultiplier?: number    // sign + magnitude relative to state.rotate
  intensity?: number
  /** A subset of ticks brighter than the rest, every Nth — gives a
   * "major / minor mark" look like a chronograph. Default 8 (every 8th). */
  majorEvery?: number
  majorBoost?: number
}

export function SegmentedRing({
  radius,
  tickCount,
  tickWidth,
  tickHeight,
  tickDepth = 0.01,
  rotationMultiplier = 1.0,
  intensity = 1.0,
  majorEvery = 8,
  majorBoost = 1.6,
}: SegmentedRingProps) {
  const groupRef = useRef<THREE.Group>(null)
  const meshRef = useRef<THREE.InstancedMesh>(null)
  const matRef = useRef<THREE.MeshBasicMaterial>(null)
  const tmpMatrix = useMemo(() => new THREE.Matrix4(), [])
  const tmpPosition = useMemo(() => new THREE.Vector3(), [])
  const tmpQuat = useMemo(() => new THREE.Quaternion(), [])
  const tmpScale = useMemo(() => new THREE.Vector3(), [])
  const tmpEuler = useMemo(() => new THREE.Euler(), [])
  const tmpColor = useMemo(() => new THREE.Color(), [])

  // Per-instance brightness tints (major vs minor), set once at init.
  const tintArray = useMemo(() => {
    const arr = new Float32Array(tickCount * 3)
    for (let i = 0; i < tickCount; i++) {
      const isMajor = i % majorEvery === 0
      const b = isMajor ? majorBoost : 1.0
      arr[i * 3] = b
      arr[i * 3 + 1] = b
      arr[i * 3 + 2] = b
    }
    return arr
  }, [tickCount, majorEvery, majorBoost])

  // Position each tick around the circle on mount.
  const initialMatrices = useMemo(() => {
    const out: { pos: THREE.Vector3; quat: THREE.Quaternion; scale: THREE.Vector3 }[] = []
    for (let i = 0; i < tickCount; i++) {
      const theta = (i / tickCount) * Math.PI * 2
      const x = Math.cos(theta) * radius
      const y = Math.sin(theta) * radius
      const isMajor = i % majorEvery === 0
      const lengthScale = isMajor ? 1.45 : 1.0
      out.push({
        pos: new THREE.Vector3(x, y, 0),
        quat: new THREE.Quaternion().setFromEuler(
          new THREE.Euler(0, 0, theta + Math.PI / 2),
        ),
        scale: new THREE.Vector3(tickWidth, tickHeight * lengthScale, tickDepth),
      })
    }
    return out
  }, [tickCount, radius, tickWidth, tickHeight, tickDepth, majorEvery])

  // Apply initial transforms exactly once after mount.
  const appliedRef = useRef(false)
  useFrame((state) => {
    if (!meshRef.current || !groupRef.current) return

    if (!appliedRef.current) {
      for (let i = 0; i < tickCount; i++) {
        const m = initialMatrices[i]!
        tmpMatrix.compose(m.pos, m.quat, m.scale)
        meshRef.current.setMatrixAt(i, tmpMatrix)
      }
      meshRef.current.instanceMatrix.needsUpdate = true
      // Per-instance color tints (major ticks brighter).
      const colorAttr = new THREE.InstancedBufferAttribute(tintArray, 3)
      meshRef.current.geometry.setAttribute('aTint', colorAttr)
      appliedRef.current = true
    }

    const s = useJarvisStore.getState()
    const reduceMotion = s.a11y.reduceMotion
    const themeColor = s.theme.arcReactorGlow
    const p = STATE_PARAMS[s.hudState]
    const t = state.clock.elapsedTime

    // Spin the entire group as a unit — much cheaper than re-composing
    // matrices per frame.
    if (!reduceMotion) {
      const speed = p.rotate * rotationMultiplier * 0.4
      groupRef.current.rotation.z = t * speed
    } else {
      groupRef.current.rotation.z = 0
    }
    void tmpPosition
    void tmpQuat
    void tmpScale
    void tmpEuler

    // Color follows the resolved state color, with a hot-cyan lift.
    const hex = p.color === 'theme' ? themeColor : p.color
    const { r, g, b } = parseHex(hex)
    tmpColor.setRGB(r, g, b)
    const hot = new THREE.Color(0xc8f5ff)
    tmpColor.lerp(hot, 0.4)
    if (matRef.current) {
      matRef.current.color.copy(tmpColor)
      matRef.current.opacity = Math.min(1, intensity * 0.95)
    }
  })

  return (
    <group ref={groupRef}>
      <instancedMesh
        ref={meshRef}
        args={[undefined, undefined, tickCount]}
      >
        <boxGeometry args={[1, 1, 1]} />
        <meshBasicMaterial
          ref={matRef}
          color={0xc8f5ff}
          transparent
          opacity={0.95}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
        />
      </instancedMesh>
    </group>
  )
}
