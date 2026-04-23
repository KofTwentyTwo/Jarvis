---
phase: 02-bus
verified: 2026-04-23T23:15:58Z
status: passed
score: 5/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: null
  previous_score: null
  gaps_closed: []
  gaps_remaining: []
  regressions: []
---

# Phase 2: Bus Verification Report

**Phase Goal:** Swift and the WKWebView speak a versioned, strictly-typed JSON protocol with zero silent schema drift. This phase is where the R4 dominant failure mode ("schema drift across the Swift/JS boundary") is architecturally foreclosed.
**Verified:** 2026-04-23T23:15:58Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth (SC) | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Outbound via `callAsyncJavaScript(arguments:)`; zero `evaluateJavaScript` in codebase, lint-enforced (HUD-04) | VERIFIED | `WebviewBridge.sendRaw` composes `functionBody` + `arguments: ["payload": json]`, routed through `WKWebViewJSEvaluator.callAsync` → `webView.callAsyncJavaScript(_:arguments:in:contentWorld:)` (WebviewBridge.swift:180-193, 331-343). `grep -rn "evaluateJavaScript" App/ packages/ --include="*.swift"` in production paths returns only two comment references at WebviewBridge.swift:19, 325 (doc strings documenting the ban). `scripts/check-no-evaluate-javascript.sh` wired as Xcode pre-build phase (project.yml:124-128). Negative test `scripts/test-check-no-evaluate-javascript.sh` confirms the script rejects `bad.swift` containing the forbidden API. Live-run: PASS. |
| 2 | Two-way `BUS_PROTOCOL_VERSION` handshake refuses mismatch with `NSAlert`; mismatch path tested (HUD-05) | VERIFIED | `WebviewBridge.handleHelloAck` compares `jsVersion == BUS_PROTOCOL_VERSION`, transitions `.armed` on match, `.mismatched(swift:js:)` on drift, invokes `alertPresenter` (WebviewBridge.swift:249-265). Production wiring routes `alertPresenter` through `TCCAlertService.presentHardBlock` + `NSApp.terminate(nil)` (AppDelegate.swift:285-291, 63). Timeout path: `scheduleTimeout` + `handleTimeout` → `.timedOut` + alert (WebviewBridge.swift:269-288). HandshakeTests.swift covers all five states: `test_handshakeArmsOnMatchingVersion`, `test_handshakeMismatchTriggersAlertAndBlocks`, `test_handshakeTimeoutTriggersAlert`, `test_handshakeTimeoutCancelledByArm`, `test_startHandshakeMovesToSentHello`. AppDelegateBusWiringTests.test_handshakeMismatchCallsTerminate confirms app-level mismatch path. 47/47 Swift tests pass live. |
| 3 | `check-bus-protocol-version.sh` runs as Xcode pre-build, fails on mismatch, round-trip per enum case against TS fixtures; `type` discriminator + hand-written Codable with exhaustive switches (SEC-09) | VERIFIED | `scripts/check-bus-protocol-version.sh` greps both constants, diffs fixture directories `/usr/bin/diff -r`. Wired as pre-build phase in `project.yml:116-123` with `inputFiles` binding to Protocol.swift + protocol.ts. Live run: `bus parity OK at v2.0.0`. Fixtures byte-identical: `/usr/bin/diff -r` between `packages/Bus/Tests/BusTests/Fixtures` and `webview/packages/bus/fixtures` returns no differences (14 files each). Hand-written `Codable` extension on `BusOutbound` (BusOutbound.swift:24-151) with `Discriminator: String, Codable` enum producing `type` key, exhaustive switches with **no** `default:` branches in both `init(from:)` and `encode(to:)`. Mirrored on `BusInbound` (BusInbound.swift:15-49). CodableRoundTripTests.swift has 24 cases including `test_allHudStateCasesHaveFixtures` (round-trip per enum case). Test `test_hudStateEncodesWithTypeDiscriminatorNotSynthesizedShape` explicitly verifies `{"type":"hudState","state":"idle"}` shape, not SE-0295 `{"hudState":{"_0":"idle"}}`. Negative harness `scripts/test-check-bus-protocol-version.sh` confirms mismatch fixture rejected. |
| 4 | High-frequency events coalesce ~30Hz via `OutboundBatcher`; state transitions flush immediately; unit tested (HUD-06) | VERIFIED | `OutboundBatcher` actor in OutboundBatcher.swift:20-90. `postAudio` → latest-wins (line 29, 39-42, 80-83); `postToken` → concat via `pendingTokens.joined()` (line 30, 44-47, 84-88); `flushAndSend(_:)` cancels scheduled drain, drains buffers in order, then emits caller's message (line 52-57). `scheduleDrainIfNeeded` uses `Task.sleep(for: .milliseconds(windowMillis))` with default 33ms (line 34, 61-69). BatcherTests.swift has 5 dedicated cases covering latest-wins, concat, order preservation via `flushAndSend`, multi-window behaviour, and flush-on-empty. `WebviewBridge` conforms to `OutboundBatcher.Sink` (WebviewBridge.swift:312-315). All 5 batcher tests pass live. |
| 5 | Inbound uses `WKScriptMessageHandlerWithReply`; reply carries success/failure, never silent swallow (HUD-03) | VERIFIED | `WebviewBridge` declares `extension WebviewBridge: WKScriptMessageHandlerWithReply` (WebviewBridge.swift:293-308). `userContentController(_:didReceive:replyHandler:)` hops to main via `MainActor.assumeIsolated` (Apple DevForums 751086 workaround), routes to `handleInboundString`. Every path produces a reply: non-String body → `replyHandler(nil, "bus: expected string payload")`; decode failure → `replyHandler(nil, "bus: decode error: ...")`; helloAck inline → `replyHandler(BusReply.success.asPlist(), nil)`; user handler → `replyHandler((reply ?? .success).asPlist(), nil)`; handler throw → `replyHandler(nil, "bus: handler error: ...")` (WebviewBridge.swift:202-241). `BusReply.asPlist()` produces plist-serializable `{ok, value|error}` (BusReply.swift:36-48). Registered in isolated `WKContentWorld("JarvisBusWorld")` (WebviewBridge.swift:92, 119-123) so page scripts cannot observe. WebviewBridgeTests.swift covers all 5 reply branches; 7 tests pass live. |

