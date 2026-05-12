# Bus + HUD + WKWebView Bridge — End-to-End Audit

**Date:** 2026-05-12
**HEAD:** `a5999e2`
**Scope:** `packages/Bus/`, `webview/packages/bus/`, `webview/packages/hud/`, `App/HUD/`, `App/MenuBar/`, `App/AppDelegate.swift` bridge / handshake / inbound-outbound surfaces.
**Mode:** Read-only on production; written to this file only.
**Calibration:** Look for shape-of-today's-bug — probe says ok, reality is wired-but-dead. Surface "wants to write HudState but goes through a non-coordinator path", outbound cases with no producer, inbound cases with `// TODO` arms, dead-letter views.

---

## TL;DR — top-3 by severity

1. **`BridgeNavigationDelegate` has no failure arm.** Only `didFinish` is implemented. If `index.html`, the JS bundle, or any sub-resource fails to load (bad reference, 404 on `file://`, JS parse error before mount), the navigation never finishes, `startHandshake()` is never invoked, the 2-second handshake timeout **is never even armed**, and the user sees a silent black HUD with no banner, no hard-block. The "missing index.html" hard-block on AppDelegate.swift:2553 is the only failure mode that surfaces.
2. **`MenuBarIconController.transition(to:)` is production-dead.** The full CABasicAnimation surface (breath / rotate / shimmer / glow per state) ships and works in unit tests, but **no production code ever calls `transition(to:)`** — `HudStateCoordinator`'s emit closure fans HudState to the webview bridge only. The menu-bar icon never animates regardless of agent state. Only `applyHealth(_:)` (Round 4) is wired.
3. **`DevOverlay` is a hollow shell.** `DevOverlayWindow` opens with a default `DevOverlayViewModel` holding `DevSnapshot.initial`. The `.devOverlay` broadcaster subscription on AppDelegate.swift:1808-1813 drains events into `_` with the comment "reserved for the DevOverlay emitter wiring in a follow-on plan." `DevOverlayBridge` is never instantiated. Opening the overlay shows static initial values (state=idle, 0 tokens, empty turn id) forever.

---

## Severity-ordered findings

### S1 — `BridgeNavigationDelegate` only implements `didFinish` (silent black HUD on bundle failure)

**Files:** `App/AppDelegate.swift:2715-2723`, `packages/Bus/Sources/Bus/WebviewBridge.swift:269-288`, `packages/Bus/Sources/Bus/Handshake.swift:24-26`.

`BridgeNavigationDelegate` is a 9-line class with one method:

```swift
nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated { onDidFinish() }
}
```

It has no `webView(_:didFail:withError:)` and no `webView(_:didFailProvisionalNavigation:withError:)`. `WebviewBridge.startHandshake()` schedules the 2-second timeout (`HandshakeTiming.timeout = .seconds(2)`) **inside** `startHandshake`, which is only invoked from `didFinish`. So the failure mode chain is:

- `loadFileURL` succeeds (file exists on disk).
- `index.html` body loads OK, but `<script src="./assets/index-fBrUXkPQ.js">` 404s (stale ref, mid-build copy, codesign strip).
- WebKit fires `didFailProvisionalNavigation` (or no completion at all for a JS parse error post-DOMContentLoaded depending on phase).
- `didFinish` never fires.
- `startHandshake()` is never called.
- The 2s timeout is never scheduled.
- `handshakeState` remains `.idle` forever. No `.timedOut`. No banner. No hard-block alert.

Audit prior context noted "live host PID 18811's HandshakeState reaches `.armed` (BootHealth probe says yes)" — this is true when the bundle exists, but **the failure mode is silent on the host that *should* be showing a banner**. That is exactly the calibration bug shape — the probe (`handshakeState == .armed`) passes when reality is OK, and provides no signal when reality breaks at the *navigation* layer.

The 2s timeout in `Handshake.swift` advertises a 2s SLA. With no `didFailX` handler, the SLA is silently >∞ in the bundle-broken path.

**Fix sketch:** add `didFailProvisionalNavigation` + `didFail` to `BridgeNavigationDelegate`, route both into a new `WebviewBridge.failHandshake(reason:)` that transitions to `.timedOut` (or a new `.loadFailed`) and presents the same hard-block alert.

Tests: none currently cover the failure-arm path. `packages/Bus/Tests/BusTests/` has no `didFail*` references.

