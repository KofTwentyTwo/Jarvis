---
phase: 03-hud
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - webview/pnpm-workspace.yaml
  - webview/package.json
  - webview/packages/hud/package.json
  - webview/packages/hud/tsconfig.json
  - webview/packages/hud/vite.config.ts
  - webview/packages/hud/vitest.config.ts
  - webview/packages/hud/index.html
  - webview/packages/hud/src/main.tsx
  - webview/packages/hud/src/App.tsx
  - webview/packages/hud/src/store/index.ts
  - webview/packages/hud/src/store/types.ts
  - webview/packages/hud/src/bus/client.ts
  - webview/packages/hud/src/hud/ParticleRing.tsx
  - webview/packages/hud/src/hud/RingMesh.tsx
  - webview/packages/hud/src/theme/tokens.css
  - webview/packages/hud/src/types/globals.d.ts
  - webview/packages/hud/tests/store.test.ts
  - webview/packages/hud/tests/bus-dispatch.test.ts
  - webview/pnpm-lock.yaml
autonomous: true
requirements: [HUD-01]
tags: [typescript, react19, r3f, drei, three, zustand, vite8, pnpm, webview, scaffold]

assumptions:
  - "Plan 03-02 runs in Wave 1 parallel with Plan 03-01 (zero file overlap: Swift vs TS)"
  - "Phase 2 shipped `webview/` pnpm workspace (webview/package.json + webview/pnpm-workspace.yaml) and `@jarvis/bus` package at `webview/packages/bus/`. This plan adds a sibling `webview/packages/hud/` that depends on `@jarvis/bus`. Verified via Bash ls of webview/packages/."
  - "Node >= 20.19 is available (Vite 8 requirement; confirmed by 02-02 SUMMARY which used Node for Vitest 2.1.9 — Vite 8 needs ≥20.19 but the node constraint goes in this plan)"
  - "pnpm 10.30.2 is the installed package manager per webview/package.json's `packageManager` pin"
  - "React 19.2.0 + R3F 9.6.0 + drei 10.7.6 + three 0.184.0 + Zustand 5 + Vite 8 versions are available on npmjs — RESEARCH §Standard Stack already verified via npm view commands. Use `pnpm add -D` with exact pinned versions from RESEARCH §Standard Stack; if any version resolution fails, use the next-lowest compatible tag and document the deviation."
  - "This plan does NOT build the ring shader state animations or chat panel — those are Plans 03-03 and 03-04. This plan ships an empty `<ParticleRing />` that renders a `<Canvas>` containing a minimal `<RingMesh>` with a default shader (arc-reactor-glow dot pattern, no state animations yet). The store + bus dispatcher hydrate hudState but the visual doesn't differentiate 7 states — Plan 03-03 wires the uniforms."
  - "No `App/Resources/webview/` mutations in this plan — the bundle-copy script is Plan 03-05. This plan produces `webview/packages/hud/dist/` via `pnpm --filter @jarvis/hud build` and verifies the build output has Vite-8-compatible `base: './'` relative asset paths."
  - "Vite 8's `base: './'` + `assetsDir: 'assets'` behavior — if v8 GA changed how base paths interact with chunk splitting, we verify by building and grepping the dist/index.html for `./assets/` prefixes. If Vite 8 surprises us with a breaking change to base-path semantics, the executor surfaces the deviation in the SUMMARY.md per Rule 1."