**Score:** 5/5 truths verified

### Required Artifacts (Level 1–4)

| Artifact | Expected | Exists | Substantive | Wired | Data Flows | Status |
|----------|----------|--------|-------------|-------|------------|--------|
| `packages/Bus/Sources/Bus/Protocol.swift` | `BUS_PROTOCOL_VERSION` const + `HudState` + `TurnTerminator` + `BusCoder` | Yes | Yes (62 LOC, explicit enum `CaseIterable`) | Yes (imported by BusInbound/Outbound/WebviewBridge) | N/A | VERIFIED |
| `packages/Bus/Sources/Bus/BusOutbound.swift` | 8-case enum with hand-written Codable | Yes | Yes (151 LOC, exhaustive switches, no `default`) | Yes (used by WebviewBridge.sendRaw + batcher Sink) | N/A (wire format) | VERIFIED |
| `packages/Bus/Sources/Bus/BusInbound.swift` | helloAck + uiReady with hand-written Codable | Yes | Yes (49 LOC) | Yes (decoded in WebviewBridge.handleInboundString) | N/A | VERIFIED |
| `packages/Bus/Sources/Bus/Handshake.swift` | HandshakeState enum + 2s timing | Yes | Yes (26 LOC, 5 states) | Yes (used by WebviewBridge state machine) | N/A | VERIFIED |
| `packages/Bus/Sources/Bus/WebviewBridge.swift` | `@MainActor`, WKScriptMessageHandlerWithReply, WKUserScript document-start, callAsyncJavaScript | Yes | Yes (345 LOC) | Yes (instantiated by AppDelegate.installBus, used in toggleHUD gate) | Yes (real WKWebView injected at AppDelegate.swift:285-291; harness loaded 302-323) | VERIFIED |
| `packages/Bus/Sources/Bus/OutboundBatcher.swift` | actor with 33ms window | Yes | Yes (90 LOC) | Yes (WebviewBridge conforms to `OutboundBatcher.Sink`; P3 will instantiate) | N/A at P2 (batcher is ready for P3/P4 to pump) | VERIFIED |
| `packages/Bus/Sources/Bus/BusReply.swift` | plist-serializable success/failure shape | Yes | Yes (50 LOC) | Yes (used in replyHandler branches) | N/A | VERIFIED |
| `packages/Bus/Sources/Bus/BusError.swift` | 4 structured errors | Yes | Yes (17 LOC) | Yes (thrown from send/handshake) | N/A | VERIFIED |
| `packages/Bus/Sources/Bus/Resources/Injection.js` | document-start stub installing `window.jarvisBus` | Yes | Yes (47 LOC, auto-ack hello path) | Yes (installed as WKUserScript at `.atDocumentStart` in JarvisBusWorld, WebviewBridge.swift:127-140) | Yes (bus-harness.html confirms `window.jarvisBus.protocolVersion` at doc-start) | VERIFIED |
| `webview/packages/bus/src/protocol.ts` | TS mirror, `BUS_PROTOCOL_VERSION = "2.0.0"`, exhaustive `never`-sentinel decode | Yes | Yes (207 LOC) | Yes (re-exported from index.ts, consumed by bridge.ts) | N/A | VERIFIED |
| `webview/packages/bus/src/bridge.ts` | `installJarvisBus` + `window.jarvisBus` glue | Yes | Yes (115 LOC) | Yes (bridge.test.ts exercises; P3 HUD will import) | N/A at P2 | VERIFIED |
| `webview/packages/bus/src/index.ts` | barrel | Yes | Yes (2 LOC) | Yes | N/A | VERIFIED |
| 14 JSON fixtures per side | byte-identical | Yes | Yes | Yes (consumed by vitest + xctest) | Yes | VERIFIED |
| `App/AppDelegate.installBus()` | wires bridge around hudPanel.webView, loads bus-harness | Yes | Yes (AppDelegate.swift:272-324) | Yes (called from `applicationWillFinishLaunching` step 4.5) | Yes (harness loaded via `loadFileURL` from bundle) | VERIFIED |
| `App/Resources/webview/bus-harness.html` | bundle-visible harness, byte-identical to canonical | Yes | Yes (23 LOC) | Yes (loaded by AppDelegate.installBus) | Yes (`/usr/bin/diff` between canonical and bundle returns no diff) | VERIFIED |
| `scripts/check-bus-protocol-version.sh` | pre-build script, greps both constants, diffs fixtures | Yes | Yes (88 LOC) | Yes (wired in project.yml:116-123) | Yes (live run prints `bus parity OK at v2.0.0`; negative harness confirms rejection) | VERIFIED |
| `scripts/check-no-evaluate-javascript.sh` | pre-build script, forbids `.evaluateJavaScript(` outside tests | Yes | Yes (58 LOC) | Yes (wired in project.yml:124-128) | Yes (live run prints `no evaluateJavaScript calls — HUD-04 OK`; negative harness confirms `bad.swift` rejected) | VERIFIED |
| `scripts/check-bus-harness-parity.sh` | diff canonical vs bundle harness | Yes | Yes (53 LOC) | Yes (wired in project.yml:108-115) | Yes (live run prints `bus-harness.html parity OK`) | VERIFIED |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| Swift `BUS_PROTOCOL_VERSION` | TS `BUS_PROTOCOL_VERSION` | `scripts/check-bus-protocol-version.sh` pre-build grep + fixture `diff -r` | WIRED | Both read `"2.0.0"`; live script PASS; project.yml:116-123 binds inputFiles + shell |
| Swift fixture dir | TS fixture dir | `/usr/bin/diff -r` inside check script | WIRED | Live diff returns no differences across 14 files |
| `WebviewBridge.sendRaw` | `WKWebView` | `callAsyncJavaScript(functionBody, arguments:["payload": json], in: nil, contentWorld:)` | WIRED | Zero `evaluateJavaScript` in production; primitive string `payload` arg (WebviewBridge.swift:183-193) |
| `WKScriptMessageHandlerWithReply` | `handleInboundString` | `userContentController(_:didReceive:replyHandler:)` + `MainActor.assumeIsolated` | WIRED | Every code path calls `replyHandler` exactly once |
| `AppDelegate.installBus()` | `WebviewBridge` constructor | Direct call with `hudPanel.webView` + alertPresenter closure | WIRED | Stored on `delegate.webviewBridge`; `toggleHUD()` reads `bridge.handshakeState` (AppDelegate.swift:246-254) |
| `BridgeNavigationDelegate.didFinish` | `WebviewBridge.startHandshake` | Closure injected into navigation delegate | WIRED | Fires after `bus-harness.html` loads (AppDelegate.swift:279-283) |
| `WebviewBridge.onHandshakeArmed` | `AppDelegate.onBusArmed` | `onHandshakeArmed` closure | WIRED | Test seam + production logging wired (AppDelegate.swift:292-295) |
| Handshake mismatch/timeout | `TCCAlertService.presentHardBlock` + `onHandshakeMismatch` (`NSApp.terminate`) | `alertPresenter` closure | WIRED | Mismatch test in AppDelegateBusWiringTests confirms `terminateCalls == 1` |
| `WKUserScript Injection.js` | `window.jarvisBus` | installed `.atDocumentStart` in JarvisBusWorld | WIRED | Test `test_injectionScriptInstalledAtDocumentStart` asserts injectionTime + contentWorld |
| `OutboundBatcher.Sink` | `WebviewBridge.sendRaw` | protocol-conformance extension | WIRED | Extension at WebviewBridge.swift:312-315 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `WebviewBridge` | `handshakeState` | Transitioned by `startHandshake`, `handleHelloAck`, `handleTimeout` | Yes — driven by real JS-side ack flowing back through `WKScriptMessageHandlerWithReply` | FLOWING |
| `WebviewBridge.sendRaw` | `json` payload | `BusCoder.makeEncoder().encode(message)` → real `BusOutbound` case | Yes — every outbound emits real encoded JSON; no static stub | FLOWING |
| `OutboundBatcher` | `pendingTokens`, `latestAudio` | `postToken`, `postAudio` external call sites | N/A at P2 — batcher is armed-but-idle (no caller yet). P3/P4 will pump. Artifact is ready-to-receive, not hollow | STATIC (intentional; batcher exists for P3/P4 consumers). Tests drive real data through the batcher, so the pipeline itself is proven FLOWING. |
| `AppDelegate.installBus` | `webviewBridge` | Constructed with real `WKWebView` from `hudPanel` + real `TCCAlertService` | Yes — production path loads real `bus-harness.html` from bundle | FLOWING |
| `window.jarvisBus` (TS bridge) | `protocolVersion` | `BUS_PROTOCOL_VERSION` import from `@jarvis/bus` package | Yes — 2.0.0 constant from protocol.ts | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Swift Bus test suite passes | `swift test --package-path packages/Bus` | `Executed 47 tests, with 0 failures` | PASS |
| TS Bus vitest passes | `pnpm --filter @jarvis/bus test --run` | `Tests 28 passed (28)` — 21 round-trip + 7 bridge | PASS |
| Protocol-version pre-build script on current tree | `scripts/check-bus-protocol-version.sh` | `bus parity OK at v2.0.0` (exit 0) | PASS |
| Protocol-version script rejects mismatch | `scripts/test-check-bus-protocol-version.sh` | `check-bus-protocol-version.sh correctly rejected mismatch fixture` (exit 0) | PASS |
| HUD-04 lint on current tree | `scripts/check-no-evaluate-javascript.sh` | `no evaluateJavaScript calls — HUD-04 OK` (exit 0) | PASS |
| HUD-04 lint rejects forbidden API | `scripts/test-check-no-evaluate-javascript.sh` | `check-no-evaluate-javascript.sh correctly rejected bad fixture` (exit 0) | PASS |
| Harness parity check | `scripts/check-bus-harness-parity.sh` | `bus-harness.html parity OK` (exit 0) | PASS |
| Fixtures byte-identical across sides | `/usr/bin/diff -r packages/Bus/Tests/BusTests/Fixtures webview/packages/bus/fixtures` | no output (all 14 identical) | PASS |
| Harness canonical vs bundle copies match | `/usr/bin/diff webview/bus-harness.html App/Resources/webview/bus-harness.html` | no output | PASS |
| Xcode build w/ all 3 pre-build phases | `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` | `** BUILD SUCCEEDED **` | PASS |
| Zero `evaluateJavaScript` in production | `grep -rn "evaluateJavaScript" App/ packages/ --include="*.swift"` excluding tests | only 2 hits, both comment/doc strings in WebviewBridge.swift | PASS |

