---
phase: 03-hud
plan: 03
type: execute
wave: 2
depends_on: [03-02]
files_modified:
  - webview/packages/hud/src/hud/RingMesh.tsx
  - webview/packages/hud/src/hud/ring.vert.glsl
  - webview/packages/hud/src/hud/ring.frag.glsl
  - webview/packages/hud/src/hud/stateUniforms.ts
  - webview/packages/hud/src/hud/RingMaterial.ts
  - webview/packages/hud/src/hud/ParticleRing.tsx
  - webview/packages/hud/src/hud/loading-fallback.css
  - webview/packages/hud/src/hud/LoadingFallbacks.tsx
  - webview/packages/hud/src/App.tsx
  - webview/packages/hud/tests/stateUniforms.test.ts
  - webview/packages/hud/tests/RingMesh.test.tsx
autonomous: true
requirements: [HUD-02]
tags: [typescript, react19, r3f, drei, glsl, shaders, hud-state, reduce-motion, a11y]

assumptions:
  - "Plan 03-02 has landed `webview/packages/hud/` with React 19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 store + static RingMesh. This plan replaces the static RingMesh with a shader-driven animated version."
  - "drei 10.7's `shaderMaterial(uniforms, vert, frag)` API is available (verified in RESEARCH §Standard Stack). If the API surface has moved, fallback is a hand-rolled `THREE.ShaderMaterial` subclass (~30 LOC extra)."
  - "Vite 8's `?raw` import suffix works for `.glsl`, `.vert`, `.frag`. If it doesn't, fallback is inline template strings in `stateUniforms.ts`."
  - "All 7 HudStates render via ONE shader — only uniforms differ. The 7 non-shader loading fallbacks (Reduce Motion) render as simple DOM <div> elements gated on `a11y.reduceMotion` per RESEARCH §Particle Ring Visual Design table."
  - "Per RESEARCH §Pitfall 1: ring mesh uses `useJarvisStore.getState()` inside `useFrame`, NOT `useJarvisStore(state => ...)` hook — otherwise React rerenders per frame and kills 60 FPS."
  - "Per RESEARCH §Pitfall 8: do NOT manually dispose geometry in useMemo cleanup — R3F reconciler handles it."
  - "`visibility` bus message (RESEARCH Open Q #1) is NOT in this plan's scope. Plan 03-05's ChatPanel/bridge integration will add it IF needed; this plan's ring runs useFrame unconditionally. A follow-up plan deals with the battery-pause concern if profiling reveals it."
  - "512 particles target (RESEARCH §A3) is the scaffold number. If 60 FPS degrades in WKWebView Metal-backend compositing, plan a fallback to 256 and document in SUMMARY.md."

