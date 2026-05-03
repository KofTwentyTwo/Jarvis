# HUD / WebKit / R3F Visual Layer — Brutal Audit

**Date:** 2026-05-03
**Scope:** `webview/packages/hud/`, the bundled webview at `App/Resources/webview/`, and the Swift loader at `App/AppDelegate.swift`.
**Auditor verdict:** the visual layer was over-built and under-validated. The core symptom ("rings are static at STANDBY") is not a build/load/bridge bug — it is the **literal contents of the state table at `src/hud/stateUniforms.ts:30`**, where `idle` is hard-coded to `pulse: 0.0, rotate: 0.0`. Everything is "working as designed"; the design is wrong.

---

## TL;DR

**Grade: D+.**

The code compiles, builds, deploys, mounts, and renders. The bus handshake reaches `armed`, `hudState=idle` is dispatched and applied to the store, and `useFrame` fires every animation frame against the live store. But the table that converts `idle` into shader uniforms hard-codes `pulse=0, rotate=0`, so the entire arc-reactor visual reduces to a still life as soon as boot completes. None of the 87 passing tests assert that any frame value actually changes. There is also a latent `tsc --strict` failure (`SegmentedRing.tsx:92`) and a broken `audioLevel` plumbing (TODO comment, no consumer). Roughly 50 hours of effort produced a bundle that visibly works for the chat panel, mounts a complex R3F scene that *should* animate when state changes, and gates the cinematic centerpiece on a `0.0` literal.

---

## 1. Bundle build — present, current, and deployed

- `webview/packages/hud/package.json:8` — `"build": "vite build"`. Configured to emit `dist/index.html` plus a single IIFE bundle in `dist/assets/`.
- `webview/packages/hud/vite.config.ts:50-67` — non-trivial config: `base: './'`, IIFE format, `inlineDynamicImports: true`, plus a custom `stripModuleAttrs` plugin that rewrites `<script type="module">` to `<script defer>` because WKWebView's `file://` null-origin can't fetch ES modules. **This config is correct and necessary**, and the comments document the bug class painfully — clearly someone burned hours discovering this, then hardened it.
- Build artifact lives at `webview/packages/hud/dist/assets/index-CAVzz6r-.js` (1,107,433 bytes, mtime `May 3 09:38:49`).
- The Swift app loads via `App/AppDelegate.swift:1537-1564`:
  - `Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "webview")`
  - `panel.webView.loadFileURL(entryURL, allowingReadAccessTo: resourcesDir)`
- Deployed copy at `App/Resources/webview/index.html` is **byte-identical** to `dist/index.html`. Both reference `./assets/index-CAVzz6r-.js`.
- Deployed bundle `App/Resources/webview/assets/index-CAVzz6r-.js` is **byte-identical** (same hash, same 1,107,433 bytes, same mtime) to the dist build.

**Observation:** there are **9 stale bundle files** sitting in `App/Resources/webview/assets/` (oldest `Apr 24`, total ~9.9 MB). Only the one referenced by `index.html` is loaded; the rest are dead weight from prior builds. Not a bug, just sloppy hygiene. Add a `clean` step to whatever copies `dist/` into `App/Resources/webview/`.

**Verdict for §1:** the build pipeline works. The right bundle is in the right place. This is not where the problem lives.

---

## 2. R3F ring animation — why it's static

This is the load-bearing finding.

### The `useFrame` hook fires correctly

- `RingMesh.tsx:169` — `useFrame((_, delta) => { … })` is registered on every layer.
- `ParticleRing.tsx:66` — separate `useFrame` for camera drift.
- `Reticle.tsx:20`, `CoreGlow.tsx:28`, `SegmentedRing.tsx:86` — all subscribe via `useFrame`.
- The bundle contains R3F's RAF driver (`Rv = requestAnimationFrame(Rv)` plus `Mv` which iterates `internal.subscribers` and invokes each `useFrame` callback — visible in the minified bundle around the `Mv`/`Rv`/`zv` symbols). `<Canvas>` defaults to `frameloop="always"` and the code does not override it.

### The `uTime` uniform is being written

- `RingMesh.tsx:201` — `matRef.current.uTime += delta` runs every frame.
- `RingMesh.tsx:202-224` — `uStateIdx`, `uStateBlend`, `uPulseSpeed`, `uRotateSpeed`, `uColorGlow`, `uReduceMotion`, `uOutwardWaveAmp`, `uIntensity`, `uCoreBoost`, `uPhase`, `uRadiusScale`, `uPointSize` all written every frame.

### The state subscription is correctly wired