---

### S1 — `MenuBarIconController.transition(to:)` is production-dead

**Files:** `App/MenuBar/MenuBarIconController.swift:65-96`, `App/AppDelegate.swift` (all references).

The controller exposes a full per-state animation kit:

| State                    | Animation                       |
| ------------------------ | ------------------------------- |
| `.idle`                  | no animation                    |
| `.listening`             | `CAAnimationFactory.makeBreath()` |
| `.thinking`              | `CAAnimationFactory.makeRotate()` |
| `.speaking`              | `CAAnimationFactory.makeShimmer()` |
| `.awaitingConfirmation`  | `CAAnimationFactory.makeGlow()` |
| `.reconfiguring`/`.booting` | `// TODO(Phase 3/4)` — share `.idle` |

`transition(to:)` is exercised exhaustively by `MenuBarIconControllerTests`. In production: zero call sites.

```
$ grep -rn "menuBarController" App/ --include='*.swift' | grep -v Tests
App/AppDelegate.swift:106:    var menuBarController: MenuBarIconController?
App/AppDelegate.swift:768:        menuBarController?.applyHealth(snapshot.overallHealth)
App/AppDelegate.swift:1305:        if let menu = menuBarController?.contextMenu { ... }
App/AppDelegate.swift:2290:        if let menu = menuBarController?.contextMenu { ... }
App/AppDelegate.swift:2393:        menuBarController = controller
```

`HudStateCoordinator` is constructed with an emit closure that only fans to `WebviewBridge.send(.hudState(_:))` (`App/AppDelegate.swift:2475-2480`). The menu-bar icon is never told. The icon stays in its default static state for the entire app lifetime regardless of `.listening`/`.thinking`/`.speaking` activity.

This is exactly the "subsystem WANTS to change HUD state but goes through a non-coordinator path" anti-pattern named in the audit scope item §6 — except in reverse: the subsystem CAN'T see the state because the coordinator never broadcasts to it.

**Fix sketch:** subscribe `MenuBarIconController.transition(to:)` to the same broadcast the bus emit consumes. Either expand the emit closure on AppDelegate.swift:2475 to also call `menuBarController?.transition(to:)`, or have `HudStateCoordinator` expose a second fan-out (broadcast pattern). Note this is *not* a HUD-08 single-writer violation — `transition(to:)` writes the menu-bar icon's `currentState`, not `BusOutbound.hudState`. The single-writer invariant covers the bus surface, not arbitrary subscribers.

---

### S1 — DevOverlay never receives data

**Files:** `App/AppDelegate.swift:2652-2659` + `:1803-1813`, `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift`, `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift`, `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift`.

`toggleDevOverlay()` creates a `DevOverlayWindow()` with the default `DevOverlayViewModel`, which holds `DevSnapshot.initial` — a static struct with zeroes and an empty `turnId`. The window opens and renders that struct.

The broadcaster's `.devOverlay`-priority subscriber on `App/AppDelegate.swift:1808`:

```swift
let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
devOverlaySubscriberTask = Task {
    for await _ in devSub.stream {
        if Task.isCancelled { break }
    }
}
```

Drains every event to `_`. The comment (lines 1803-1807) is explicit:

> "DevOverlay subscriber (lossy — observational; reserved for the DevOverlay emitter wiring in a follow-on plan)."

So `DevOverlayBridge` (which exists in `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift` and is the intended consumer) is never instantiated, never given the `DevOverlayViewModel` reference, never given the broadcaster stream. `DevSnapshotEmitter.swift` exists in AgentCore but produces a snapshot stream that nobody attaches to the view model.

This is the exact "DevOverlay subsystem dump… silently shows stale data" pattern called out in the audit scope item §10.

Audit-2026-05-03 noted DevOverlay wasn't in scope; the May-12 round confirms it's still a flat-line view.

**Fix sketch:** instantiate `DevOverlayBridge` in `toggleDevOverlay()` (or earlier, at orchestrator install time), wire `DevSnapshotEmitter` → broadcaster → `DevOverlayBridge` → `viewModel.update(_:)`. Replace the no-op drain on line 1809-1813 with the bridge.

---

### S2 — `BusOutbound.sessionHistory(turns:)` is a dead-letter case

