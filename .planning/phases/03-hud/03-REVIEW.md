---
phase: 03-hud
review_depth: standard
files_reviewed: 52
diff_base: 9689a1d
diff_head: 1fd18ca
reviewer: gsd-code-reviewer
review_date: 2026-04-24
summary: "Phase 3 is close to ship-quality; one sentinel-fragility bug in the tool-call dispatcher is a HIGH defense-in-depth gap, and a suite of MEDIUM/LOW hygiene items. No Critical blockers. Recommend one code-review-fix pass before /gsd-verify-phase 3."
findings_by_severity:
  critical: 0
  high: 2
  medium: 6
  low: 7
  info: 4
---

# Phase 3 Code Review

## Overall Assessment

Phase 3 delivers everything the plans promised and the invariants hold: HudStateCoordinator is genuinely the single Swift writer (lint activated, allowlist minimal), pre-approval args are defense-in-depth hidden, all chat text goes through React text interpolation, and the bundle shape on disk matches what the smoke script enforces. The Swift 6 concurrency shape is careful (`[weak self]` + cancellation + MainActor isolation) and the test surface is deep — 79 webview + 19 coordinator + 6 enum + 6 bridge-wiring + 3 bundle-load tests, plus a 20-message fixture replay proving chronology. The Phase 2 schema is untouched, `useFrame` uses `.getState()` not the hook, and there is no unsafe-HTML-injection escape hatch anywhere in the diff.