must_haves:
  truths:
    - "`RingMesh` renders a `<points>` with `BufferGeometry` of N particles (default 512) on a unit ring, with a drei `shaderMaterial`-constructed `<ringMaterial>` material"
    - "7 HudState → uniform-param mappings exist in `stateUniforms.ts`: booting, reconfiguring, idle, thinking, listening, speaking, awaitingConfirmation — all match the RESEARCH §Particle Ring Visual Design table values verbatim"
    - "`useFrame` hook inside RingMesh reads HudState via `useJarvisStore.getState().hudState` (NOT via `useJarvisStore(selector)` hook — verified by grep in tests)"
    - "State transition runs a 150ms crossfade: on state change, `uPrevStateIdx` captures the old index and `uStateBlend` eases from 0 → 1 over ~0.15s (per RESEARCH §Pattern 3 line 593)"
    - "Reduce Motion fallback: when `a11y.reduceMotion === true`, shader uniform `uReduceMotion = 1` zeros the pulse + rotate terms; separate DOM fallback elements (loading dots, static indicator) render in `<LoadingFallbacks />` and are gated on the same state"
    - "CSS animations in `loading-fallback.css` use `@media (prefers-reduced-motion: reduce)` as a defense-in-depth — kept CSS-native so WKWebView respects the OS setting even if the bus `a11y` message is delayed"
    - "Ring is visibly different across all 7 states — not just color — per the visual design table (pulse freq, rotate speed, particle density modulation)"
    - "All 7 state uniform mappings are covered by `stateUniforms.test.ts` — table-driven tests assert `STATE_PARAMS['listening'].pulse === 3.0` etc."
    - "`RingMesh.test.tsx` renders the component inside `<Canvas>` via @react-three/test-renderer or jsdom + manual mount, asserts no crash and `getState().hudState` drives the mesh's material prop correctly"
    - "Bundle size doesn't regress — `pnpm --filter @jarvis/hud build` output's main chunk stays under ~1 MB (three.js alone is ~600 KB; R3F + drei + React adds ~300 KB)"
  artifacts:
    - path: "webview/packages/hud/src/hud/ring.vert.glsl"
      provides: "Vertex shader with uTime/uStateIdx/uStateBlend/uPulseSpeed/uRotateSpeed/uReduceMotion uniforms + aRadius/aTheta attributes"
      contains: "uniform float uTime"
    - path: "webview/packages/hud/src/hud/ring.frag.glsl"
      provides: "Fragment shader with circular point-sprite + uColorGlow uniform"
      contains: "uniform vec3 uColorGlow"
    - path: "webview/packages/hud/src/hud/stateUniforms.ts"
      provides: "STATE_PARAMS, STATE_TO_IDX maps for all 7 HudStates"
      contains: "awaitingConfirmation:"
    - path: "webview/packages/hud/src/hud/RingMaterial.ts"
      provides: "drei shaderMaterial-constructed RingMaterial class + R3F extend() registration"
      contains: "shaderMaterial"
    - path: "webview/packages/hud/src/hud/RingMesh.tsx"
      provides: "Animated ring mesh reading hudState from Zustand in useFrame"
      contains: "useJarvisStore.getState()"
    - path: "webview/packages/hud/src/hud/LoadingFallbacks.tsx"
      provides: "DOM fallback elements for Reduce Motion per RESEARCH table"
      contains: "data-hud-fallback="
  key_links:
    - from: "webview/packages/hud/src/hud/RingMesh.tsx"
      to: "webview/packages/hud/src/store/index.ts"
      via: "useJarvisStore.getState() in useFrame"
      pattern: "useJarvisStore\\.getState\\(\\)"
    - from: "webview/packages/hud/src/hud/RingMesh.tsx"
      to: "webview/packages/hud/src/hud/stateUniforms.ts"
      via: "STATE_PARAMS lookup by hudState"
      pattern: "STATE_PARAMS\\["
    - from: "webview/packages/hud/src/hud/RingMesh.tsx"
      to: "webview/packages/hud/src/hud/RingMaterial.ts"
      via: "JSX element <ringMaterial ref={...}>"
      pattern: "ringMaterial"
---

<objective>
Replace Plan 03-02's static RingMesh with a shader-driven animated ring whose uniforms are keyed off `hudState` in Zustand. Implement the 7-state visual vocabulary from RESEARCH §Particle Ring Visual Design verbatim, with a 150ms crossfade between states, a `uReduceMotion` escape hatch for accessibility, and a sibling `<LoadingFallbacks />` component that renders CSS-only affordances (loading dots, orbit indicators) when Reduce Motion is active.

Purpose: HUD-02 is the single most visible acceptance criterion of Phase 3 — "seven distinct visual states." The ring is how the user perceives whether Jarvis is listening, thinking, speaking, or waiting for confirmation. Sticking all 7 into ONE shader (with uniforms differing) keeps the GPU pipeline simple (one draw call, no material swaps) while preserving the single source of truth in Zustand and the Swift-side HudStateCoordinator (Plan 03-01). The Reduce Motion fallbacks are non-optional — macOS users with vestibular issues or migraine sensitivity expect motion to vanish when they flip the toggle, and web-content in WKWebView doesn't automatically respect the OS-level Accessibility Display setting without either a CSS `@media` rule or an explicit attribute toggle driven by the bus.

Output: a visible particle ring that morphs smoothly between the 7 HUD states when the Zustand store's `hudState` changes, with accessibility fallbacks in place and table-driven tests covering the state → uniform mapping.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/phases/03-hud/03-RESEARCH.md
@.planning/phases/01-foundations/01-UI-SPEC.md
@webview/packages/hud/src/store/types.ts
@webview/packages/hud/src/store/index.ts
@webview/packages/hud/src/hud/RingMesh.tsx
@webview/packages/hud/src/App.tsx

<interfaces>
<!-- Key contract: the 7-state visual design table from RESEARCH §Particle Ring Visual Design (lines 854-862). -->