**Files:** `packages/Bus/Sources/Bus/Protocol.swift:14-17`, `packages/Bus/Sources/Bus/BusOutbound.swift:22-25`, `webview/packages/bus/src/protocol.ts:60`, `webview/packages/hud/src/bus/client.ts:153-157`.

Plan 07-03 bumped `BUS_PROTOCOL_VERSION` 2.0.0 → 2.1.0 specifically to add `sessionHistory(turns:)`. The TS mirror tracks it. Both sides decode it. The JS handler reads:

```ts
case 'sessionHistory':
  // Plan 07-06 added the case; AppDelegate.installMemory does not yet
  // hydrate (= WARN-INT-2). Until then we acknowledge but no-op so the
  // exhaustiveness sentinel below remains tight.
  break
```

The Swift side has zero production constructors of `.sessionHistory(turns: …)`. Verified by:

```
$ grep -rEn 'sessionHistory\(turns' App/ packages/ --include='*.swift'
(no output)
```

The version was bumped, the parser landed on both sides, the chat panel's hydration consumer is still a `break`. Both the producer and the consumer are explicitly marked "deferred." This is structurally fine, but it's the kind of "we landed the protocol bump for a feature that never shipped" debt the audit was looking for.

**Fix sketch:** either (a) actually wire `AppDelegate.installMemory` → `WebviewBridge.send(.sessionHistory(turns: lastN))` on webview-ready + chat-panel mount with a corresponding JS hydration arm, or (b) cut the case out and bump 2.3.0 → 3.0.0 (MAJOR — removed field). (a) is cheaper; (b) is honest. Given the chat panel currently *only* gets state via the in-flight token stream after a turn starts, hydration would actually be useful — the user sees an empty chat panel on every relaunch.

---

### S2 — `BusOutbound.audioLevel` produces but the consumer is a `break`

**Files:** `packages/Bus/Sources/Bus/OutboundBatcher.swift:82`, `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift`, `App/AppDelegate.swift:1282-1292`, `webview/packages/hud/src/bus/client.ts:135-138`, `webview/packages/hud/src/hud/*.tsx` (no consumers).

Track B-7 / P1-1 wired `AudioLevelEmitter` so the listening-state ring would pulse on real mic RMS. Production code constructs the emitter and routes through `OutboundBatcher`. Frames are emitted live. The JS handler:

```ts
case 'audioLevel':
  // Plan 03-03's ring shader uses a synthetic sine; Phase 6 binds this
  // to the real mic RMS. Intentional no-op for P3.
  break
```

No `audioLevel`-driven uniform in any of `RingMesh.tsx`, `ParticleRing.tsx`, `SegmentedRing.tsx`, `CoreGlow.tsx`, `Reticle.tsx` (independently verified via `grep audioLevel webview/packages/hud/src/hud/`). So:

- Swift instruments the mic correctly.
- The bus carries the frames at ~30 Hz.
- The JS handler decodes them.
- Nothing renders.

Same structural shape as `sessionHistory`: the audit-2026-05-03 prior-context audit already noted this in §2 "audioLevel is wired to nothing." It has not been touched since. The Swift production wire keeps spending CPU/IPC on a payload the renderer throws away.

**Fix sketch:** either (a) bind `audioLevel` to a `uAudioRMS` uniform on `RingMesh` so listening-state visibly reacts to voice input, or (b) stop emitting from `AudioLevelEmitter` until the consumer lands. (a) is the cheaper net-positive — `audioLevel` was the whole point of the listening-state ring per the prior audit.

---

### S2 — Documentation drift: `JarvisBusWorld` references throughout

**Files:** `packages/Bus/Sources/Bus/WebviewBridge.swift:10`, `packages/Bus/Sources/Bus/Resources/Injection.js:1`, `webview/packages/bus/src/bridge.ts:60-99,159`, `webview/packages/bus/dist/bridge.{js,d.ts}` (build artifact, stale), `webview/packages/bus/tests/bridge.test.ts:78-113`, `webview/packages/hud/src/main.tsx:9-15`, `App/AppDelegate.swift:484`.

Commit `fb41c5f` (2026-05-XX) unified the bridge on `WKContentWorld.page` — see the commit message:

> "Two related bugs blocking the HUD from advancing past BOOTING after handshake. Found via BootDiag instrumentation that proved Swift was correctly emitting .idle but the JS handler was never receiving it ... Fix: WebviewBridge defaults to WKContentWorld.page so Injection.js, the page bundle, and the script-message-handler all share one world."