- `RingMesh.tsx:172` — `const s = useJarvisStore.getState()` inside `useFrame` (the documented Pitfall 1 guard against per-frame React re-renders). Reads live store on every tick.

### The bug

`stateUniforms.ts:30`:

```ts
idle: { pulse: 0.0, rotate: 0.0, color: 'theme', densityMod: 'none' },
```

When the bus delivers `hudState = idle` (the sole steady state during STANDBY), the shader receives:

- `uPulseSpeed = 0.0` → vertex shader `ring.vert.glsl:28` computes `sin(uTime * 0 * 6.2831) * 0.04 = 0`. No pulse.
- `uRotateSpeed = 0.0` → `ring.vert.glsl:25` computes `theta = aTheta + uPhase + uTime * 0`. No rotation.
- `uOutwardWaveAmp = 0` (because `densityMod !== 'wave'`) → no wave.

So the shader is correctly given exactly zero motion in the idle state. The same logic kills `SegmentedRing.tsx:111` (`speed = p.rotate * rotationMultiplier * 0.4 = 0`), `CoreGlow.tsx:49` (sphere pulse scalar collapses to `1.0`), `CoreGlow.tsx:70` (torus rotation = 0), and `Reticle.tsx:36` (group rotation and breath both static).

**The HUD is doing exactly what the table says, and the table says "do nothing on idle."**

This contradicts Phase 3's verification record (`.planning/phases/03-hud/03-VERIFICATION.md:39-40` per AUDIT-FINDINGS.md): "Ring transitions booting → idle within 2s of summon; ring is visibly animated (pulse/rotate) with arc-reactor-glow color." The promise was "animated in idle." The implementation delivers "frozen in idle."

The cited research (`stateUniforms.ts:8-10`, "Per RESEARCH §Particle Ring Visual Design table (lines 854-862)") — the table that drove this — defines `idle` as zero-motion. Either the research was wrong, or someone copied the table without reconciling it against the verification criterion. Either way, the cinematic STANDBY visual the user paid 50 hours for cannot exist with these parameters.

### What needs to change

Pick low-but-non-zero values for `idle.pulse` and `idle.rotate` (something like `pulse: 0.5, rotate: 0.08`). Or introduce a separate "ambient idle drift" uniform that is independent of `uPulseSpeed`/`uRotateSpeed` and is always non-zero so even quiet states breathe. Either fix is one-file, ~3-line.

### Sub-finding: `audioLevel` is wired to nothing

- `bus/client.ts:135-138` — `case 'audioLevel': // Plan 03-03's ring shader uses a synthetic sine; Phase 6 binds this to the real mic RMS. Intentional no-op for P3.`

The shader has no `audioLevel`-driven uniform and no `useFrame` consumer subscribes to it. So even if Swift sent live mic RMS, the rings wouldn't react. This is documented as deferred to Phase 6 — fine — but the user said "rings don't animate" and `audioLevel` would be a natural input. Currently it's a dead drop.

---

## 3. Tests — present in volume, useless against this bug

| Test | File | Classification | Catches static rings? |
|---|---|---|---|
| `ParticleRing mounts inside a Canvas without throwing` | `RingMesh.test.tsx:37` | **MOCK** — renders into jsdom (no WebGL); only proves no exception thrown | **NO** |
| `LoadingFallbacks` (5 cases) | `RingMesh.test.tsx:48-116` | **REAL** for DOM behavior; none touch R3F | **NO** |
| `easeStateBlend` (5 cases) | `RingMesh.test.tsx:118-139` | **REAL** — pure-function math test of one easing helper | **NO** — would still pass with motionless rings |
| `STATE_PARAMS has entries for all 7 HudStates` | `stateUniforms.test.ts:40` | **REAL** — table coverage check | **NO** — and it codifies the bug: `pulse=0` for idle is *asserted* in `TABLE` at line 31 |
| `STATE_PARAMS[idle].pulse === 0` (and 6 others) | `stateUniforms.test.ts:47-49` | **REAL** | **NO** — actively *enforces* the bug |
| `parseHex` (2 cases) | `stateUniforms.test.ts:92-104` | **REAL** | NO |
| `ring.vert.glsl + ring.frag.glsl import via ?raw` | `stateUniforms.test.ts:107-114` | **REAL** | NO — only proves shader *strings* exist |
| `streaming.test.tsx` (D1–D8, I1) | bus dispatcher | **REAL** for store mutation; **MOCK** of webkit | NO — entirely orthogonal |
| `chronology.test.tsx`, `ChatPanel.test.tsx`, `ChatInput.test.tsx`, `ToolCallCard.test.tsx`, `bus-dispatch.test.ts`, `store.test.ts` | various | **REAL** for chat/store; **MOCK** of bus | NO |