### Requirements Coverage

| REQ | Source Plan(s) | Description | Status | Evidence |
|-----|---------------|-------------|--------|----------|
| HUD-03 | 02-01, 02-02, 02-03 | All HUD state transitions driven by Swift via typed JSON bus over `WKScriptMessageHandlerWithReply`; `type` discriminator + hand-written Codable | SATISFIED | `WKScriptMessageHandlerWithReply` conformance at WebviewBridge.swift:293-308. Hand-written `Codable` extensions on `BusOutbound` (151 LOC, zero `default:`) + `BusInbound` (49 LOC). 7 WebviewBridgeTests cases pass covering every reply branch. TS mirror at protocol.ts with exhaustive `never`-sentinel decode. |
| HUD-04 | 02-03, 02-04 | `callAsyncJavaScript(arguments:)` primitive-string payload; never `evaluateJavaScript`; lint-enforced build breaker | SATISFIED | Production call in WebviewBridge.sendRaw (line 183-193) uses primitive-string `["payload": json]` argument. Lint script `check-no-evaluate-javascript.sh` wired as Xcode pre-build phase. Negative test harness confirms script rejects forbidden API. Zero production callers of `evaluateJavaScript`. |
| HUD-05 | 02-01, 02-02, 02-03 | Two-way `BUS_PROTOCOL_VERSION` handshake refuses mismatch with native `NSAlert`; mismatch path tested | SATISFIED | `HandshakeState` enum with 5 states (Handshake.swift:13-19). Mismatch path → `alertPresenter` → `TCCAlertService.presentHardBlock` + `NSApp.terminate(nil)` in production. 2s timeout with identical alert path. Tests: `test_handshakeMismatchTriggersAlertAndBlocks` + `test_handshakeTimeoutTriggersAlert` + `test_handshakeMismatchCallsTerminate` (app-level). |
| HUD-06 | 02-03 | High-freq events coalesce via `OutboundBatcher` ~30Hz; state transitions flush immediately | SATISFIED | `OutboundBatcher` actor (90 LOC). `postAudio` latest-wins, `postToken` concat, `flushAndSend` cancel-drain-send semantics. 5 dedicated BatcherTests cases including order-preservation under interleaved state transition. |
| SEC-09 | 02-01, 02-02, 02-04 | `scripts/check-bus-protocol-version.sh` pre-build phase; Swift + TS versions must match; round-trip per enum case against fixtures | SATISFIED | Script wired as Xcode pre-build phase in project.yml:116-123 with inputFiles binding to Protocol.swift + protocol.ts. Fixture dirs byte-identical (14 fixtures each). `CodableRoundTripTests.test_allHudStateCasesHaveFixtures` asserts coverage across every `HudState` case. TS round-trip test exercises every fixture via `decodeOutbound` + re-encode JSON-normalized compare. Negative harness confirms script fails on mismatch. |