must_haves:
  truths:
    - "`webview/packages/hud/` is a new pnpm workspace package with name `@jarvis/hud`, private, ESM, with React 19.2 + R3F 9.6 + drei 10.7 + three 0.184 + Zustand 5 + Vite 8 as dependencies"
    - "`webview/packages/hud/vite.config.ts` sets `base: './'` so file:// resolution works in WKWebView (pitfall 3)"
    - "`pnpm --filter @jarvis/hud build` produces `webview/packages/hud/dist/index.html` that references `./assets/*.js` (relative paths, no absolute `/assets/`)"
    - "`pnpm --filter @jarvis/hud build` output contains the resolved versions — React 19.2.x, three r184, drei 10.7.x — visible in dist/assets/*.js chunk content"
    - "Zustand store at `webview/packages/hud/src/store/index.ts` exposes `useJarvisStore` with slices: `hudState: HudState`, `chatEvents: ChatEvent[]` (empty initially), `a11y: {reduceMotion, reduceTransparency}`, `theme: {arcReactorGlow}`, `connection: 'booting' | 'ready' | 'refused'`"
    - "Store uses `subscribeWithSelector` middleware so RingMesh can subscribe imperatively inside `useFrame` (Plan 03-03 consumes this)"
    - "Bus dispatcher at `webview/packages/hud/src/bus/client.ts` calls `installJarvisBus()` from `@jarvis/bus`, registers an `onOutbound` handler that switch-exhausts every BusOutbound case, and posts `uiReady` back to Swift once React has mounted"
    - "Bus dispatcher's outbound switch uses the same `const _exhaustive: never = type;` (NO `as never` cast) pattern as `@jarvis/bus` so adding a case fails `tsc --strict` at compile time"
    - "Adding a new `BusOutbound` discriminator without extending the dispatch switch fails `pnpm --filter @jarvis/hud typecheck` (empirically verified by temporarily appending a fake case to a local type augmentation, running tsc, observing TS2322 on the sentinel, then reverting)"
    - "`<App />` renders a `<Canvas>` hosting `<RingMesh particles={512} />` — a `three.Points` with `BufferGeometry` arranged on a ring; the ring is visibly arc-reactor-glow-colored but does NOT animate per state yet (Plan 03-03)"
    - "Vitest unit tests cover: (a) store default values; (b) store `setHudState` mutates only `hudState`; (c) bus dispatcher routes `hudState` outbound → `store.setHudState`; (d) bus dispatcher routes unknown type → error callback; (e) `main.tsx` boot sequence posts `uiReady` after first render"
    - "`pnpm --filter @jarvis/hud test` reports zero failures"
    - "`pnpm --filter @jarvis/hud typecheck` reports zero errors"
    - "`pnpm-lock.yaml` at webview/ root is updated and committed"
  artifacts:
    - path: "webview/packages/hud/package.json"
      provides: "@jarvis/hud ESM package with React/R3F/drei/three/Zustand/Vite deps + vitest/testing-library devDeps"
      contains: "\"@jarvis/bus\": \"workspace:*\""
    - path: "webview/packages/hud/vite.config.ts"
      provides: "Vite 8 config with base: './' for WKWebView file:// compat"
      contains: "base: './'"
    - path: "webview/packages/hud/index.html"
      provides: "HTML entrypoint with CSP meta, #root div, references ./src/main.tsx via Vite dev+build"
      contains: "Content-Security-Policy"
    - path: "webview/packages/hud/src/main.tsx"
      provides: "React 19 createRoot mount + attachBus() + uiReady ping"
      contains: "createRoot"
    - path: "webview/packages/hud/src/App.tsx"
      provides: "Top-level <Canvas> + <RingMesh> composition; Plan 03-04 adds <ChatPanel>"
      contains: "Canvas"
    - path: "webview/packages/hud/src/store/index.ts"
      provides: "Zustand store with subscribeWithSelector middleware + actions only the bus dispatcher calls"
      contains: "subscribeWithSelector"
    - path: "webview/packages/hud/src/bus/client.ts"
      provides: "installJarvisBus() integration + exhaustive outbound dispatcher + uiReady ping"
      contains: "installJarvisBus"
    - path: "webview/packages/hud/src/hud/RingMesh.tsx"
      provides: "Minimal R3F <points> with 512 particles on a ring — no state animations yet (Plan 03-03)"
      contains: "THREE.BufferGeometry"
  key_links:
    - from: "webview/packages/hud/src/bus/client.ts"
      to: "@jarvis/bus installJarvisBus"
      via: "import"
      pattern: "from \"@jarvis/bus\""
    - from: "webview/packages/hud/src/main.tsx"
      to: "webview/packages/hud/src/bus/client.ts"
      via: "attachBus() call"
      pattern: "attachBus\\(\\)"
---

<objective>
Stand up `webview/packages/hud/` as a new pnpm workspace package holding the React 19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8 scaffold. Produce a buildable bundle at `webview/packages/hud/dist/` that:
1. Imports `@jarvis/bus` (Phase 2) and installs `window.jarvisBus` at document-start.
2. Mounts a React 19 app whose top-level component renders a `<Canvas>` containing a minimal `<RingMesh>` of 512 particles on a ring (single-color arc-reactor-glow dot pattern — no state animations yet; those land in Plan 03-03).
3. Exposes a single Zustand 5 store (`useJarvisStore`) with `subscribeWithSelector` middleware and slices for `hudState`, `chatEvents`, `a11y`, `theme`, and `connection`.
4. Registers an exhaustive outbound bus dispatcher: every `BusOutbound` case maps to a specific store mutation, and the default branch uses the same `const _exhaustive: never = type;` pattern @jarvis/bus pioneered so adding a case fails `tsc --strict`.
5. Posts `{ type: 'uiReady' }` back to Swift once React has committed first render.