That said, adversarial reading surfaced one HIGH-severity sentinel-fragility defect in `bus/client.ts` (literal string equality for the `awaitingApproval` detection — whitespace-sensitive, drifts silently from `isApprovalPlaceholder`'s parsed-object check) and one HIGH concurrency-correctness concern around `WKContentWorld` isolation that Phase 2's harness happened to sidestep but Phase 3's `main.tsx` now touches. Both are fixable with minimal edits. The MEDIUM tier is dominated by test-hygiene drift (incomplete `resetStore()` helpers after the store grew new slices), minor Swift 6 redundancies (a doubly-hopped Task inside a `@MainActor` closure swallowing errors with `try?`), a couple of indirect-mutation patterns, and two GLSL brittleness points (`gl_PointSize` divide-by-zero risk if geometry ever moves, and `uTime` monotonic accumulation that will eventually lose shader precision).

The Xcode 26 xctest blocker remains out of scope per the phase context — tests COMPILE and the structural file-read tests + `scripts/smoke-test-hud.sh` are the correct runtime substitute. The `.planning/phases/03-hud/.continue-here.md` note about "paused at wave 1/3" appears to be stale leftover from an early-wave commit — the code on disk is complete, all 5 waves landed, and CLAUDE.md's recent commit log confirms this. No action needed.

**Verdict:** recommend `/gsd-code-review-fix 3` to land the 2 HIGH findings and 2-3 MEDIUM wins, then proceed to `/gsd-verify-phase 3`.

## Findings

### Critical (blocks merge)

_None._

### High (should fix before merge)

#### H-01: Fragile literal-string sentinel detection in `bus/client.ts` drifts from the defense-in-depth guard

**File:** `webview/packages/hud/src/bus/client.ts:96`
**Issue:** `toolCallStart` determines whether to set `status: 'awaiting-approval'` with a literal string equality:
```ts
const isApproval = msg.argsPreview === '{"awaitingApproval":true}'
```
This compares the raw JSON bytes, so any whitespace or key-ordering variation from Swift — e.g. `'{"awaitingApproval": true}'`, `'{ "awaitingApproval":true }'`, or an encoder that prefixes/suffixes whitespace — silently defeats the detection. The card's `hideArgs` gate in `ToolCallCard.tsx` uses the parsed-object check (`isApprovalPlaceholder(event.args)`), so args are still hidden (good — defense-in-depth works). But the status label in the card would read "Running" while the body shows "(hidden until you approve)" — a confusing UX and, more importantly, a latent drift between two sentinel-detection mechanisms that were supposed to agree.

This is invisible today because the only Phase-2 producer is test fixtures that hand-craft the exact byte string. Phase 5 MCP-04 is the real producer and has not yet been written; if that path uses `JSONEncoder(.prettyPrinted)` or any field ordering, the sentinel detection here regresses silently.

**Fix:** unify both sentinel checks on the parsed-object form. `parseArgs` already exists and runs anyway:
```ts
case 'toolCallStart': {
  const turnId = store.currentTurnId ?? 'untracked'
  const parsedArgs = parseArgs(msg.argsPreview)
  const isApproval = isApprovalPlaceholder(parsedArgs)
  store.upsertToolCall(msg.id, {
    name: msg.name,
    args: parsedArgs,
    status: isApproval ? 'awaiting-approval' : 'running',
    turnId,
  })
  // ...
}
```
Export `isApprovalPlaceholder` from `ToolCallCard.tsx` (or lift it to a shared util) so there's one detection function, not two. Add a D-series test with `'{"awaitingApproval": true}'` (note space after colon) asserting `status === 'awaiting-approval'`.

---

#### H-02: `main.tsx` installs `window.jarvisBus` in the page's default JS world; Swift `callAsyncJavaScript(..., in: JarvisBusWorld)` + `webkit.messageHandlers.jarvisBus` are world-scoped to `JarvisBusWorld`

**File:** `webview/packages/hud/src/main.tsx:7`, `webview/packages/hud/src/bus/client.ts:56`
**Issue:** `main.tsx` runs from `<script type="module" src="./assets/index-*.js">` in `index.html` — i.e. the page's default content world. It imports `installJarvisBus` from `@jarvis/bus` and ultimately writes `window.jarvisBus = bus` and `window.jarvisBus.onOutbound(handler)` in the default world.

Meanwhile, the Swift side (Phase 2 `WebviewBridge`):
- installs the Injection.js `WKUserScript` `in: contentWorld` = `WKContentWorld.world(name: "JarvisBusWorld")`
- registers `addScriptMessageHandler(_, contentWorld: JarvisBusWorld, name: "jarvisBus")`
- calls outbound via `callAsyncJavaScript(..., in: JarvisBusWorld)`

Per Apple's WKContentWorld semantics, the message handler (`window.webkit.messageHandlers.jarvisBus`) is **only visible inside `JarvisBusWorld`**. A `send()` from the default world hits `window.webkit?.messageHandlers?.jarvisBus === undefined`, which `bridge.ts` converts to `throw new Error("[bus] webkit.messageHandlers.jarvisBus is not available")`. The optional-chained `main.tsx` queueMicrotask call (`void window.jarvisBus?.send({ type: 'uiReady' })`) swallows that silently but the ripple is: **`uiReady` is never posted to Swift**, and every `.send()` from the HUD webview throws and is lost.

The observed Phase-2 "handshake armed" success came from Injection.js's own auto-ack in the bus world; the bus-harness.html marker script only logged, never called `send`. Phase 3 is the first caller in main world, and the Phase 3 manual UAT is still flagged "pending" in `03-05-SUMMARY.md` line 124 — meaning this path has never actually been exercised end-to-end yet.

Note that the `window.jarvisBus` GLOBAL is shared across worlds because WebKit keeps `window` as one object (only world-scoped variables are isolated), so the Injection.js-installed `jarvisBus` IS what the HUD sees when it references `window.jarvisBus`. The problem is specifically that `installJarvisBus()` from `@jarvis/bus` then OVERWRITES this shared property with a default-world version whose `_handler` is registered there — and whose `send()` path can't reach `webkit.messageHandlers.jarvisBus`.

**Fix (pick one; neither is invasive):**

Option A — **run the HUD bundle in `JarvisBusWorld`.** Inject it via `WKUserScript(source: <bundle JS>, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: JarvisBusWorld)` instead of relying on the `<script src>` tag. Matches the injection world, makes `webkit.messageHandlers` reachable. Requires reading `assets/index-*.js` at runtime and feeding it to WKUserScript.

Option B — **don't overwrite `window.jarvisBus` in the HUD.** Change `installJarvisBus` (or add an `attachToExistingBus` entry point) so that when `window.jarvisBus` already exists (installed by Injection.js in the bus world, shared via `window`), we register a handler on the existing object rather than replacing it. Also route `send()` through the existing bus, which already knows how to reach `webkit.messageHandlers` from its own world. This is the smaller edit.

Option C — verify with a manual UAT (build + open app + tail `~/Library/Logs/Jarvis/system.log`) that `uiReady` actually arrives and that HUD→Swift outbound survives. If it does, my world-isolation model is wrong for this WebKit version; add a short doc-comment on `main.tsx` explaining why the shared-window trick works so future readers don't re-hit this analysis. **Until a human confirms the UAT pass, this should block `/gsd-verify-phase 3`.**

Confidence: ~80%. I have high confidence in the content-world isolation model for `webkit.messageHandlers`; I have lower confidence that `window.jarvisBus` being a shared property (vs. per-world) will rescue the outbound path. A 5-minute UAT resolves it definitively.

---

### Medium (fix when convenient)

#### M-01: `AppDelegate.installBus()` emit closure double-hops through `Task { @MainActor in ... }` inside an already-@MainActor-isolated closure, AND swallows every error via `try?`

**File:** `App/AppDelegate.swift:331-336`
**Issue:**
```swift
let coordinator = HudStateCoordinator(emit: { [weak bridge] appState in
    guard let bridge else { return }
    Task { @MainActor in
        try? await bridge.send(.hudState(busHudState(from: appState)))
    }
})
```
The `emit` parameter is typed `@escaping @MainActor (HudState) -> Void`, so the closure body is already on the MainActor. `bridge.send(_:)` is `async throws`. Wrapping in `Task { @MainActor in ... }` is a detached hop — functionally equivalent (still lands on MainActor) but introduces ordering non-determinism: two rapid-fire state transitions can reorder on the MainActor job queue, and the `try?` masks every error (including `BusError.bridgeNotReady` and any `callAsyncJavaScript` throw). A failed send never surfaces to ops.

**Fix:** keep the Task hop (it's required because `send` is async and `emit` is sync), but log the error:
```swift
Task { @MainActor [weak bridge] in
    guard let bridge else { return }
    do {
        try await bridge.send(.hudState(busHudState(from: appState)))
    } catch {
        // `systemLogger` is nonisolated-captured via self; use the delegate ref.
        // Or: inject a logger closure into the coordinator's emit to keep it Bus-agnostic.
    }
}
```
A cleaner alternative: give `HudStateCoordinator` an `emit: @MainActor (HudState) async throws -> Void` signature and let the coordinator await + log internally (coordinator already has access to its own `Logger` via the emit boundary).

#### M-02: `HudStateCoordinator.start()` subscriber Tasks redundantly `await MainActor.run { ... }` from within `Task { @MainActor in ... }`

**File:** `App/HUD/HudStateCoordinator.swift:67-96`
**Issue:** `start()` is `@MainActor`-isolated, so the `Task { [weak self] in for await ... }` inherits MainActor executor by default. Each arm then does `await MainActor.run { ... }` for every intent — a redundant hop that adds a job queue roundtrip per intent and complicates reasoning about ordering. For high-frequency intents (voice `.listening` with audio-level coming in Phase 6) this is measurable latency and a real concern for the 60 FPS budget.

Confirm by checking that `for await intent in agent` is indeed on MainActor (Swift 6 task inheritance rule — a Task created in a @MainActor context inherits the isolation). Current tests pass because the `MainActor.run { ... }` is redundantly correct, not because the surrounding context is off-actor.

**Fix:**
```swift
agentTask = Task { @MainActor [weak self] in
    for await intent in agent {
        guard let self else { return }
        self.lastAgent = intent
        self.resolveAndEmit()
    }
}
```
Dropping `MainActor.run` shortens the await path and eliminates one scheduled job per intent. Same pattern for voice and confirm.

#### M-03: `resetStore()` helpers in `ChatPanel.test.tsx` + `store.test.ts` don't reset `currentTurnId` / `activeTextPartId` — tests silently inherit stale turn state from prior tests

**File:** `webview/packages/hud/tests/ChatPanel.test.tsx:10-17`, `webview/packages/hud/tests/store.test.ts:7-14`
**Issue:** The store grew `currentTurnId` and `activeTextPartId` slices in Plan 03-04, but these two `resetStore()` helpers still spread only the Plan 03-02 set. Zustand's `setState` is a shallow merge, so the new slices inherit whatever the previous test in the file left behind. All current tests pass because they don't read these slices, but the tests are now fragile — a new test that happens to check `currentTurnId === null` could get `'t1'` from a prior fixture if the order shifts.

The Plan 03-04 SUMMARY explicitly documented this ("resetStore helpers in bus-dispatch.test.ts were NOT updated to include the new currentTurnId/activeTextPartId slices, because Zustand's setState shallow-merges — the existing 03-02 tests remain green"), but knowingly leaving a trap is still a trap.

**Fix:** add both slices to every `resetStore()` helper:
```ts
function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    currentTurnId: null,
    activeTextPartId: null,
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}
```
`streaming.test.tsx` and `chronology.test.tsx` already do this correctly — use those as the template.

#### M-04: `bus/client.ts` bypasses store actions by calling `useJarvisStore.setState({ activeTextPartId: ... })` directly

**File:** `webview/packages/hud/src/bus/client.ts:89, 106, 126`
**Issue:** The store was built with an action-dispatch pattern (`beginTurn`, `endTurn`, `upsertToolCall`, `appendTokenToLastText`), but three dispatcher arms reach in and mutate `activeTextPartId` via `useJarvisStore.setState(...)` directly. This works because Zustand allows it, but it breaks the single-writer abstraction — future debugging (where does `activeTextPartId` change?) has to grep both action bodies AND dispatcher call sites.

**Fix:** add a `setActiveTextPartId(id: string | null)` action (or bundle it into `upsertToolCall`'s semantics so the action itself nulls `activeTextPartId` when a tool-call lands). Trivial edit; centralizes the Ch1 chronology rule in one place.

#### M-05: `AppDelegate.installBus()` missing-bundle path has three near-identical hard-block patterns

**File:** `App/AppDelegate.swift:379-388` and two other sites
**Issue:** If `index.html` is missing from the bundle, the code shows an NSAlert hard-block modal then calls `NSApp.terminate(nil)`. The same pattern (critical log + `TCCAlertService.presentHardBlock` + `NSApp.terminate(nil)`) appears three times in this file (config malformed, config load failed, bundle missing). Not a correctness bug — the NSAlert.runModal is synchronous so ordering holds — but the duplication invites drift.

**Fix:** factor a `private func hardBlockAndTerminate(title:body:)` helper. Not load-bearing.

#### M-06: `scripts/build-webview.sh` doesn't restore `pwd` after `cd "$REPO_ROOT/webview"` — benign for Xcode's subshell-per-phase runner, hostile for future `source`-style callers

**File:** `scripts/build-webview.sh:41`
**Issue:** `set -euo pipefail` is correct. `cd "$REPO_ROOT/webview"` changes the working dir; the script never restores it. Xcode pre-build scripts run in isolated subshells so this is benign for Xcode. But if someone ever invokes this via `source ./scripts/build-webview.sh` for faster iteration, the caller's cwd drifts. The pnpm commands all run from the webview dir (correct); the rsync uses absolute paths so correctness is unaffected.

**Fix (optional):** `pushd "$REPO_ROOT/webview" > /dev/null; ...; popd > /dev/null` or use a subshell `(cd "$REPO_ROOT/webview" && pnpm ...)`. Not urgent.

---

### Low (nice to have)

#### L-01: `HudStateCoordinator.deinit` cancels Tasks that already use `[weak self]` + explicit `cancelAll()` — triple-covered

**File:** `App/HUD/HudStateCoordinator.swift:45-49`
**Issue:** The deinit cancellation is correct and defensive, but combined with the `[weak self]` pattern and `cancelAll()`, there's triple-coverage for the same invariant. Harmless; just noting.

#### L-02: `webviewEntryFilename: String = "index"` is mutable but only ever written to the same constant inside `installBus()`

**File:** `App/AppDelegate.swift:102, 363`
**Issue:** The property is declared as a `var` to let tests write `"UNSET"` before `installBus()`. Then `installBus()` unconditionally writes `"index"` back. If a future test wants to assert the bundle-lookup path for a different filename, they'd have to modify the code. Minor — the test seam works.

#### L-03: `ring.vert.glsl` uses `gl_PointSize = 4.0 * (300.0 / -mvPosition.z)` with no guard against `mvPosition.z == 0`

**File:** `webview/packages/hud/src/hud/ring.vert.glsl:27`
**Issue:** With the current camera at `[0,0,3]` and ring at `z=0`, `mvPosition.z = -3` always, so `-mvPosition.z = 3` and division is safe. If a future tweak moves the ring closer to `z=3` or adds a CameraControls helper that lets the ring intersect the camera plane, division by zero produces `NaN` which propagates to `gl_PointSize` and then to GPU rasterization — undefined behavior per WebGL spec.

**Fix:** `gl_PointSize = 4.0 * (300.0 / max(-mvPosition.z, 0.001));` — cheap clamp.

#### L-04: `uTime` accumulates via `matRef.current.uTime += delta` indefinitely — after ~8 hours of runtime, Float32 precision loss causes visible shader artifacts

**File:** `webview/packages/hud/src/hud/RingMesh.tsx:98`
**Issue:** `uTime` starts at 0 and grows by `delta` (typically 0.016) each frame. At ~60 FPS, in 8 hours `uTime ≈ 28800`. `sin(uTime * uPulseSpeed * 2π)` at `uPulseSpeed = 3.0` (listening) is `sin(542867.4)` — still correct on CPU but Float32 mantissa loss on the GPU makes the sine value snap to a small discrete set. User-visible: listening pulse becomes jittery after a long idle session. Jarvis is pitched as an always-on HUD, so this is a real runtime concern, not theoretical.

**Fix:** wrap uTime modulo a large period:
```ts
matRef.current.uTime = (matRef.current.uTime + delta) % 1000.0
```
Works because every shader math path is periodic (sin at integer-multiple periods aligns). Or subtract `Math.floor(uTime)` for the sine path. Document the chosen period.

#### L-05: `ToolCallCard` renders `event.args` as `JSON.stringify(event.args, null, 2)` — if args is a raw string (non-JSON argsPreview), this wraps it in quotes

**File:** `webview/packages/hud/src/chat/ToolCallCard.tsx:65`
**Issue:** `parseArgs()` in `bus/client.ts` returns the raw string when JSON.parse fails. Then `JSON.stringify("foo", null, 2)` renders `"foo"` (with surrounding quotes). Looks off for plain-text args. Not a bug (and not exploitable — React still escapes), just ugly.

**Fix:** branch on `typeof args === 'string'`:
```tsx
{hideArgs
  ? '(hidden until you approve)'
  : typeof event.args === 'string'
  ? event.args
  : JSON.stringify(event.args, null, 2)}
```

#### L-06: `App/Resources/webview/index.html` commits hashed asset paths while `assets/` is gitignored — fresh clone + no pre-build = blank HUD

**File:** `App/Resources/webview/index.html`
**Issue:** Commit history will show `index.html` bumping on every dep upgrade (new hash → new src attr). That's expected per Plan 03-05's decision ("committed index.html, gitignored assets/"). Not a bug — but the first time a fresh checkout runs without `build-webview.sh`, the committed index.html points at hashed assets that don't exist on disk. The pre-build script fixes it, but a dev opening the app without running the pre-build first sees a blank HUD. Worth a one-line README note.

**Fix:** add a check at the top of `smoke-test-hud.sh` or `scripts/dev.sh` that greps the committed `index.html` src attr, greps for the same hash in `App/Resources/webview/assets/`, and warns if missing. Or simpler: don't commit the hash in `index.html` — have the pre-build script inject it. That's more invasive.

#### L-07: `tsconfig.json` `lib: ["ES2022", "DOM", "DOM.Iterable"]` — over-broad but not wrong

**File:** `webview/packages/hud/tsconfig.json:7`
**Issue:** Low-priority; suggests a cargo-culted lib setting. Not wrong (ES2022 is a superset of what's in use), just over-broad. Vite 8 / Node 20 target should probably be ES2023 now, but this doesn't cause a bug.

---

### Info / Observations

#### I-01: The single-writer lint is real and bites — I verified the grep filter against the current tree

**File:** `scripts/check-single-writer-hudstate.sh`
**Note:** 6-file allowlist, exits 0 today. Adding a fake `BusOutbound.hudState(.idle)` line to a fresh file in `App/MenuBar/` would make the lint fire — the grep filter chain correctly excludes only the allowlisted paths and comment lines. Good.

#### I-02: XSS review is clean

**Note:** No unsafe HTML-injection escape hatches anywhere in the webview package. Every chat-event render path is JSX text interpolation, which React escapes. `TextPart` uses `{event.text}`, `ErrorPart` uses `{event.message}`, `ToolCallCard` uses `{event.name}`, `{JSON.stringify(...)}`, `{event.result}`, `{event.error}` — all React text. `chat-panel.css` has no `content: attr(...)` tricks. The CSP meta (`script-src 'self'; object-src 'none'; frame-ancestors 'none'; connect-src 'none'`) is correctly restrictive; `'unsafe-inline'` on `style-src` is the unavoidable Vite/React inline-style floor. No XSS surface in the diff.

#### I-03: Shell injection review is clean

**Note:** All three scripts (`build-webview.sh`, `check-single-writer-hudstate.sh`, `smoke-test-hud.sh`) quote every variable expansion (`"$REPO_ROOT"`, `"$STAMP_FILE"`, `"$BUILT_APP"`, etc.). `set -euo pipefail` is on every script. No `eval`, no user-controlled input (all paths are computed from `BASH_SOURCE[0]` or `$HOME` or `find | head -1`). The `grep -rn '\.hudState(' App/ packages/ --include='*.swift'` in the single-writer lint is a fixed pattern, not user-derived. Clean.

#### I-04: Pitfall-1 guard is correctly observed

**Note:** `RingMesh.tsx` uses `useJarvisStore.getState()` inside `useFrame` — not the subscribing hook. Grep confirms: `grep -c 'useJarvisStore.getState()'` returns 2 (hudState + theme read). `LoadingFallbacks.tsx` DOES use the hook — but that's the low-frequency render path as documented, not the 60 Hz loop. Correctly split.

---

## By-File Annotations

### Swift (native host)

- `App/AppDelegate.swift` — minor findings M-01 (Task double-hop + swallowed errors), M-05 (hardBlock helper); core wiring is correct
- `App/HUD/HudStateBridge.swift` — clean; `assertionFailure` + `.idle` Release fallback is the right pattern
- `App/HUD/HudStateCoordinator.swift` — minor finding M-02 (redundant `MainActor.run` hops); L-01 (triple-covered cancellation). Core state machine is correct.
- `App/HUD/HudStateIntent.swift` — clean; three Sendable Equatable enums, no surprises
- `App/MenuBar/MenuBarIconController.swift` — clean; the 5→7 switch extension correctly handles `.booting` + `.reconfiguring` as no-animation arms with a TODO pointing to Phase 3/4
- `App/Theme/HudState.swift` — clean; rawValues + voiceOverLabels match spec verbatim; preserves Phase 1 case order
- `App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift` — clean; FakeJSEvaluator mirrors Phase 2 pattern correctly
- `App/Tests/AppTests/HudStateCoordinatorTests.swift` — clean; 19 tests cover every precedence pair + idempotency + boot gate + weak-self; `drain()` helper is brittle-looking (8 yields) but empirically sufficient
- `App/Tests/AppTests/HudStateEnumTests.swift` — clean
- `App/Tests/AppTests/WebviewBundleLoadTests.swift` — clean; `#filePath` + 4× `deletingLastPathComponent()` to repo root is correct; `test_assetsDirectoryGitignored_documentedInSmokeScript` is documentation-only (noted in file)

### Shell / build infrastructure

- `scripts/build-webview.sh` — minor finding M-06 (pwd leak); lockfile-sha caching is correct; rsync excludes preserve the 02-04 parity invariant
- `scripts/check-single-writer-hudstate.sh` — clean; grep filter chain correctly allowlists 6 paths + comment lines
- `scripts/smoke-test-hud.sh` — clean; bundle-shape assertions match the invariants
- `project.yml` — clean; preBuildScripts ordering (parity → protocol-version → no-eval → single-writer → build-webview) is correct per Plan 03-05

### Webview (React + R3F + TS)

- `webview/packages/hud/package.json` — clean
- `webview/packages/hud/tsconfig.json` — L-07 (over-broad lib)
- `webview/packages/hud/vite.config.ts` — clean; `base: './'` is the Pitfall 3 mitigation
- `webview/packages/hud/vitest.config.ts` — clean; deliberately excluded from `tsc` include per Plan 03-02 DR #2
- `webview/packages/hud/index.html` — clean; CSP meta is tight
- `webview/packages/hud/src/App.tsx` — clean; three-child composition matches plan
- `webview/packages/hud/src/main.tsx` — **H-02** (world-isolation concern); otherwise `queueMicrotask` pattern is correct per Pitfall 7
- `webview/packages/hud/src/bus/client.ts` — **H-01** (sentinel fragility); M-04 (direct setState bypass)
- `webview/packages/hud/src/store/index.ts` — clean; Zustand 5 + subscribeWithSelector usage is textbook
- `webview/packages/hud/src/store/types.ts` — clean
- `webview/packages/hud/src/chat/ChatEventRouter.tsx` — clean; exhaustiveness sentinel is real
- `webview/packages/hud/src/chat/ChatPanel.tsx` — clean
- `webview/packages/hud/src/chat/ErrorPart.tsx` — clean; `role="alert"` is correct
- `webview/packages/hud/src/chat/TextPart.tsx` — clean; React text interpolation guarantees escaping
- `webview/packages/hud/src/chat/ToolCallCard.tsx` — L-05 (JSON.stringify on string args); defense-in-depth guard is correct
- `webview/packages/hud/src/chat/chat-panel.css` — clean
- `webview/packages/hud/src/hud/LoadingFallbacks.tsx` — clean
- `webview/packages/hud/src/hud/ParticleRing.tsx` — clean
- `webview/packages/hud/src/hud/RingMaterial.ts` — clean; drei factory + R3F 9 namespace augmentation done correctly
- `webview/packages/hud/src/hud/RingMesh.tsx` — L-04 (uTime monotonic drift)
- `webview/packages/hud/src/hud/loading-fallback.css` — clean; `@media (prefers-reduced-motion)` defense-in-depth present
- `webview/packages/hud/src/hud/ring.frag.glsl` — clean
- `webview/packages/hud/src/hud/ring.vert.glsl` — L-03 (gl_PointSize divide-by-zero risk)
- `webview/packages/hud/src/hud/stateUniforms.ts` — clean; `parseHex` has fallback for malformed input
- `webview/packages/hud/src/theme/tokens.css` — clean
- `webview/packages/hud/src/types/globals.d.ts` — clean
- `webview/packages/hud/tests/ChatPanel.test.tsx` — M-03 (incomplete resetStore)
- `webview/packages/hud/tests/RingMesh.test.tsx` — clean
- `webview/packages/hud/tests/ToolCallCard.test.tsx` — clean; T3 + T3b specifically prove the defense-in-depth guard
- `webview/packages/hud/tests/bus-dispatch.test.ts` — clean
- `webview/packages/hud/tests/chronology.test.tsx` — clean; Ch2 whitespace-normalization is the documented pattern
- `webview/packages/hud/tests/fixtures/streaming-fixture.json` — clean; 20 messages, canonical UUIDs
- `webview/packages/hud/tests/setup.ts` — clean; ResizeObserver polyfill is the documented Plan 03-02 DR #3
- `webview/packages/hud/tests/stateUniforms.test.ts` — clean
- `webview/packages/hud/tests/store.test.ts` — M-03 (incomplete resetStore)
- `webview/packages/hud/tests/streaming.test.tsx` — clean

### Bundle artifacts

- `App/Resources/webview/.gitignore` — clean; single `assets/` ignore with clear rationale comment
- `App/Resources/webview/index.html` — L-06 (hash-drift risk)

---

## Recommended Next Steps

**Recommended flow:** run `/gsd-code-review-fix 3` once to land the two HIGH findings and the cheapest MEDIUM wins, then `/gsd-verify-phase 3`.

Must-fix-before-verify:
1. **H-02 first.** Before anything else, do the 5-minute manual UAT: build Debug, open the app, summon HUD, tail `~/Library/Logs/Jarvis/system.log`. If `uiReady` doesn't arrive and/or `handshake armed` fires via the injection auto-ack but NOT via main.tsx's `onOutbound` path, the world-isolation defect is confirmed and Option B (don't overwrite `window.jarvisBus`) is the smallest fix. If UAT passes, downgrade to a doc-comment MEDIUM and proceed.
2. **H-01.** One-function change in `bus/client.ts` — replace literal string equality with `isApprovalPlaceholder(parseArgs(...))`; add one D-test with whitespace-varied sentinel.

Fix-when-convenient (defer to next phase if time-pressed):
3. **M-03.** Update `resetStore()` in two test files (mechanical).
4. **M-02.** Drop `MainActor.run` from three coordinator Task bodies; runtime win + cleaner.
5. **M-01.** Log the swallowed errors in the emit closure; Phase 4 will pay the debt otherwise.

Safe to defer to Phase 4+ or Phase 8 Hardening:
- All LOW findings (L-01..L-07)
- M-04 (direct setState) — Phase 4 will touch this path when it adds `chat/textStart`, natural time to refactor.
- M-05 (hardBlock helper) — cleanup, not correctness.
- M-06 (pwd leak) — environmental hygiene.

**Do NOT include in code-review-fix:**
- The Xcode 26 xctest-launch blocker (upstream, explicitly out of scope per project_context #9)
- Any Phase 2 bus schema changes (explicit out-of-scope per the reviewer brief)
- Main-chunk size (Phase 8 Hardening, explicit out-of-scope)

---

_Reviewed: 2026-04-24_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