There are **zero tests that mount the Canvas, advance frames, and assert any uniform or transform changed**. The `RingMesh.test.tsx:37` mount test is structurally a smoke test that only catches "import explosions." `@react-three/test-renderer` is the standard tool for the missing test class — it's the same package family, ~10 lines of harness, and was rejected at line 23 ("we avoid `@react-three/test-renderer` to stay on the webview's existing dep surface"). That's the wrong call: catching this regression would have saved more time than `npm i -D` cost.

Worse, `stateUniforms.test.ts:31` *literally encodes the bug as expected behavior*. A regression that introduced motion in idle would *fail* this test. The test suite is not just blind — it's actively guarding the bug.

---

## 4. HudFrame chrome — mostly dead

`HudFrame.tsx` renders four panels of text. Of the visible fields:

| Field | File:line | Source |
|---|---|---|
| `SYS: JARVIS Mk-II` | `HudFrame.tsx:33` | **Static template** |
| `STATE: STANDBY` (etc.) | `HudFrame.tsx:36` | **Live** — subscribes to `hudState` via the hook (line 16) and maps through `STATE_DISPLAY` (line 79-87) |
| `CLK: 12:34:56` | `HudFrame.tsx:40` | **Live (clock-driven)** — `useClock()` updates every 1000 ms via `setInterval` (lines 147-153) |
| `PWR: 100%` | `HudFrame.tsx:48` | **Static** |
| `CORE: NOMINAL` | `HudFrame.tsx:52` | **Static** |
| `LINK: SECURE` | `HudFrame.tsx:56` | **Static** |
| Center state readout | `HudFrame.tsx:63` | **Live** — same `hudState` |
| Ticker (16 items: `CORE 100%`, `PALLADIUM 14%`, `WAKE WORD ARMED`, `MCP HELPERS 3`, `OPUS 4.7 ONLINE`, etc.) | `HudFrame.tsx:116-133` | **All static template strings** |
| Corner brackets | `HudFrame.tsx:99-114` | Static SVG, accent color via `data-state` |

So three of ~22 fields are reactive (`hudState`, clock, accent color). Everything else is theatrical filler that says nothing about the live system. `WAKE WORD ARMED` will keep claiming to be armed even when the wake-word stack is dead. `MCP HELPERS 3` is a hard-coded literal. `TCC AUDIO ✓` does not consult the TCC probe.

This is fine for a stylistic prop, but every one of those strings is a future credibility-loss point. Wire the ticker to the actual subsystem statuses, or shorten it to just the live ones.

---

## 5. Bus → store → render path — actually connected

Tracing one `BusOutbound.hudState`:

1. **Swift sends** — `App/AppDelegate.swift:1480`, `bridge.send(.hudState(busHudState(from: appState)))`. Encoded as JSON, dispatched via `WKContentWorld.page` (per the F-A2-01 finding, this is correct; the test that asserted otherwise was the bug). Delivered into the page via the bridge's `evaluateJavaScript("window.jarvisBus.receive(payload)")`.
2. **JS receives** — `@jarvis/bus` (in `webview/packages/bus/`) decodes and invokes the registered outbound handler.
3. **Store mutation** — `bus/client.ts:63-65`: `case 'hudState': store.setHudState(msg.state); break`. `setHudState` in `store/index.ts:63` does `set({ hudState: s })`, which updates the zustand store atomically.
4. **Consumers read live** — every `useFrame` body in `RingMesh.tsx:172`, `Reticle.tsx:21`, `CoreGlow.tsx:29`, `SegmentedRing.tsx:102`, `ParticleRing.tsx:67` calls `useJarvisStore.getState()` once per frame. These are **non-subscribing** reads, so the store update doesn't re-render React but it *is* visible on the next frame tick.
5. **HudFrame.tsx:16 / LoadingFallbacks.tsx:16-17** — subscribing reads via `useJarvisStore((s) => s.hudState)` for the DOM chrome. These cause React re-renders on state change, which is correct for low-frequency updates.
6. **Render** — uniforms get written; if the per-state values are non-zero, the shader animates.

**End-to-end this works.** The boot transition `booting → idle` is observable in the chrome (the `STATE` row flips from BOOTING to STANDBY). The ring genuinely receives the new `idle` parameters. They are just `pulse=0, rotate=0`. So the path is correct; the destination is wrong.