Purpose: Phase 3 cannot land a shader-driven ring or a streaming chat panel without the scaffold underneath. This plan is the **bed** — it proves pnpm workspace integration, Vite 8 base-path behavior in WKWebView bundles, Zustand 5 wiring, and the bus-dispatcher exhaustiveness guard all work together. Plans 03-03 (ring animations) and 03-04 (chat panel) layer onto this scaffold without re-installing dependencies or re-wiring the bus.

Output: new `webview/packages/hud/` package with working `pnpm build`, `pnpm test`, `pnpm typecheck`; buildable bundle that can be loaded by WKWebView (Plan 03-05 wires the loadFileRequest); zero mutations to Swift code, `App/Resources/webview/`, or `webview/packages/bus/`.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-hud/03-RESEARCH.md
@.planning/phases/02-bus/02-02-SUMMARY.md
@.planning/phases/02-bus/02-03-SUMMARY.md
@webview/package.json
@webview/pnpm-workspace.yaml
@webview/tsconfig.base.json
@webview/packages/bus/package.json
@webview/packages/bus/src/protocol.ts
@webview/packages/bus/src/bridge.ts

<interfaces>
<!-- Extracted from `@jarvis/bus` (Phase 2). Executor should import these directly. -->

From `webview/packages/bus/src/protocol.ts`:
```ts
export const BUS_PROTOCOL_VERSION = "2.0.0";

export type HudState =
  | "idle" | "listening" | "thinking" | "speaking"
  | "awaitingConfirmation" | "reconfiguring" | "booting";

export type TurnTerminator = "completed" | "cancelled" | "errored" | "superseded";

export type BusOutbound =
  | { type: "hello"; version: string }
  | { type: "hudState"; state: HudState }
  | { type: "tokenDelta"; text: string }
  | { type: "audioLevel"; rms: number }
  | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
  | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
  | { type: "turnStarted"; id: string }
  | { type: "turnEnded"; id: string; terminator: TurnTerminator };

export type BusInbound =
  | { type: "helloAck"; version: string }
  | { type: "uiReady" };
```

From `webview/packages/bus/src/bridge.ts`:
```ts
export function installJarvisBus(options?: InstallOptions): () => void;
// After install, global: window.jarvisBus.receive(payload: string)
// After install, global: window.jarvisBus.send(msg: BusInbound): Promise<unknown>
// After install, global: window.jarvisBus.onOutbound(handler: (msg: BusOutbound) => void): void
// After install, global: window.jarvisBus.protocolVersion: string
```