| State | Color | Pulse Hz | Rotate rad/s | Reduce-Motion fallback |
|-------|-------|----------|--------------|-----------------------|
| `booting` | grey `#6b7280` @ 60% | 0.3 | 0.1 | static ring, single orbit dot (or fully static) |
| `reconfiguring` | amber `#F59E0B` | 0.8 | 0.3 | static ring + 3-dot loading indicator below |
| `idle` | arc-reactor-glow @ 85% | 0 | 0 | identical (no motion to strip) |
| `thinking` | arc-reactor-glow | 1.5 | 1.0 | 3 dots below rotate opacity sequential 500ms |
| `listening` | arc-reactor-glow @ 100% | 3.0 (will bind to mic RMS in P6) | 0 | single pulse dot, opacity blink 1.25s |
| `speaking` | arc-reactor-glow + outward wave | 2.0 shimmer phased | 0.2 | static ring + 0.8x opacity pulse 0.8s |
| `awaitingConfirmation` | amber `#F59E0B` | 2.5 (higher amplitude) | 0 | static + persistent dot top-right corner |

From `@jarvis/bus`:
```ts
export type HudState = 'idle' | 'listening' | 'thinking' | 'speaking'
  | 'awaitingConfirmation' | 'reconfiguring' | 'booting'
```

From Plan 03-02 `webview/packages/hud/src/store/index.ts`:
```ts
export const useJarvisStore = create<JarvisStore>()(subscribeWithSelector((set) => ({
  hudState: 'booting',
  // ... other slices
})))
```

From Plan 03-02 `webview/packages/hud/src/hud/RingMesh.tsx` (to be REPLACED):
```tsx
export function RingMesh({ particles = 512 }: { particles?: number }) { /* static */ }
```