The runtime is now correct (verified: `WebviewBridge.init` default is `contentWorld: WKContentWorld = .page`, line 86 + 106). But the codebase still describes the *prior* topology in 20+ docstrings and one variable comment in production source:

- `WebviewBridge.swift:10`: "Install a `WKScriptMessageHandlerWithReply` in an isolated content world (`JarvisBusWorld`) so page scripts cannot observe or post to it." — **No longer true.** Page scripts *can* observe (they share the world).
- `Injection.js:1`: "Injected at document-start in WKContentWorld('JarvisBusWorld')." — wrong.
- `bridge.ts:60-99` "WKContentWorld attach-to-existing path (H-02)" — the whole rationale is now obsolete; both stubs run in the same world. The duck-type `isJarvisBusShape` check is still load-bearing (it prevents the bundle's `installJarvisBus` from clobbering Injection.js's stub), but the *reason* documented is no longer the actual reason.
- `main.tsx:9-15`: comments still describing the cross-world attach path.
- `AppDelegate.swift:484`: same drift.

This is not a runtime bug — gate `check-no-evaluate-javascript.sh` passes, `check-bus-protocol-version.sh` passes, all bus tests pass. It IS exactly the kind of stale-doc trap that produces the next outage: a future agent reads `bridge.ts:60` and "fixes" the duck-type-guard branch because the rationale no longer applies, deleting the stub-protection check.

The dist artifact at `webview/packages/bus/dist/bridge.js` (which has the same stale comments) is shipped to consumers via `pnpm`. Whether anyone runs `tsc` against the `dist/` doc-comments is unclear.

**Fix sketch:** rename "JarvisBusWorld" → "page" / "shared world" in all comments. Rewrite the `bridge.ts:60-99` rationale to reflect that the duck-type guard is now defensive against double-install (Injection.js + bundle in the same world, both running `installJarvisBus`-like logic), not cross-world attach. Bump the bus package patch version.

---

### S3 — Stale build artifacts in `App/Resources/webview/assets/`

**File:** `App/Resources/webview/assets/`.

Audit-2026-05-03 noted 9 stale bundles totaling ~9.9 MB. Today: still 8 stale bundles (`index-BKfT8cyH.js` through `index-PXUzusnJ.js`) plus their `.map` files, with the active `index-fBrUXkPQ.js` referenced by `index.html`. Same pattern, ~6 weeks later. No clean step has been added to whatever copies `dist/` → `App/Resources/webview/`.

