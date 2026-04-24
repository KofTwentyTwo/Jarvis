import { shaderMaterial } from '@react-three/drei'
import { extend, type ThreeElements } from '@react-three/fiber'
import * as THREE from 'three'
import vertexShader from './ring.vert.glsl?raw'
import fragmentShader from './ring.frag.glsl?raw'

/**
 * drei's `shaderMaterial` is a factory that returns a class constructor of a
 * `THREE.ShaderMaterial` subclass with typed uniform fields. `extend({...})`
 * registers it as a JSX intrinsic element (`<ringMaterial>`) under R3F's
 * reconciler.
 *
 * Namespace augmentation below teaches TypeScript that `<ringMaterial>` is a
 * valid JSX element whose props are the union of a `shaderMaterial`'s props +
 * our custom uniforms. R3F 9 moved away from `ReactThreeFiber.Object3DNode`
 * and exposes `ThreeElements` directly from `@react-three/fiber`.
 */
export const RingMaterial = shaderMaterial(
  {
    uTime: 0,
    uStateIdx: 0,
    uStateBlend: 1,
    uPrevStateIdx: 0,
    uPulseSpeed: 1.0,
    uRotateSpeed: 0.0,
    uColorGlow: new THREE.Color('#1E88E5'),
    uReduceMotion: 0,
    uOutwardWaveAmp: 0,
  },
  vertexShader,
  fragmentShader,
)

extend({ RingMaterial })

declare module '@react-three/fiber' {
  interface ThreeElements {
    ringMaterial: ThreeElements['shaderMaterial'] & {
      uTime?: number
      uStateIdx?: number
      uStateBlend?: number
      uPrevStateIdx?: number
      uPulseSpeed?: number
      uRotateSpeed?: number
      uColorGlow?: THREE.Color
      uReduceMotion?: number
      uOutwardWaveAmp?: number
    }
  }
}