R3F 9 pattern for drei shaderMaterial (per RESEARCH §Pattern 3 lines 499-614):
```tsx
import { shaderMaterial } from '@react-three/drei'
import { extend, useFrame } from '@react-three/fiber'
const RingMaterial = shaderMaterial(uniforms, vertexShader, fragmentShader)
extend({ RingMaterial })
// usage: <points><ringMaterial ref={matRef} transparent depthWrite={false} /></points>
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: State uniform map + GLSL shader sources + RingMaterial drei integration; table-driven test coverage for STATE_PARAMS</name>
  <files>webview/packages/hud/src/hud/stateUniforms.ts, webview/packages/hud/src/hud/ring.vert.glsl, webview/packages/hud/src/hud/ring.frag.glsl, webview/packages/hud/src/hud/RingMaterial.ts, webview/packages/hud/tests/stateUniforms.test.ts</files>
  <behavior>
    - Test U1 (stateUniforms.test.ts: all 7 HudStates have entries): `Object.keys(STATE_PARAMS)` as a Set equals `{'booting','reconfiguring','idle','thinking','listening','speaking','awaitingConfirmation'}`. Any missing key is a type error; test enforces runtime too.
    - Test U2 (every HudState's STATE_PARAMS.pulse matches the RESEARCH table): table-driven assertions per row: booting=0.3, reconfiguring=0.8, idle=0.0, thinking=1.5, listening=3.0, speaking=2.0, awaitingConfirmation=2.5.
    - Test U3 (every HudState's STATE_PARAMS.rotate matches): booting=0.1, reconfiguring=0.3, idle=0.0, thinking=1.0, listening=0.0, speaking=0.2, awaitingConfirmation=0.0.
    - Test U4 (STATE_TO_IDX assigns unique 0..6 indices): `Object.values(STATE_TO_IDX)` as a Set has size 7; values are the integers 0..6; no collisions.
    - Test U5 (color per state): exactly 2 states (`booting`, `reconfiguring`) return non-default colors; booting='#6b7280'; reconfiguring='#F59E0B'; awaitingConfirmation='#F59E0B'; all others return the theme's `arcReactorGlow` via a special sentinel (e.g., the string 'theme') that RingMesh resolves at useFrame time from store.theme.
    - Test U6 (shader source imports compile at TS level): `import vert from './ring.vert.glsl?raw'; import frag from './ring.frag.glsl?raw'` typechecks. Runtime test: both modules export non-empty strings ≥100 chars.
  </behavior>
  <action>
    1. Create `webview/packages/hud/src/hud/stateUniforms.ts`:
       ```ts
       import type { HudState } from '@jarvis/bus'
       // Per RESEARCH §Particle Ring Visual Design table (lines 854-862).
       // pulse is Hz of the sine term in the vertex shader; rotate is rad/s.
       // color is EITHER a hex string OR the sentinel 'theme' meaning the
       // RingMesh resolves at useFrame time via store.theme.arcReactorGlow.
       export interface StateParams {
         pulse: number
         rotate: number
         color: string // hex "#RRGGBB" or the literal 'theme'
         densityMod?: 'none' | 'gaps' | 'wave' | 'thickness'
       }
       export const STATE_PARAMS: Record<HudState, StateParams> = {
         booting:              { pulse: 0.3, rotate: 0.1, color: '#6b7280', densityMod: 'none' },
         reconfiguring:        { pulse: 0.8, rotate: 0.3, color: '#F59E0B', densityMod: 'gaps' },
         idle:                 { pulse: 0.0, rotate: 0.0, color: 'theme',   densityMod: 'none' },
         thinking:             { pulse: 1.5, rotate: 1.0, color: 'theme',   densityMod: 'none' },
         listening:            { pulse: 3.0, rotate: 0.0, color: 'theme',   densityMod: 'thickness' },
         speaking:             { pulse: 2.0, rotate: 0.2, color: 'theme',   densityMod: 'wave' },
         awaitingConfirmation: { pulse: 2.5, rotate: 0.0, color: '#F59E0B', densityMod: 'none' },
       }
       export const STATE_TO_IDX: Record<HudState, number> = {
         booting: 0, reconfiguring: 1, idle: 2, thinking: 3,
         listening: 4, speaking: 5, awaitingConfirmation: 6,
       }
       // Parse hex '#RRGGBB' -> {r,g,b} in 0..1 space for THREE.Color writes.
       export function parseHex(hex: string): { r: number; g: number; b: number } {
         const m = /^#([0-9a-f]{6})$/i.exec(hex)
         if (!m) return { r: 0.12, g: 0.53, b: 0.90 } // arc-reactor-glow default
         const n = parseInt(m[1]!, 16)
         return { r: ((n >> 16) & 0xff) / 255, g: ((n >> 8) & 0xff) / 255, b: (n & 0xff) / 255 }
       }
       ```
    2. Create `webview/packages/hud/src/hud/ring.vert.glsl` per RESEARCH §Pattern 3 lines 616-644. Include `densityMod` handling as a comment (the shader doesn't need the enum; densityMod is a higher-level categorization the RingMesh uses to drive additional uniforms like `uOutwardWaveAmp` for `speaking`):
       ```glsl
       uniform float uTime;
       uniform float uPulseSpeed;
       uniform float uRotateSpeed;
       uniform float uStateIdx;
       uniform float uStateBlend;        // 0..1, 1 = fully at uStateIdx
       uniform float uPrevStateIdx;
       uniform float uReduceMotion;
       uniform float uOutwardWaveAmp;    // set when state==speaking; 0 otherwise
       attribute float aRadius;
       attribute float aTheta;
       varying float vAlpha;
       void main() {
         float theta = aTheta + uTime * uRotateSpeed;
         float pulse = sin(uTime * uPulseSpeed * 6.2831) * 0.05 * (1.0 - uReduceMotion);
         float wave = uOutwardWaveAmp * sin(uTime * 2.0 + aTheta * 3.0) * (1.0 - uReduceMotion);
         float r = aRadius + pulse + wave;
         vec3 pos = vec3(cos(theta) * r, sin(theta) * r, 0.0);
         vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
         gl_Position = projectionMatrix * mvPosition;
         gl_PointSize = 4.0 * (300.0 / -mvPosition.z);
         vAlpha = 0.85;
       }
       ```
    3. Create `webview/packages/hud/src/hud/ring.frag.glsl`:
       ```glsl
       uniform vec3 uColorGlow;
       varying float vAlpha;
       void main() {
         vec2 uv = gl_PointCoord - vec2(0.5);
         float d = length(uv);
         float alpha = smoothstep(0.5, 0.2, d) * vAlpha;
         gl_FragColor = vec4(uColorGlow, alpha);
       }
       ```
    4. Create `webview/packages/hud/src/hud/RingMaterial.ts`:
       ```ts
       import { shaderMaterial } from '@react-three/drei'
       import { extend } from '@react-three/fiber'
       import * as THREE from 'three'
       import vertexShader from './ring.vert.glsl?raw'
       import fragmentShader from './ring.frag.glsl?raw'
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
       // R3F element namespace augmentation — `<ringMaterial>` becomes a valid JSX element.
       declare module '@react-three/fiber' {
         interface ThreeElements {
           ringMaterial: ReactThreeFiber.Object3DNode<typeof RingMaterial, typeof RingMaterial>
         }
       }
       ```
       If R3F 9's namespace augmentation path has changed (the exact module name may differ from `@react-three/fiber`), consult the type declarations at runtime (`grep -rn ThreeElements node_modules/@react-three/fiber/dist`) and use the correct one. Document any discovery in SUMMARY.md.
    5. Create `webview/packages/hud/tests/stateUniforms.test.ts` covering U1–U6 via table-driven `it.each(...)` over all 7 HudStates.
    6. Run `pnpm --filter @jarvis/hud test tests/stateUniforms.test.ts` — all pass.
    7. Run `pnpm --filter @jarvis/hud typecheck` — exit 0.
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm --filter @jarvis/hud test tests/stateUniforms.test.ts 2>&amp;1 | tail -10 &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; test -s packages/hud/src/hud/ring.vert.glsl &amp;&amp; test -s packages/hud/src/hud/ring.frag.glsl &amp;&amp; grep -c 'pulse:' packages/hud/src/hud/stateUniforms.ts</automated>
  </verify>
  <done>
    - `stateUniforms.ts` has 7 STATE_PARAMS entries and 7 STATE_TO_IDX entries with unique indices 0..6.
    - `ring.vert.glsl` and `ring.frag.glsl` both exist and are non-empty.
    - `RingMaterial.ts` compiles with drei's `shaderMaterial` and registers via R3F `extend()`.
    - `stateUniforms.test.ts` reports ≥6 passing tests (table-driven `it.each` counts as one descriptor).
    - `pnpm typecheck` exits 0.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Animated RingMesh + LoadingFallbacks + 150ms crossfade + Reduce-Motion handling; RingMesh mount-and-drive test</name>
  <files>webview/packages/hud/src/hud/RingMesh.tsx, webview/packages/hud/src/hud/ParticleRing.tsx, webview/packages/hud/src/hud/LoadingFallbacks.tsx, webview/packages/hud/src/hud/loading-fallback.css, webview/packages/hud/src/App.tsx, webview/packages/hud/tests/RingMesh.test.tsx</files>
  <behavior>
    - Test R1 (RingMesh.test.tsx: renders a Canvas + points without crash): mount `<ParticleRing />` inside a `<Canvas>` under jsdom + @react-three/test-renderer if available; expect no thrown error, expect the mesh tree contains a `points` node (via test-renderer's `toTree()`).
    - Test R2 (RingMesh reads hudState via getState in useFrame, NOT via hook): verified via a repository-level grep check documented in the task's done-criteria — the `<verify>` block runs `grep -c "useJarvisStore.getState()"` on the source and asserts ≥1 occurrence AND `grep "useJarvisStore(" ... | grep -v 'getState\|subscribe\|//\|import'` is empty. This is the Pitfall 1 guard.
    - Test R3 (LoadingFallbacks renders state-specific DOM): mount `<LoadingFallbacks hudState="thinking" reduceMotion={true} />`; assert DOM contains elements with `data-hud-fallback="thinking-dots"` (or equivalent). Repeat for `listening`, `speaking`, `awaitingConfirmation` — each has its own fallback signature. `idle`, `booting`, `reconfiguring` use either empty or `data-hud-fallback="static"`.
    - Test R4 (LoadingFallbacks renders nothing when reduceMotion=false for states without persistent affordance): `<LoadingFallbacks hudState="thinking" reduceMotion={false} />` produces empty DOM. States with persistent affordances regardless of reduceMotion (e.g., `awaitingConfirmation` corner dot) MAY render — document per RESEARCH table.
    - Test R5 (App.tsx wires both RingMesh and LoadingFallbacks): asserted via the `<verify>` block's grep checks on App.tsx.
    - Test R6 (150ms crossfade mechanics — unit-level): the crossfade logic is inside useFrame which is hard to test directly; extract the easing math into a pure helper `easeStateBlend(previousBlend, delta, duration=0.15): number` and test it: `easeStateBlend(0, 0.15, 0.15) === 1`, `easeStateBlend(0, 0.075, 0.15) === 0.5`, clamp at 1 for over-budget.
    - Test R7 (build still succeeds): `pnpm --filter @jarvis/hud build` exits 0 and dist/ is re-emitted.
  </behavior>
  <action>
    1. Replace `webview/packages/hud/src/hud/RingMesh.tsx` with the full animated version per RESEARCH §Pattern 3 lines 547-614. Key concrete decisions:
       - Pure helper `easeStateBlend(current, delta, duration): number` exported for R6 unit testing.
       - `currentRef` and `targetRef` as `useRef<{stateIdx, pulse, rotate, blend}>()`.
       - `useFrame((_, delta) => { ... })` body:
         - `const s = useJarvisStore.getState(); const p = STATE_PARAMS[s.hudState]; const reduceMotion = s.a11y.reduceMotion; const theme = s.theme;`
         - If target idx changed: start crossfade (blend=0, uPrevStateIdx=current).
         - Ease blend toward 1 via helper.
         - Ease pulse/rotate toward `p.pulse`/`p.rotate`.
         - Write uniforms onto `matRef.current.uPulseSpeed`, `uRotateSpeed`, `uStateIdx`, `uStateBlend`, `uReduceMotion`, `uOutwardWaveAmp` (set only for `speaking`), `uColorGlow` (via `matRef.current.uColorGlow.setRGB(...)` — parse either the hex string in `p.color` or the theme.arcReactorGlow for sentinel 'theme').
       - geometry useMemo: positions + aRadius + aTheta buffer attributes (512 particles by default). DO NOT return a cleanup that disposes geometry (Pitfall 8).
    2. Create `webview/packages/hud/src/hud/ParticleRing.tsx` as a small `<Canvas>`-wrapping component for cleaner App.tsx composition:
       ```tsx
       import { Canvas } from '@react-three/fiber'
       import { RingMesh } from './RingMesh'
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
       ```
    3. Create `webview/packages/hud/src/hud/LoadingFallbacks.tsx` — a small React component that reads `hudState` via the hook (it's fine to rerender on state change — this is the LOW-frequency path) and renders CSS-driven affordances. Example shape:
       ```tsx
       import { useJarvisStore } from '../store'
       import './loading-fallback.css'
       export function LoadingFallbacks() {
         const hudState = useJarvisStore((s) => s.hudState)
         const reduceMotion = useJarvisStore((s) => s.a11y.reduceMotion)
         // Always-on affordances regardless of reduceMotion:
         if (hudState === 'awaitingConfirmation') {
           return <div className="hud-fallback__corner-dot" data-hud-fallback="awaiting-corner" aria-label="Jarvis, waiting for your confirmation" />
         }
         if (!reduceMotion) return null  // no loading DOM when motion allowed
         // Reduce Motion fallbacks (shader zeroes motion; these carry the signal)
         switch (hudState) {
           case 'thinking':       return <div className="hud-fallback__three-dots" data-hud-fallback="thinking-dots" aria-label="Jarvis, thinking" />
           case 'listening':      return <div className="hud-fallback__pulse-dot" data-hud-fallback="listening-pulse" aria-label="Jarvis, listening" />
           case 'speaking':       return <div className="hud-fallback__speaking-pulse" data-hud-fallback="speaking-pulse" aria-label="Jarvis, speaking" />
           case 'reconfiguring':  return <div className="hud-fallback__three-dots hud-fallback__three-dots--warm" data-hud-fallback="reconfiguring-dots" aria-label="Jarvis, reconfiguring audio" />
           case 'booting':        return <div className="hud-fallback__single-dot" data-hud-fallback="booting-dot" aria-label="Jarvis, starting up" />
           case 'idle':           return null
           case 'awaitingConfirmation': return null // handled above
           default: {
             const _exhaustive: never = hudState
             void _exhaustive
             return null
           }
         }
       }
       ```
    4. `webview/packages/hud/src/hud/loading-fallback.css` — CSS animations with `@media (prefers-reduced-motion: reduce)` defense-in-depth. Example rules:
       ```css
       .hud-fallback__three-dots { width: 48px; height: 12px; display: flex; gap: 8px; margin: 16px auto; justify-content: center; }
       .hud-fallback__three-dots::before, .hud-fallback__three-dots::after,
       .hud-fallback__three-dots > span { content: ""; width: 8px; height: 8px; background: var(--arc-reactor-glow); border-radius: 50%; opacity: 0.3; animation: hud-dot-pulse 1.5s ease-in-out infinite; }
       .hud-fallback__three-dots::after { animation-delay: 0.5s; }
       .hud-fallback__three-dots > span { animation-delay: 0.25s; }
       @keyframes hud-dot-pulse { 0%,100%{ opacity:0.3 } 50%{ opacity:1 } }
       .hud-fallback__three-dots--warm::before, .hud-fallback__three-dots--warm::after,
       .hud-fallback__three-dots--warm > span { background: #F59E0B; }
       .hud-fallback__pulse-dot { width: 16px; height: 16px; margin: 16px auto; background: var(--arc-reactor-glow); border-radius: 50%; animation: hud-pulse-blink 1.25s ease-in-out infinite; }
       @keyframes hud-pulse-blink { 0%,100% { opacity:1; transform:scale(1)} 50%{opacity:0.3; transform:scale(0.8)} }
       .hud-fallback__speaking-pulse { width: 100%; height: 8px; margin: 16px 0; background: linear-gradient(90deg, transparent, var(--arc-reactor-glow), transparent); opacity: 0.5; animation: hud-speak-pulse 0.8s ease-in-out infinite; }
       @keyframes hud-speak-pulse { 0%,100%{opacity:0.3} 50%{opacity:0.8} }
       .hud-fallback__corner-dot { position: fixed; top: 12px; right: 12px; width: 12px; height: 12px; background: #F59E0B; border-radius: 50%; box-shadow: 0 0 8px #F59E0B; }
       .hud-fallback__single-dot { width: 8px; height: 8px; margin: 16px auto; background: var(--arc-reactor-glow); border-radius: 50%; opacity: 0.6; }
       @media (prefers-reduced-motion: reduce) {
         .hud-fallback__three-dots > *, .hud-fallback__pulse-dot, .hud-fallback__speaking-pulse {
           animation: none !important;
         }
       }
       ```
    5. Update `webview/packages/hud/src/App.tsx` to compose both:
       ```tsx
       import { ParticleRing } from './hud/ParticleRing'
       import { LoadingFallbacks } from './hud/LoadingFallbacks'
       export function App() {
         return (
           <div className="jarvis-hud">
             <div className="jarvis-hud__ring"><ParticleRing particles={512} /></div>
             <LoadingFallbacks />
             {/* <ChatPanel /> lands in Plan 03-04 */}
           </div>
         )
       }
       ```
    6. Create `webview/packages/hud/tests/RingMesh.test.tsx`:
       - R1: Use `@react-three/test-renderer` (R3F official test renderer). If it's not in deps, add `@react-three/test-renderer` to devDependencies of `@jarvis/hud` and pin to the version matching R3F 9.6. If that package doesn't exist at R3F 9, fall back to mounting via `@testing-library/react` inside a `<Canvas>` (jsdom won't render WebGL but will at least exercise the component tree without error — document the fallback).
       - R2/R5: not inside the test file. The `<verify>` block at the end of this task runs the greps directly.
       - R3/R4: mount `<LoadingFallbacks />` directly (no Canvas needed — it's plain DOM) via `render` from `@testing-library/react`; `useJarvisStore.setState({ hudState: 'thinking', a11y: { reduceMotion: true, reduceTransparency: false } })` before render; assert presence of `data-hud-fallback="thinking-dots"` via `screen.getByTestId` or `container.querySelector`.
       - R6: direct unit test of `easeStateBlend` exported from `RingMesh.tsx`.
    7. Run `pnpm --filter @jarvis/hud test` — all tests (stateUniforms + RingMesh + from 03-02) pass.
    8. Run `pnpm --filter @jarvis/hud build` — verify output emits the shader chunks correctly (grep for `uColorGlow` inside one of the emitted asset chunks as a sanity check that the `?raw` import survived).
    9. Run `pnpm --filter @jarvis/hud typecheck` — exit 0.
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm --filter @jarvis/hud test 2>&amp;1 | tail -15 &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; pnpm --filter @jarvis/hud build 2>&amp;1 | tail -5 &amp;&amp; grep -c 'useJarvisStore.getState()' packages/hud/src/hud/RingMesh.tsx &amp;&amp; ! (grep -n 'useJarvisStore(' packages/hud/src/hud/RingMesh.tsx | grep -v -e 'getState' -e 'subscribe' -e '//' -e 'import' | grep -q '.')</automated>
  </verify>
  <done>
    - RingMesh reads hudState via `getState()` in useFrame; no subscribing hook inside the R3F render-per-frame path.
    - LoadingFallbacks renders state-appropriate DOM under Reduce Motion.
    - App.tsx composes both ParticleRing and LoadingFallbacks.
    - `pnpm test` + `pnpm typecheck` + `pnpm build` all exit 0.
    - Shader sources end up in the built chunk (proves `?raw` import worked).
    - `easeStateBlend` helper tests pass.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| GLSL shader sources → WebGL compile | Shader source files are statically imported via Vite `?raw`. No dynamic shader compilation from external input. |
| Zustand store → RingMesh useFrame | Trusted in-process reads; store is the single source of truth for `hudState`, `a11y`, `theme`. |
| OS accessibility settings → webview | macOS Reduce Motion reaches webview via two paths: (a) CSS `@media (prefers-reduced-motion: reduce)` (automatic), and (b) Swift-emitted `a11y` bus message (Plan 03-05). Both paths enforced for defense-in-depth. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-20 | DoS | useFrame per-frame React rerender | mitigate | Read via `useJarvisStore.getState()` not hook; Pitfall 1. Task 2 `<verify>` grep lint-enforces. |
| T-03-21 | DoS | GPU memory growth from double-mount | mitigate | Do NOT dispose geometry in useMemo cleanup; R3F reconciler owns it (Pitfall 8). Documented in RingMesh.tsx comment. |
| T-03-22 | Accessibility | Reduce Motion ignored | mitigate | Two paths: CSS `@media` (automatic) + shader `uReduceMotion` uniform driven from store.a11y.reduceMotion (Swift-emitted per Plan 03-05). If bus message is delayed, CSS still catches. |
| T-03-23 | Tampering | Shader source injection | accept | Shaders are static `.glsl` files imported at build time; no runtime shader string concatenation. `?raw` import is safe — no dynamic content. |
| T-03-24 | DoS | 512 particles × 60 FPS on older hardware | accept | RESEARCH §A3 calibration target. Fallback is documented as "reduce to 256" in SUMMARY.md if profiling reveals perf issues on target hardware. |
</threat_model>

<verification>
Phase-gate for Plan 03-03:
1. `pnpm --filter @jarvis/hud build && pnpm --filter @jarvis/hud test && pnpm --filter @jarvis/hud typecheck` all exit 0.
2. `grep -c 'STATE_PARAMS' webview/packages/hud/src/hud/stateUniforms.ts` ≥ 1 with 7 entries visible.
3. `grep -c 'useJarvisStore.getState()' webview/packages/hud/src/hud/RingMesh.tsx` ≥ 1.
4. `grep 'useJarvisStore(' webview/packages/hud/src/hud/RingMesh.tsx | grep -v 'getState\|subscribe\|//\|import'` returns empty.
5. `ls webview/packages/hud/src/hud/ring.{vert,frag}.glsl` both resolve.
6. `ls webview/packages/hud/src/hud/LoadingFallbacks.tsx webview/packages/hud/src/hud/loading-fallback.css` both resolve.
7. `cd packages/Bus && swift test` stays 47/47 green (Swift unaffected).
</verification>

<success_criteria>
- Shader-driven animated ring replaces Plan 03-02's static mesh.
- All 7 HudStates render distinct visuals per the RESEARCH design table.
- 150ms state crossfade eases between states without jitter.
- Reduce Motion zeros shader motion AND renders DOM-based loading affordances per state.
- Build, test, typecheck all exit 0 after the change.
- No regression in bundle size (check dist chunk sizes; document if main chunk crosses 1 MB).
</success_criteria>

<output>
After completion, create `.planning/phases/03-hud/03-03-SUMMARY.md`:
- `requirements-completed: [HUD-02]` (HUD-02 is complete from the webview side; Plan 03-05's integration test proves it end-to-end when Swift drives state transitions through the bus).
- Decisions: drei shaderMaterial vs hand-roll; `?raw` import path for shaders; any R3F 9 element namespacing workarounds; perf measurements (FPS at 512 particles in a dev-server smoke-test if possible).
- Known stubs: uOutwardWaveAmp effect for `speaking` is simple; a more elaborate outward-wave spring system is Phase 4+.
- Audio-reactive modulation for `listening` (pulse=3.0) is a FAKE sine wave in P3 — Phase 6 VoiceController will emit `audioLevel` RMS over the bus and the uniform will bind to that. Document this as a Phase 6 dependency.
- Next plan readiness: Plan 03-04 renders ChatPanel alongside ParticleRing; Plan 03-05 wires the bundle into the Swift app and drives state transitions end-to-end.
</output>