Not a runtime bug, just bundle bloat (each bundle is ~1.1 MB; with `.map`s the total is ~50+ MB of dead weight in the app's `.app` bundle).

**Fix sketch:** add `rm -rf App/Resources/webview/assets/*` before the `cp -R` in whatever build script copies the dist. Or have `scripts/build-webview.sh` own the cleanup.

---

### S3 — `WebviewBridge.sendRaw` propagates JSON-throwing through the public API

**File:** `packages/Bus/Sources/Bus/WebviewBridge.swift:180-194`.

```swift
public func sendRaw(_ message: BusOutbound) async throws {
    let data = try encoder.encode(message)
    let json = String(decoding: data, as: UTF8.self)
    _ = try await evaluator.callAsync(...)
}
```

`encoder.encode(.audioLevel(rms: .nan))` will succeed (`Float.nan` encodes as `null`), but `decodeOutbound` JS-side will reject (`typeof parsed.rms !== "number"` is true for `null` since `typeof null === "object"`). Result: per-frame decode error in `onDecodeError` for every audio frame containing a `NaN`. Since `audioLevel` is currently a no-op consumer, this never manifests. But the day someone wires it through, it will surface as console-spammed decode errors at 30 Hz if the AudioLevelEmitter ever emits NaN.

**Fix sketch:** clamp `rms` to `0.0...1.0` in `AudioLevelEmitter`, or have `BusOutbound.audioLevel.encode` substitute `0.0` for non-finite floats.

Mark this S3 because the consumer is dead; it'll become S1 the moment §S2-audioLevel above is fixed.

---

## Verified healthy

These were checked and found to work as documented:

- **Handshake protocol.** Swift → JS hello → JS helloAck → `HandshakeState.armed`. Confirmed in `WebviewBridge.handleHelloAck` and `Injection.js`'s "hello is owned by the stub" auto-ack. Mismatch path correctly hard-blocks via `TCCAlertService.presentHardBlock`. Timeout (2s) is correctly armed by `startHandshake` (but see S1-§1: only after `didFinish`).
- **`WKContentWorld` isolation.** Confirmed `.page` is the runtime default; `check-no-evaluate-javascript.sh` passes; `WebviewBridge.sendRaw` routes only through `callAsyncJavaScript` with primitive-string arguments (no JSON-into-body interpolation). No production calls to `evaluateJavaScript`.
- **Bus protocol version (`2.3.0`).** `check-bus-protocol-version.sh` passes — Swift, TS, and Injection.js stub all agree. Fixture directories byte-identical between `packages/Bus/Tests/BusTests/Fixtures/` and `webview/packages/bus/fixtures/`. `check-bus-harness-parity.sh` passes — canonical `webview/bus-harness.html` matches bundled copy.
- **Inbound bus events.** All 5 `BusInbound` cases (`helloAck`, `uiReady`, `frameAttachRequested`, `chatSubmit`, `chatCancelAndSubmit`) have real handlers in `AppDelegate.onInbound` (lines 2513-2530). `frameAttachRequested` → `frameAttachController.requestAttach(reason: .hudButton)`. `chatSubmit` → `handleChatSubmit`. `chatCancelAndSubmit` → `handleChatCancelAndSubmit`. No `case foo: break // TODO` arms. The `helloAck` + `uiReady` arm returns `nil` but those are no-op-by-design (helloAck is intercepted inline by `WebviewBridge.handleInboundString`).
- **Outbound bus events with real production senders.**
  - `.hello` — `WebviewBridge.startHandshake` (line 154).
  - `.hudState` — `HudStateCoordinator` via emit closure (only writer per HUD-08).
  - `.tokenDelta` — `OutboundBatcher` driven by `BusForwarder` (`packages/AgentCore/Sources/AgentOrchestrator/BusForwarder.swift:72`) + `AgentOrchestrator.swift:550`.
  - `.toolCallStart` / `.toolCallEnd` — `MCPBusGatewayAdapter` (`App/MCPBusGatewayAdapter.swift:56,65,71`).
  - `.turnStarted` / `.turnEnded` — `AppBusForwarderSink` (`App/AppBusForwarderSink.swift:26,31`).
  - `.submitRejected` — `AppDelegate.handleTextOutcome` (`:2197`) + `AppBusForwarderSink:36`.
  - `.audioLevel` — `OutboundBatcher.drainBuffers` (`packages/Bus/Sources/Bus/OutboundBatcher.swift:82`) driven by `AudioLevelEmitter`. **Producer works; consumer is dead (see S2 above).**
  - `.sessionHistory` — **no producer (see S2 above).**
- **`HudStateCoordinator` single-writer.** `check-single-writer-hudstate.sh` passes. `BusOutbound.hudState(_:)` is only constructed at AppDelegate.swift:2478 inside the coordinator's emit closure. No other constructor sites in production. The coordinator's 3-stream input (agent/voice/confirmation) precedence is correctly enforced via `resolved` + `emit` (lines 102, 179).
- **Banner coordinator non-dismissible flag (Round 4).** `bootHealthCritical` enqueues with `nonDismissible: true` (priority 1); `HUDBannerCoordinator.dismissCurrent` correctly no-ops on `current?.nonDismissible == true` (line 69). Production wire on AppDelegate.swift:937: `bannerCoordinator?.enqueue(.bootHealthCritical(...))` fires when a critical health probe reports failure. Verified — would surface a non-dismissible banner if a critical subsystem (memory off, no API key, no MCP tools, webview never armed) failed today.
- **`MenuBarIconController.applyHealth`** (Round 4 Slice 4). Live wire at AppDelegate.swift:768 from `subsystemHealthMonitor` snapshot. `contentTintColor = .systemRed` for `.loud`/`.critical`; clear for `.ok`/`.soft`. Correctly does *not* write `HudState` (HUD-08 invariant preserved). Live host with 8/8 ok health correctly sees a system-tinted icon.
- **Chat panel rendering.** `App.tsx` mounts `ParticleRing`, `LoadingFallbacks`, `HudFrame`, `ChatPanel`, `ChatInput`. Tool-call card rendering wired in `bus/client.ts:95-134` (start/end → `store.upsertToolCall`). Frame-attach button: `CameraButton.tsx` posts `frameAttachRequested` inbound on click. Approval sentinel (`isApprovalPlaceholder`) correctly drives the "awaiting-approval" status label. Auto-scroll skipped per M-7 carry-forward.
- **Bus tests.** `swift test --package-path packages/Bus` and `vitest` for the bus package exercise the round-trip path. Fixtures parity is enforced at build time.

---

## Open questions

1. **Should `sessionHistory` actually ship?** The case is dead on both sides. If the chat-panel hydration was deliberately deferred to a phase that hasn't started, it's wasting a protocol-version bump. Either commit Plan 07-06's emit + JS hydration arm, or roll the case back and bump to 3.0.0. Cheapest fix: emit on webview-ready with the most-recent ~20 turns and have the JS arm replay them into the chat store, then strip the `break`.
2. **Should `audioLevel` actually drive the ring?** Prior audit flagged this 9 days ago and recommended `uAudioRMS` uniform. Still a no-op. Producer is wasting wire frames. Either bind a uniform or stop emitting from `AudioLevelEmitter`. The producer path is fully live including `AudioGraphOwner.subscribe()` (failed-subscription degradation logged at AppDelegate.swift:1291), so the cost of leaving it on is real (~30 Hz IPC + decode + handler call).
3. **Should the menu-bar icon animate?** `transition(to:)` and its CABasicAnimation surface compile, ship, and unit-test. The decision to remove it from the production wire (or never to add it) isn't documented in a `Plan` or `DECISION.md` I could find. If the user-facing intent is "the icon should breathe/rotate/shimmer per state," wire the coordinator emit. If the intent is "icon is static, ring is dynamic," delete `transition(to:)` entirely and its tests — keep `applyHealth` as the only public mutator.
4. **`BridgeNavigationDelegate.didFail*`.** Was this an oversight or an explicit decision that `loadFileURL` from `Bundle.main` "can't fail in practice"? In practice the JS bundle reference inside `index.html` can drift (and has, mid-build), and a missing/stale `assets/index-XXX.js` would never surface to the user. Either argue the case (and document) or add the failure arm.

---

## Patterns checked but not found

- TS handler with `// TODO: implement` in landed code — only `audioLevel` and `sessionHistory` no-ops, both with explicit "deferred to Phase X" comments (so they're known dead-letters, not silent TODOs).
- Swift `case .foo: break // TODO` for inbound dispatch — none. All 5 inbound cases have real arms.
- `WKScriptMessageHandler` that registers but never decodes payloads — none. `WebviewBridge.handleInboundString` decodes via `JSONDecoder` and ships every case to `onInbound`.
- Outbound bus event with a comment "emitted by X" where X never emits — found three (`audioLevel`, `sessionHistory`, transitively `MenuBarIconController.transition`).
- Stale `BusOutbound` cases referencing removed features — none. All cases reference live features; `sessionHistory` and `audioLevel` reference features whose *consumers* are dead.
- HudStateCoordinator transition that takes effect but the shader reads a different uniform — covered by audit-2026-05-03 for the `idle` zero-motion bug (out of scope here per "Track A landed animated rings"). Verified `stateUniforms.ts:30` no longer hard-codes `pulse: 0.0` — needs cross-check against the running bundle but appears resolved by Track A.

---

## Methodology

- Ran the four scope-relevant gate scripts: `check-bus-protocol-version.sh`, `check-bus-harness-parity.sh`, `check-no-evaluate-javascript.sh`, `check-single-writer-hudstate.sh`. All pass.
- Read all of `packages/Bus/Sources/Bus/`, `webview/packages/bus/src/`, `webview/packages/hud/src/bus/`, `webview/packages/hud/src/App.tsx`, `webview/packages/hud/src/main.tsx`, `App/HUD/`, `App/MenuBar/MenuBarIconController.swift`, and the bridge / handshake / installBus / onInbound / inbound / outbound regions of `App/AppDelegate.swift`.
- For each `BusOutbound` case, grepped for production constructors (excluding `Tests/`, `BusOutbound.swift`, `Protocol.swift`).
- For each `BusInbound` case, traced the arm in `bridge.onInbound`.
- Cross-checked Injection.js's `protocolVersion` literal against `BUS_PROTOCOL_VERSION` in Protocol.swift + protocol.ts. Three-way parity OK.
- Did not run live tests against PID 18811 (host is not currently running per `ps`).