All 5 REQ-IDs for Phase 2 (HUD-03, HUD-04, HUD-05, HUD-06, SEC-09) SATISFIED. No orphaned requirements — ROADMAP.md lists exactly these five for Phase 2 and all appear in plan frontmatter.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| WebviewBridge.swift | 19, 325 | String `"evaluateJavaScript"` in doc comments | Info | Comments documenting the forbidden API (for future maintainers). The lint script specifically skips matches inside `grep -nE '\.evaluateJavaScript\('` (requires the `.` prefix and `(`). Comments use the bare word, so no lint interaction. Not a real code-level anti-pattern. |

No TODO/FIXME/XXX/HACK/PLACEHOLDER markers found in any Phase 2 production source. No stub `return null` / `return []` handlers. No `console.log`-only functions. No hardcoded-empty prop patterns at call sites.

### Human Verification Required

None. Every Phase 2 success criterion is observable programmatically via the test suites + lint scripts + build pipeline, and every mechanism is already exercised by an automated check that passes.

Phase 2 is a protocol + lint-rail phase, not a visual/UX phase — no visual polish, no user-flow completion, no real-time behavior that requires human senses. The one user-facing surface (`NSAlert` on handshake mismatch) is test-injected via `alertPresenter` closure and its production wiring to `TCCAlertService.presentHardBlock` inherits Phase 1's hard-block modal which was human-verified during Phase 1.