---

## 6. TypeScript health — one strict failure, latent

```
$ npm run typecheck -C webview/packages/hud
src/hud/SegmentedRing.tsx(92,27): error TS18048: 'm' is possibly 'undefined'.
src/hud/SegmentedRing.tsx(92,34): error TS18048: 'm' is possibly 'undefined'.
src/hud/SegmentedRing.tsx(92,42): error TS18048: 'm' is possibly 'undefined'.
```

`SegmentedRing.tsx:91` does `const m = initialMatrices[i]` where `initialMatrices` is `T[]` and indexing returns `T | undefined` under `noUncheckedIndexedAccess`. The next line `tmpMatrix.compose(m.pos, m.quat, m.scale)` dereferences `m` without a null check.

This is not a runtime bug — `i` ranges over `0..tickCount-1` and the array is constructed with `tickCount` entries, so `m` is provably defined. It is a TS-strictness regression that pre-dates this session's debugging. Fix is trivial:

```ts
const m = initialMatrices[i]!
```

or guard it explicitly. The fact this is currently failing means **`npm run typecheck` is not part of any pre-commit / pre-build gate** — Vite's build does its own minimal type-stripping pass and doesn't run `tsc`. So the project has been shipping without strict-typecheck gating. That's a process bug, not just a code bug.

No other TS errors observed.

---

## 7. What actually works visually

Confirmed working from screenshots + reading code:

- **HudFrame chrome.** Corner brackets, top-left/top-right panels, "STANDBY" state label (live), clock (live), bottom ticker (animated by CSS — `hud-frame.css` runs the marquee, fully decoupled from R3F).
- **ChatPanel + ChatInput.** Renders, accepts text, the Send button posts `chatSubmit` (`ChatInput.tsx`), the bus dispatcher synthesizes user-text events optimistically, the streaming path D1–D8 is live (commits 326a27d, 602a95b verify token deltas land).
- **The R3F Canvas mounts.** WebGL is initialized; the bundle contains the full Three.js renderer; the scene graph (`<group>` of layers, four `<RingLayer>`, two `<SegmentedRing>`, `<CoreGlow>`, `<Reticle>`) is built. The dots the user sees ARE rendered by R3F — they are the additive-blended point sprites from `ring.frag.glsl`. **It is not a CSS fallback or loading state.**
- **The ring transitions during state changes.** When state goes `booting → idle`, the 150 ms eased crossfade in `RingMesh.tsx:188-192` runs. So if you transition to `thinking` (`pulse: 1.5, rotate: 1.0`) it WILL animate. The static appearance is specific to `idle`.

What does NOT work:

- Any animation while at `idle` (= STANDBY = the default steady state the user sees 99% of the time).
- `audioLevel` → ring (no consumer).
- The strict-typecheck pre-commit gate (because there isn't one).
- Tests catching the symptom.

---

## Recommended fixes (prioritized)

1. **(5 min, unblocks UAT)** Edit `stateUniforms.ts:30` to give `idle` a real ambient rotation/pulse. Suggestion:
   ```ts
   idle: { pulse: 0.4, rotate: 0.06, color: 'theme', densityMod: 'none' },
   ```
   Update `stateUniforms.test.ts` TABLE row at line 31 to match. Smoke-test the launch.
2. **(30 min, kills the regression class)** Add `@react-three/test-renderer` and write one test that:
   - Renders `<ParticleRing />` with `useJarvisStore.setState({ hudState: 'idle' })`.
   - Advances frames for 100 ms.
   - Asserts at least one of the four layers' material `uTime > 0` and a non-zero rotation accumulated. (This catches "useFrame stopped firing" regressions and "idle is frozen" regressions in one test.)
3. **(2 min)** Fix `SegmentedRing.tsx:92` with `!` or a guard. Add `npm run typecheck` to whatever script runs before `vite build` in the App's resource-copy step.
4. **(15 min)** Decide what to do with the static ticker fields. Either drive at least the SUBSYSTEM-presence ones (`MCP HELPERS N` from the actual MCP child manager state, `WAKE WORD ARMED` from the wake-word feature flag) from the store, or remove them. Keep the lyrical ones (`PALLADIUM 14%`) as flavor.
5. **(5 min)** Delete the 8 stale bundles in `App/Resources/webview/assets/`. Add a clean step to the resource-copy script.

Total fix surface for the visible regression: **~3 lines of code in one file**. Fifty hours of agent work bypassed it because every test in the suite is structured around state plumbing, not visual behaviour, and one of those tests *codified the broken value*.
