---
phase: 03-hud
plan: 03
subsystem: webview/hud
tags: [typescript, react19, r3f, drei, glsl, shaders, zustand, a11y, reduce-motion]
requirements-completed: [HUD-02]
dependency-graph:
  requires: [03-01, 03-02]
  provides: [03-04, 03-05]
  affects: []
tech-stack:
  added: []
  patterns:
    - "drei shaderMaterial factory + R3F 9 extend() + <ringMaterial> JSX"
    - "Pitfall 1: useJarvisStore.getState() inside useFrame (no subscribing hook)"
    - "Pitfall 8: do NOT dispose useMemo'd geometry; R3F owns lifecycle"
    - "150ms eased crossfade via pure easeStateBlend() helper (unit-testable)"
    - "Reduce Motion: shader uReduceMotion uniform + DOM fallbacks + CSS @media defense-in-depth"
key-files:
  created:
    - webview/packages/hud/src/hud/stateUniforms.ts
    - webview/packages/hud/src/hud/RingMaterial.ts
    - webview/packages/hud/src/hud/ring.vert.glsl
    - webview/packages/hud/src/hud/ring.frag.glsl
    - webview/packages/hud/src/hud/LoadingFallbacks.tsx
    - webview/packages/hud/src/hud/loading-fallback.css
    - webview/packages/hud/tests/stateUniforms.test.ts
    - webview/packages/hud/tests/RingMesh.test.tsx
  modified:
    - webview/packages/hud/src/hud/RingMesh.tsx  # replaced static with shader-driven
    - webview/packages/hud/src/App.tsx           # added <LoadingFallbacks /> sibling
decisions:
  - "drei shaderMaterial chosen over hand-rolled THREE.ShaderMaterial subclass"
  - "Vite ?raw import for .glsl worked first try (vite/client types already in tsconfig)"
  - "R3F 9 namespace pattern: ThreeElements['shaderMaterial'] & { custom uniforms }"
  - "Skipped @react-three/test-renderer; used @testing-library/react + Canvas"
  - "512 particles default retained (Wave 1 number); not reduced"
metrics:
  tasks: 2
  tests-added: 42    # 27 stateUniforms + 15 RingMesh
  tests-passing: 54  # full hud suite (store 6 + bus 6 + new 42)
  duration-hours: "~1"
---

# Phase 3 Plan 03: Particle Ring Shader Summary

Shader-driven 7-state animated particle ring with 150ms crossfades, Reduce-Motion DOM affordances, and table-driven state-uniform tests. Replaces Wave 1's static `<pointsMaterial>` with a drei `shaderMaterial`-backed `<ringMaterial>` whose uniforms are keyed off Zustand `hudState`.

## What changed

**Task 1 — State uniforms + GLSL + drei material**
- `stateUniforms.ts`: `STATE_PARAMS` + `STATE_TO_IDX` for all 7 HudStates per RESEARCH §Particle Ring Visual Design table (lines 854-862). `parseHex()` helper handles hex-to-RGB with arc-reactor-glow fallback for the `'theme'` sentinel.
- `ring.vert.glsl` / `ring.frag.glsl`: single-pass vertex + fragment shaders. Vert does `aTheta + uTime*uRotateSpeed` rotation, `sin(uTime*uPulseSpeed*2π)*0.05` pulse, and optional `uOutwardWaveAmp*sin(...)` for `speaking`. Frag produces a circular point sprite tinted by `uColorGlow`.
- `RingMaterial.ts`: drei `shaderMaterial` factory + `extend({RingMaterial})` + R3F 9 namespace augmentation declaring `<ringMaterial>` with typed uniform props (`ThreeElements['shaderMaterial'] & {...}`). Also exports `RingMaterialImpl = InstanceType<typeof RingMaterial>` so `matRef.current.uTime = ...` is type-safe in RingMesh.
- `stateUniforms.test.ts`: 27 tests covering U1–U6 — all 7 entries present, pulse/rotate/color per-state table-driven, `STATE_TO_IDX` assigns unique 0–6, `parseHex()` round-trips + fallback, `?raw` shader imports non-empty with expected uniform tokens.

**Task 2 — Animated RingMesh + LoadingFallbacks**
- `RingMesh.tsx`: pure `easeStateBlend(current, delta, duration)` helper exported for unit testing. `useFrame` reads `useJarvisStore.getState()` (Pitfall 1 guard), detects state change via `targetIdxRef`, starts a 150ms crossfade by snapshotting `uPrevStateIdx`, eases `blend` → 1, smooths `pulse`/`rotate` morphing via `delta*6` factor, and sets `uReduceMotion`/`uOutwardWaveAmp` uniforms. Color uniform resolves the `'theme'` sentinel from `store.theme.arcReactorGlow` at frame time. Geometry (`position` + `aRadius` + `aTheta` buffer attributes) allocated once via `useMemo`, NOT disposed in cleanup (Pitfall 8 guard).
- `LoadingFallbacks.tsx`: DOM affordances per HudState when `reduceMotion === true`. Subscribes via the normal hook — this is the low-frequency rerender path, Pitfall 1 only applies inside `useFrame`. `awaitingConfirmation` renders its corner dot regardless of `reduceMotion`. Exhaustiveness check on `hudState` keeps the switch honest.
- `loading-fallback.css`: CSS keyframe animations for `three-dots`, `pulse-dot`, `speaking-pulse`, etc. `@media (prefers-reduced-motion: reduce)` kills all animations as defense-in-depth, so WKWebView respects the OS-level setting even if the bus `a11y` message is delayed at boot.
- `App.tsx`: `<LoadingFallbacks />` rendered as sibling to `<ParticleRing />`. ChatPanel placeholder comment left for Plan 03-04.
- `RingMesh.test.tsx`: 15 tests — ParticleRing mounts in jsdom + Canvas without throwing; LoadingFallbacks emits correct `data-hud-fallback="<slug>"` for each of 5 reduce-motion states + persistent awaiting-corner in both reduce-motion modes + empty DOM for motion-allowed thinking + empty DOM for idle; `easeStateBlend()` edge cases (0/0.15=1, 0/0.075=0.5, clamps at 1 over-budget, additive, no-op when delta=0).