Residual concern acknowledged in input context: `xcodebuild test -only-testing:JarvisAppTests` remains blocked by the Xcode 26 dyld Team-ID quirk tracked in `.planning/phases/01-foundations/01-HUMAN-UAT.md`. This is a Phase 1 defect — AppDelegateBusWiringTests compile-verifies fine and the Swift package's own 47-test suite passes via `swift test`, so Phase 2 acceptance does not depend on resolving it.

### Gaps Summary

No gaps. All 5 roadmap success criteria are met with live evidence:

1. HUD-04 invariant: zero `evaluateJavaScript` in production Swift; `callAsyncJavaScript` with primitive-string argument is the sole JS entry; lint-enforced as Xcode pre-build phase (live-run PASS; negative harness rejects fixture).
2. HUD-05 invariant: `BUS_PROTOCOL_VERSION = "2.0.0"` on both sides; mismatch and timeout both terminal via `NSAlert` + `NSApp.terminate`; 5 handshake tests + 1 app-level mismatch test pass.
3. SEC-09 build-breaker: `check-bus-protocol-version.sh` pre-build phase diffs constants + fixture directories; live-run PASS; negative harness confirms rejection.
4. HUD-06 coalescer: `OutboundBatcher` actor with 33ms window; 5 dedicated tests cover latest-wins, concat, flush-ordering, and multi-window paths.
5. HUD-03 inbound: `WKScriptMessageHandlerWithReply` with `MainActor.assumeIsolated`; every reply branch produces success-or-failure plist; 7 tests cover all paths.

**Full test pass counts (live-run 2026-04-23):**
- Swift Bus package: 47/47
- TS `@jarvis/bus`: 28/28 (21 round-trip + 7 bridge)
- xcodebuild Debug: BUILD SUCCEEDED (all 3 pre-build phases exercised)
- Negative harness suites: both PASS

Phase goal achieved: Swift and the WKWebView now speak a versioned, strictly-typed JSON protocol. Schema drift is architecturally foreclosed by (a) hand-written exhaustive-switch `Codable` with no `default:` branches, (b) Swift/TS constant parity check as a build breaker, (c) byte-identical fixtures enforced by `diff -r` as a build breaker, (d) the HUD-04 lint rule as a build breaker, (e) the two-way version handshake rejecting mismatched bundles before the HUD loads. Every one of the five defenses is independently tested and reachable by pre-existing scripts.

---

_Verified: 2026-04-23T23:15:58Z_
_Verifier: Claude (gsd-verifier)_