Key consumption pattern the HUD must follow:
```ts
installJarvisBus({ onDecodeError: (e, raw) => console.error('[bus]', e, raw) });
window.jarvisBus.onOutbound((msg) => dispatch(msg)); // register BEFORE 'hello' arrives
void window.jarvisBus.send({ type: 'uiReady' });
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Scaffold @jarvis/hud package — package.json, tsconfig, Vite 8 config, index.html, main.tsx, App.tsx, store skeleton, bus dispatcher scaffolding, globals.d.ts; ensure `pnpm install` + `pnpm build` + `pnpm typecheck` all succeed</name>
  <files>webview/pnpm-workspace.yaml, webview/package.json, webview/packages/hud/package.json, webview/packages/hud/tsconfig.json, webview/packages/hud/vite.config.ts, webview/packages/hud/vitest.config.ts, webview/packages/hud/index.html, webview/packages/hud/src/main.tsx, webview/packages/hud/src/App.tsx, webview/packages/hud/src/store/types.ts, webview/packages/hud/src/store/index.ts, webview/packages/hud/src/bus/client.ts, webview/packages/hud/src/theme/tokens.css, webview/packages/hud/src/types/globals.d.ts, webview/pnpm-lock.yaml</files>
  <behavior>
    - Test B1 (build produces relative asset paths): after `pnpm --filter @jarvis/hud build`, grep `webview/packages/hud/dist/index.html` must show `src="./assets/` (at least one occurrence); zero occurrences of `src="/assets/`. This is the Pitfall 3 guard.
    - Test B2 (build emits index.html + at least one JS chunk): `ls webview/packages/hud/dist/index.html webview/packages/hud/dist/assets/*.js` both resolve; the JS chunk is ≥10 KB (contains React+R3F+three).
    - Test B3 (typecheck passes): `pnpm --filter @jarvis/hud typecheck` exits 0.
    - Test B4 (no `: any` in src): `grep -rn ': any' webview/packages/hud/src/` returns zero. Exception: `eslint-disable` line + globals.d.ts third-party shim if the drei `shaderMaterial` element namespace needs a targeted @ts-expect-error (NOT a blanket any). Document any allowance in-file with a comment.
    - Test B5 (exhaustiveness sentinel is un-cast): `grep 'as never' webview/packages/hud/src/bus/client.ts` returns zero; `grep -c '_exhaustive: never' webview/packages/hud/src/bus/client.ts` ≥ 1.
    - Test B6 (CSP meta is present in index.html): `grep -c 'Content-Security-Policy' webview/packages/hud/index.html` ≥ 1 and the policy includes `connect-src 'none'` and `script-src 'self'` per RESEARCH §Security Domain.
  </behavior>
  <action>
    1. Add `"packages/*"` glob to `webview/pnpm-workspace.yaml` — already present per Phase 2 (`packages: - packages/*`). Verify by cat'ing the file; no change needed unless missing.
    2. Update `webview/package.json` — confirm `devDependencies` already has `typescript ^5.5.0` + `vitest ^2.1.0` + `@types/node ^20.0.0`. No changes unless the hud package needs hoisted devDeps; prefer per-package devDeps to keep hoisting minimal.
    3. Create `webview/packages/hud/package.json`:
       ```json
       {
         "name": "@jarvis/hud",
         "private": true,
         "version": "0.0.0",
         "type": "module",
         "scripts": {
           "dev": "vite",
           "build": "vite build",
           "typecheck": "tsc --noEmit -p tsconfig.json",
           "test": "vitest run"
         },
         "dependencies": {
           "@jarvis/bus": "workspace:*",
           "react": "^19.2.0",
           "react-dom": "^19.2.0",
           "@react-three/fiber": "^9.6.0",
           "@react-three/drei": "^10.7.0",
           "three": "^0.184.0",
           "zustand": "^5.0.0"
         },
         "devDependencies": {
           "@types/react": "^19.0.0",
           "@types/react-dom": "^19.0.0",
           "@types/three": "^0.184.0",
           "@vitejs/plugin-react": "^5.0.0",
           "typescript": "^5.9.0",
           "vite": "^8.0.0",
           "vitest": "^3.0.0",
           "@testing-library/react": "^17.0.0",
           "@testing-library/jest-dom": "^7.0.0",
           "jsdom": "^25.0.0"
         }
       }
       ```
       If any version doesn't resolve at `pnpm install` time, fall back to the latest compatible published tag and document in SUMMARY.md Decisions. RESEARCH §Standard Stack lists these as 2026-04-22-verified; if ecosystem has moved, pick the next-lower major to avoid breaking-change surprises.
    4. `webview/packages/hud/tsconfig.json`:
       ```json
       {
         "extends": "../../tsconfig.base.json",
         "compilerOptions": {
           "outDir": "dist",
           "rootDir": "src",
           "jsx": "react-jsx",
           "lib": ["ES2022", "DOM", "DOM.Iterable"],
           "types": ["vite/client"],
           "moduleResolution": "bundler",
           "allowImportingTsExtensions": false,
           "noEmit": true
         },
         "include": ["src", "vite.config.ts", "vitest.config.ts", "tests", "index.html"],
         "references": [{ "path": "../bus" }]
       }
       ```
    5. `webview/packages/hud/vite.config.ts`:
       ```ts
       import { defineConfig } from 'vite'
       import react from '@vitejs/plugin-react'
       export default defineConfig({
         base: './',                   // REQUIRED for file:// loading in WKWebView (Pitfall 3)
         plugins: [react()],
         build: {
           outDir: 'dist',
           assetsDir: 'assets',
           emptyOutDir: true,
           sourcemap: 'hidden',
           rollupOptions: {
             output: {
               chunkFileNames: 'assets/[name]-[hash].js',
               entryFileNames: 'assets/[name]-[hash].js',
               assetFileNames: 'assets/[name]-[hash][extname]',
             },
           },
         },
         server: { port: 5174, strictPort: true },
       })
       ```
    6. `webview/packages/hud/vitest.config.ts`:
       ```ts
       import { defineConfig } from 'vitest/config'
       import react from '@vitejs/plugin-react'
       export default defineConfig({
         plugins: [react()],
         test: {
           environment: 'jsdom',
           globals: true,
           setupFiles: ['./tests/setup.ts'],
         },
       })
       ```
       (Plan 03-02 ships `tests/setup.ts` as an empty re-export of `@testing-library/jest-dom` matchers; Plan 03-04 adds the real component tests.)
    7. `webview/packages/hud/index.html` with CSP per RESEARCH §Security Domain lines 1459-1472:
       ```html
       <!DOCTYPE html>
       <html lang="en">
         <head>
           <meta charset="UTF-8" />
           <meta name="viewport" content="width=device-width, initial-scale=1.0" />
           <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none';" />
           <title>Jarvis HUD</title>
         </head>
         <body>
           <div id="root"></div>
           <script type="module" src="/src/main.tsx"></script>
         </body>
       </html>
       ```
       Note: `src="/src/main.tsx"` is Vite dev-server-relative. The BUILT index.html will have `src="./assets/*.js"` after Vite transforms it (with `base: './'`). Test B1 asserts this transformation.
    8. `webview/packages/hud/src/types/globals.d.ts`:
       ```ts
       // Vite's `?raw` import suffix for shader strings (P3-03 uses this)
       declare module '*.glsl?raw' { const src: string; export default src }
       declare module '*.vert?raw' { const src: string; export default src }
       declare module '*.frag?raw' { const src: string; export default src }
       ```
    9. `webview/packages/hud/src/store/types.ts`:
       ```ts
       import type { HudState } from '@jarvis/bus'
       export type { HudState }
       export type ToolCallStatus = 'pending' | 'running' | 'awaiting-approval' | 'completed' | 'failed'
       export type ChatEvent =
         | { id: string; kind: 'text'; text: string; role: 'user' | 'assistant'; turnId: string }
         | { id: string; kind: 'tool-call'; name: string; args: unknown; status: ToolCallStatus; result?: unknown; error?: string; turnId: string }
         | { id: string; kind: 'error'; message: string; turnId: string }
       export type A11y = { reduceMotion: boolean; reduceTransparency: boolean }
       export type Theme = { arcReactorGlow: string }
       export type Connection = 'booting' | 'ready' | 'refused'
       ```
    10. `webview/packages/hud/src/store/index.ts` — Zustand 5 store with subscribeWithSelector middleware, per RESEARCH §Pattern 2 lines 407-486. Actions included: `setHudState`, `appendTokenToLastText`, `upsertToolCall`, `pushEvent`, `setA11y`, `setTheme`, `setConnection`. Plan 03-02 ships the actions but Plans 03-03/03-04 exercise them fully — keep action bodies real (not stubs). Include the `subscribeHudState` helper (imperative subscription for RingMesh/Plan 03-03).
    11. `webview/packages/hud/src/bus/client.ts` — exports `attachBus()`:
       ```ts
       import { installJarvisBus, type BusOutbound } from '@jarvis/bus'
       import { useJarvisStore } from '../store'
       export function attachBus(): void {
         installJarvisBus({
           onDecodeError: (e, raw) => console.error('[bus] decode failed:', e, raw),
         })
         window.jarvisBus.onOutbound((msg: BusOutbound) => {
           switch (msg.type) {
             case 'hello':        /* handled by bridge auto-ack prior to handler registration */ break
             case 'hudState':     useJarvisStore.getState().setHudState(msg.state); break
             case 'tokenDelta':   /* Plan 03-04 wires appendTokenToLastText */ break
             case 'audioLevel':   /* Plan 03-03 may wire an audio-reactive uniform; ignore for now */ break
             case 'toolCallStart':/* Plan 03-04 wires upsertToolCall */ break
             case 'toolCallEnd':  /* Plan 03-04 wires upsertToolCall */ break
             case 'turnStarted':  /* Plan 03-04 may push a delimiter event */ break
             case 'turnEnded':    /* Plan 03-04 */ break
             default: {
               const _exhaustive: never = msg
               void _exhaustive
               console.warn('[bus] unknown outbound:', msg)
             }
           }
         })
       }
       ```
       The "/* Plan 03-04 wires ... */" comments are intentional — they document the expansion points so Plan 03-04 doesn't re-discover them. The switch IS exhaustive today via the `never` sentinel; Plan 03-04 replaces the no-op bodies with real store mutations without changing the switch's shape.
    12. `webview/packages/hud/src/App.tsx`:
       ```tsx
       import { Canvas } from '@react-three/fiber'
       import { RingMesh } from './hud/RingMesh'
       export function App() {
         return (
           <div className="jarvis-hud">
             <div className="jarvis-hud__ring">
               <Canvas
                 camera={{ position: [0, 0, 3], fov: 50 }}
                 gl={{ alpha: true, premultipliedAlpha: false, antialias: true }}
                 dpr={[1, 2]}
               >
                 <RingMesh particles={512} />
               </Canvas>
             </div>
           </div>
         )
       }
       ```
    13. `webview/packages/hud/src/main.tsx`:
       ```tsx
       import { StrictMode } from 'react'
       import { createRoot } from 'react-dom/client'
       import { App } from './App'
       import { attachBus } from './bus/client'
       import './theme/tokens.css'
       attachBus()
       const rootEl = document.getElementById('root')!
       const root = createRoot(rootEl)
       root.render(<StrictMode><App /></StrictMode>)
       // Post uiReady after the first React commit completes.
       queueMicrotask(() => {
         void window.jarvisBus?.send({ type: 'uiReady' })
       })
       ```
       Use `queueMicrotask` (not `setTimeout`) so the uiReady fires on the same tick as the commit (avoids Pitfall 7 token-delta race documented in RESEARCH §Pitfall 7).
    14. `webview/packages/hud/src/theme/tokens.css` — initial CSS custom properties + body transparency per RESEARCH §Brand color inheritance:
       ```css
       :root {
         --arc-reactor-glow: #1E88E5;
         --bg: transparent;
         --text-primary: rgba(255, 255, 255, 0.92);
         --text-secondary: rgba(255, 255, 255, 0.64);
         --card-bg: rgba(20, 24, 30, 0.72);
         --card-border: rgba(255, 255, 255, 0.08);
       }
       html, body, #root { height: 100%; margin: 0; padding: 0; background: transparent; }
       body[data-reduce-transparency="true"] { background: #101418; }
       .jarvis-hud { height: 100vh; display: flex; flex-direction: column; }
       .jarvis-hud__ring { flex: 0 0 60vh; }
       @media (prefers-reduced-motion: reduce) {
         * { animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; transition-duration: 0.01ms !important; }
       }
       ```
    15. `webview/packages/hud/src/hud/RingMesh.tsx` — MINIMAL ring (no state animation yet; Plan 03-03 adds the shader):
       ```tsx
       import { useMemo } from 'react'
       import * as THREE from 'three'
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
             <pointsMaterial size={0.03} color="#1E88E5" sizeAttenuation transparent depthWrite={false} />
           </points>
         )
       }
       ```
       Plan 03-03 replaces `<pointsMaterial>` with drei's `shaderMaterial` and wires the uniforms. For this plan the ring is visible but static.
    16. Run `cd webview && pnpm install` — this will bootstrap node_modules and update pnpm-lock.yaml. Commit the updated lockfile (committing lockfiles is the project's standard per Phase 2 precedent).
    17. Run `pnpm --filter @jarvis/bus build` first (the hud package depends on @jarvis/bus's `dist/`). Then `pnpm --filter @jarvis/hud build`. Verify the outputs per B1/B2.
    18. Run `pnpm --filter @jarvis/hud typecheck` — exit 0.
    19. Note for R3F + drei element namespacing: drei's `<pointsMaterial>` is already an R3F JSX element (from `@react-three/fiber` auto-registering three.js classes). If the executor gets TS errors on `<points>` or `<pointsMaterial>`, the fix is `import { extend } from '@react-three/fiber'` + `import * as THREE from 'three'` + `extend({ Points: THREE.Points, PointsMaterial: THREE.PointsMaterial })` at module top. R3F 9 should handle this automatically via `@react-three/fiber/three-types`, but if it doesn't, this is the escape hatch. Document any such need in SUMMARY.md.
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm install &amp;&amp; pnpm --filter @jarvis/bus build &amp;&amp; pnpm --filter @jarvis/hud build &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; test -f packages/hud/dist/index.html &amp;&amp; grep -q 'src="\./assets/' packages/hud/dist/index.html &amp;&amp; ! grep -q 'src="/assets/' packages/hud/dist/index.html &amp;&amp; grep -c '_exhaustive: never' packages/hud/src/bus/client.ts</automated>
  </verify>
  <done>
    - `webview/packages/hud/` exists with the 14 files listed.
    - `pnpm install` completes; `pnpm-lock.yaml` is updated.
    - `pnpm --filter @jarvis/hud build` produces `dist/index.html` + at least one `dist/assets/*.js` chunk.
    - `dist/index.html` references `./assets/...` (relative), NOT `/assets/...`.
    - `pnpm --filter @jarvis/hud typecheck` exits 0.
    - `grep 'as never'` in client.ts returns zero; `_exhaustive: never` appears at least once.
    - CSP meta tag present in index.html with `connect-src 'none'`.
    - Running `pnpm --filter @jarvis/hud dev` (optional manual spot-check) serves the app on http://127.0.0.1:5174/ with the static ring visible. (Not automated — dev-server is not part of CI.)
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Store + bus-dispatcher Vitest coverage + exhaustiveness-sentinel drift probe documentation</name>
  <files>webview/packages/hud/tests/store.test.ts, webview/packages/hud/tests/bus-dispatch.test.ts, webview/packages/hud/tests/setup.ts</files>
  <behavior>
    - Test S1 (store.test.ts: default values): `useJarvisStore.getState()` returns `{hudState: 'booting', chatEvents: [], a11y: {reduceMotion: false, reduceTransparency: false}, theme: {arcReactorGlow: '#1E88E5'}, connection: 'booting', ...actions}`.
    - Test S2 (store.test.ts: setHudState isolates mutations): call `setHudState('thinking')`; verify `hudState === 'thinking'` AND `chatEvents === []` (same reference — setState didn't clone the whole store).
    - Test S3 (store.test.ts: subscribeWithSelector fires only on relevant change): subscribe to `state => state.hudState`; dispatch `pushEvent(...)`; assert subscriber NOT called. Dispatch `setHudState('listening')`; assert subscriber called once.
    - Test S4 (store.test.ts: appendTokenToLastText no-op on missing id): `appendTokenToLastText('does-not-exist', 'hi')` leaves `chatEvents === []`.
    - Test B1 (bus-dispatch.test.ts: hudState routes to store): install mock `window.webkit.messageHandlers.jarvisBus` + mock `window.jarvisBus`; call `attachBus()`; synthesize a `window.jarvisBus.receive('{"type":"hudState","state":"speaking"}')`; assert `useJarvisStore.getState().hudState === 'speaking'`.
    - Test B2 (bus-dispatch.test.ts: unknown type hits onDecodeError): inject a spy as onDecodeError; receive an invalid JSON; assert the spy is called with a string starting with `"parse error"` or `"missing discriminator"`.
    - Test B3 (bus-dispatch.test.ts: uiReady is posted by main.tsx boot): simulated via jsdom — import main.tsx side-effectfully inside a test; wait a microtask; assert `window.webkit.messageHandlers.jarvisBus.postMessage` was called with the uiReady JSON (mock the webkit side).
    - Test B4 (bus-dispatch.test.ts: exhaustiveness proof — manual): a test comment block documents "to verify the sentinel bites, add a ficticious case to BusOutbound locally and run pnpm typecheck; you should see TS2322 on `_exhaustive`". Task 2 does NOT modify the @jarvis/bus type union; this is a documentation test. (Do not include a fail-at-runtime check because the sentinel is compile-time only; Plan 03-02 relies on `pnpm typecheck` as the enforcement.)
  </behavior>
  <action>
    1. Create `webview/packages/hud/tests/setup.ts`:
       ```ts
       import '@testing-library/jest-dom'
       ```
       (Extension matchers for DOM tests in Plan 03-04; harmless for this plan's tests.)
    2. Create `webview/packages/hud/tests/store.test.ts` covering S1–S4 with vitest's `beforeEach` to reset the store (use `useJarvisStore.setState` to restore defaults; keep this helper local to the test file).
    3. Create `webview/packages/hud/tests/bus-dispatch.test.ts` covering B1–B4. B1/B2 mock `window.webkit.messageHandlers.jarvisBus` with `{ postMessage: vi.fn() }` before calling `attachBus()`. B3 imports `main.tsx` in a test body (dynamic `await import('../src/main')` after setting up DOM + webkit mock).
    4. Run `pnpm --filter @jarvis/hud test`. Expect all tests green (target ≥8 test methods).
    5. Run `pnpm --filter @jarvis/hud typecheck` — still exit 0 with the new test files included.
    6. OPTIONAL probe (do not commit): for Task 2's own confidence, temporarily add a fake `| { type: 'futureCase'; data: string }` to a local `_probe.ts` file and import it in client.ts just to confirm `tsc` flags `_exhaustive: never` with TS2322. Revert the probe before commit. If the probe does NOT flag TS2322, Plan 03-02 has a broken sentinel — fix per 02-02 SUMMARY §Deviations #1 (drop any `as never` cast, strong-type the switch scrutinee).
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm --filter @jarvis/hud test 2>&amp;1 | tail -10 &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; grep -c 'describe\|it\|test' packages/hud/tests/store.test.ts packages/hud/tests/bus-dispatch.test.ts</automated>
  </verify>
  <done>
    - `pnpm --filter @jarvis/hud test` reports all tests passing.
    - At least 8 test methods total across `store.test.ts` + `bus-dispatch.test.ts`.
    - `pnpm --filter @jarvis/hud typecheck` exits 0.
    - The probe (optional; NOT committed) produced TS2322 on the sentinel when run locally, confirming the exhaustiveness guard is live. Document in SUMMARY.md that the probe was run.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Swift → webview (callAsyncJavaScript) | Trusted in-process; Swift is the source of truth. The `receive(payload)` string is a JSON-encoded BusOutbound; decoder (decodeOutbound) never throws on malformed. |
| webview → Swift (postMessage) | Untrusted page origin IF anyone else had WKWebView access, but the bus operates in an isolated `JarvisBusWorld` content world (Phase 2 guarantee), so no page script can reach it. |
| Bundle → WKWebView filesystem | `base: './'` in Vite config confines asset references to the bundle directory. Plan 03-05 configures `loadFileRequest(_:allowingReadAccessTo:)` to scope filesystem access to the bundle's webview/ subdirectory. |
| CSP enforcement | `connect-src 'none'` denies any remote fetch; `script-src 'self'` denies inline scripts. Verified via inspection of index.html post-build. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-10 | Tampering | Vite build absolute asset paths | mitigate | `base: './'` in vite.config.ts; Test B1 verifies `src="./assets/` in built index.html. Absolute `/assets/` references would 404 in WKWebView file:// context (Pitfall 3). |
| T-03-11 | Spoofing | Remote script inclusion via CSP bypass | mitigate | CSP meta enforces `script-src 'self'`, `connect-src 'none'`, `object-src 'none'`. Test B6 validates presence. Plan 03-05 verifies CSP survives into the bundle-vendored copy. |
| T-03-12 | Tampering | Bus schema drift between Swift and TS | mitigate | Imports only from `@jarvis/bus` (Phase 2 canonical source). Exhaustiveness sentinel (`_exhaustive: never`, no `as never` cast) on outbound dispatcher. Plan 02-04's parity scripts continue to enforce Swift ↔ TS lock-step; Plan 03-02 is a consumer, not a mirror. |
| T-03-13 | Information disclosure | Zustand store visible to DevTools | accept | The user runs WKWebView locally in a single-user app; DevTools access requires explicit developer overlay (Phase 4). No secrets in the store — only UI state. Documented risk per RESEARCH §Pitfall 9. |
| T-03-14 | Denial of service | RingMesh 512 particles at 60 FPS | accept | RESEARCH §A3 (512 on 4-yr-old Apple Silicon target). Plan 03-03 adds state animations; if perf degrades, fall back to 256. This plan's static ring is not on the hot path. |
| T-03-15 | Tampering | window.jarvisBus replay if a page script got hold | mitigate | Phase 2 ships the WKUserScript + handler in `JarvisBusWorld` isolated content world. This plan does NOT touch that isolation; it consumes the already-installed `window.jarvisBus` within the same isolated world. |
</threat_model>

<verification>
Phase-gate for Plan 03-02:
1. `cd webview && pnpm install` succeeds.
2. `pnpm --filter @jarvis/bus build && pnpm --filter @jarvis/hud build` produce `webview/packages/hud/dist/index.html` with relative asset paths.
3. `pnpm --filter @jarvis/hud test` reports ≥8 passing tests, 0 failing.
4. `pnpm --filter @jarvis/hud typecheck` exits 0.
5. `grep -q 'src="\./assets/' webview/packages/hud/dist/index.html` succeeds.
6. `! grep -q 'src="/assets/' webview/packages/hud/dist/index.html` succeeds.
7. `grep -c '_exhaustive: never' webview/packages/hud/src/bus/client.ts` ≥ 1.
8. `grep -c 'as never' webview/packages/hud/src/` returns 0.
9. `cd packages/Bus && swift test` stays 47/47 green (proves no cross-contamination).
10. No files modified outside `webview/`, `.planning/`, or `pnpm-lock.yaml`.
</verification>

<success_criteria>
- Buildable, typechecked, test-covered `@jarvis/hud` package exists at `webview/packages/hud/`.
- Vite 8 produces a WKWebView-compatible bundle with relative asset paths.
- Zustand 5 store with `subscribeWithSelector` middleware is in place for Plans 03-03/03-04 to consume.
- Bus dispatcher has an exhaustiveness sentinel that fails `tsc --strict` if a new BusOutbound case lands without handler wiring.
- React 19 app mounts, renders a static 512-particle ring, and posts `uiReady` back to Swift.
- All versions from RESEARCH §Standard Stack are pinned (any deviations documented in SUMMARY.md).
- Plan 03-05 can consume this bundle directly via `rsync dist/ → App/Resources/webview/` without touching TS source.
</success_criteria>

<output>
After completion, create `.planning/phases/03-hud/03-02-SUMMARY.md`:
- Frontmatter `requirements-completed: [HUD-01]` (HUD-01 is partially complete — scaffold + build exists; full HUD-01 validation lands in Plan 03-05 when WKWebView loads it).
- `provides`: `webview/packages/hud/` buildable package; store + bus dispatcher consumable by 03-03/03-04; dist output consumable by 03-05.
- Resolved versions of React / R3F / drei / three / Zustand / Vite as captured at build time.
- Decisions: any version fallback from RESEARCH pins; any element namespace workarounds for drei/three; probe outcome for exhaustiveness sentinel.
- Known stubs: ring is static (no state animations); chat panel absent; bus dispatcher has no-op arms for tokenDelta/toolCall/turn events awaiting Plans 03-03/03-04.
- Next plan readiness: Plan 03-03 layers shader material + uniforms into RingMesh.tsx; Plan 03-04 adds ChatPanel.tsx + wires no-op dispatcher arms; Plan 03-05 copies dist/ into the bundle.
</output>