## Deviations from plan

**None of substance.** Minor wording/ergonomics decisions:

1. **Typed `matRef` with `RingMaterialImpl`** instead of the plan's `useRef<any>(null)`. Added `export type RingMaterialImpl = InstanceType<typeof RingMaterial>` to `RingMaterial.ts` so `matRef.current.uTime` is type-safe. Zero runtime cost, better DX.
2. **Skipped `@react-three/test-renderer`** (version 9.1.0 would have been the R3F 9 peer). The plan allowed this fallback explicitly. Instead, R1 mounts `<ParticleRing />` inside a `<Canvas>` via `@testing-library/react` and asserts no throw. jsdom lacks WebGL, so Canvas logs an error internally but doesn't throw — this still exercises the `extend({RingMaterial})` registration, `?raw` shader imports, and the full component tree, which is what we actually want to prove at the unit level. GPU rendering is validated at runtime via the dev-server smoke test, not here.
3. **`DEFAULT_RGB` named constant** in `stateUniforms.ts` instead of the plan's inline `{ r: 0.12, g: 0.53, b: 0.90 }`. Same value, shared between the `parseHex` branches so a future change to the arc-reactor-glow fallback only touches one line.

## Known stubs (flagged for future phases)

- **`uOutwardWaveAmp` for `speaking`** is a fixed `0.03` amplitude driven by a simple `sin(uTime*2 + aTheta*3)` — a more elaborate outward-wave spring system is Phase 4+.
- **`listening` pulse (3.0 Hz)** is a fake sine wave in Phase 3. **Phase 6 VoiceController** will emit an `audioLevel` RMS over the bus and bind that to the uniform for true audio-reactive pulsing. This is documented as a Phase 6 dependency.
- **`visibility` bus message** (RESEARCH Open Q #1 — battery-pause when HUD is minimized) is NOT in this plan's scope per the plan's assumptions. Ring's `useFrame` runs unconditionally; Plan 03-05's bridge integration will add battery-saving pause IF profiling shows it matters.

## Bundle size note

Main JS chunk lands at **1,080.72 kB** (gzipped 297.37 kB). Rolldown emits a 500 kB warning; this is dominated by three.js (~600 kB) + R3F + drei + React. The plan's target was "under ~1 MB" as a soft ceiling — we're 8% over. Acceptable for Phase 3; **flagged for Phase 8 (Hardening) code-splitting work** (dynamic `import()` of the R3F/three bundle behind a loading spinner would trivially split the 3D layer from the app shell). Not a regression — this is the first time R3F+drei lands in the bundle.

## Test / build / typecheck

- `pnpm --filter @jarvis/hud test` → **54 passed / 4 files** (27 stateUniforms + 15 RingMesh + 6 store + 6 bus-dispatch). Zero failures.
- `pnpm --filter @jarvis/hud typecheck` → exit 0.
- `pnpm --filter @jarvis/hud build` → exit 0, dist emits `index-CWhbXuPI.css` (2.31 kB) + `index-GKpMedO4.js` (1,080.72 kB). `grep uColorGlow` confirms shader `?raw` imports survived into the bundle.
- Swift tests not re-run from this worktree (webview-only plan); previous baseline 47/47 green.

## Pitfall guards (verified via grep)

- `grep -c 'useJarvisStore.getState()' RingMesh.tsx` → **2** (hudState + theme read) ✓
- `grep 'useJarvisStore(' RingMesh.tsx | grep -v 'getState|subscribe|//|import'` → **empty** ✓ (no subscribing hook in useFrame path)
- `STATE_PARAMS` has 7 entries ✓
- `.glsl` files non-empty ✓
- `LoadingFallbacks.tsx` + `loading-fallback.css` both present ✓
- `App.tsx` composes `<ParticleRing />` + `<LoadingFallbacks />` ✓

## Next plan readiness

- **Plan 03-04 (ChatPanel)**: will add a sibling `<ChatPanel />` beneath the ring. `App.tsx` already has the placeholder comment. `data-hud-fallback="awaiting-corner"` is positioned `fixed top-right` so it won't collide with chat bottom layout.
- **Plan 03-05 (Swift bridge integration)**: will drive `hudState` transitions end-to-end through the bus. This plan's visual vocabulary is already bound to the store, so 03-05's work is purely the bridge wiring — no changes expected to any file here.
- **Phase 6 (Voice)**: will wire `listening` pulse to real mic RMS. The `uPulseSpeed` uniform is already in place; only a new `audioLevel` bus message + a store field + one line in `useFrame` needs to change.

## Self-Check: PASSED

- Files created: all 8 present at listed paths ✓
- Files modified: `RingMesh.tsx` + `App.tsx` diffs applied ✓
- Commits present:
  - `d094b3b feat(03-03): add state uniforms, GLSL sources, RingMaterial + table-driven tests`
  - `4951bfd feat(03-03): animated shader-driven RingMesh + Reduce Motion DOM fallbacks`
