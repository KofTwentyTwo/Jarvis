---
title: Test Pyramid Audit — 2026-05-03
auditor: deep-audit subagent
scope: packages/*/Tests, App/Tests, webview/packages/*/tests
status: complete
---

# Test Pyramid Audit — Brutal Honesty Edition

## TL;DR

**Letter grade: C–.**

The pyramid is **wide at the unit base, thin at the seam, and effectively absent at the integration apex**. ~960 tests defend tiny, isolated capability surfaces with high fidelity, but the cable diagram between subsystems — the part where every shipped bug has lived — is verified by exactly **two** real WKWebView tests (added today, in response to a bug that already shipped) and **two** real MCP-helper integration tests. Everything else is unit-level fakes, source-grep gates, or trivial-property assertions. The "8 boundary grep gates" + "9/9 phase verifications" green light is real but measures the wrong thing — it proves layers don't *cross*, not that they *connect*. The user's lived experience ("nothing works end-to-end") is the correct read; the test pyramid's "400+ green" is theatre over the load-bearing seam.

## 1. Inventory (Actual Counts, Not Claimed)

`find … | grep -v .build/` and `grep -E '^\s*func test'`:

| Target | Files | Test funcs/cases |
|---|---:|---:|
| `packages/AgentCore/Tests` (AgentCoreTests + AgentOrchestratorTests + AnthropicProviderTests + OllamaProviderTests) | 34 | **194** |
| `packages/Bus/Tests` | 7 | 56 |
| `packages/Config/Tests` | 6 | 16 |
| `packages/DevOverlay/Tests` | 3 | 14 |
| `packages/Harness/Tests` | 13 | 32 |
| `packages/Keychain/Tests` | 1 | 6 |
| `packages/Logging/Tests` | 4 | 17 |
| `packages/MCP/Tests` | 19 | **85** |
| `packages/Memory/Tests` | 16 | 84 |
| `packages/Replay/Tests` | 6 | 33 |
| `packages/Shell/Tests` | 4 | 20 |
| `packages/Vision/Tests` | 14 | 57 |
| `packages/Voice/Tests` | 18 | 64 |
| `App/Tests/AppTests` | 17 | **90** |
| `App/Tests/JarvisEntitlementProbeTests` | 1 | 1 |
| `webview/packages/bus/tests` (vitest) | 2 | 23 |
| `webview/packages/hud/tests` (vitest) | 9 | 61 |
| **TOTAL** | **174** | **~853 Swift + ~84 webview ≈ 937** |

`Harness` is a CLI/eval harness, not a runtime subsystem; ignore for "defending the app." Subtract its 32 → ~905 production-relevant. The "400+" claim is conservative by ~2x. The number is also the problem.

## 2. Stratified Classification (n=30)

R = REAL, M = MOCK, D = DEAD/RUBBER-STAMP, G = GREP/structural.

| # | Test | File:line | Class | Notes |
|---|---|---|---|---|
| 1 | `RealWKWebViewIntegrationTests.test_endToEndHandshake_reachesArmed` | packages/Bus/Tests/BusTests/RealWKWebViewIntegrationTests.swift:143 | **R** | Loads HTML in real WKWebView, drives JS round-trip. Added today after the bug it would have caught had already shipped. |
| 2 | `RealWKWebViewIntegrationTests.test_passesThroughSentHello` | …:188 | R | State-transition observation; real round-trip. |
| 3 | `WebviewBridgeOutboundTests.test_sendWhenArmedCallsEvaluator` | packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift:80 | M (broken) | Asserts `WKContentWorld(name: "JarvisBusWorld")` against `FakeJSEvaluator`. Production switched to `.page` in `fb41c5f`. **Test is currently failing** but was reported green (F-A2-01). Stale rubber-stamp on retired literal. |
| 4 | `WebviewBridgeTests.*` | packages/Bus/Tests/BusTests/WebviewBridgeTests.swift | M | Uses `handleInboundString` test seam, bypasses real `WKScriptMessageHandler`. Could not have caught the WKContentWorld bug — milestone audit explicitly notes this seam. |
| 5 | `HandshakeTests.*` | packages/Bus/Tests/BusTests/HandshakeTests.swift | M | Drives `handleHelloAck` directly. Same seam-bypass. |
| 6 | `AppDelegateBusWiringTests.test_handshakeMismatchCallsTerminate` | App/Tests/AppTests/AppDelegateBusWiringTests.swift:103 | M | Drives mismatch via `bridge.handleHelloAck("1.0.0")`. Real `AppDelegate`, fake handshake. |
| 7 | `AppDelegateWiringTests.test_loggingBootstrapCalled` | …:52 | M | Real delegate, fake keychain/HID/entitlement; asserts a single `bootstrapped += 1` increment. Trivially correct. |
| 8 | `AppDelegateWiringTests.test_stateDumpDoesNotIncludeAPIKey` | …:112 | R | Pasteboard side-effect actually verified; a recognizable plaintext string is checked for in real `NSPasteboard`. Ironically, the file's own comment admits this used to be `XCTAssertTrue(true)`. |
| 9 | `MCPTimeIntegrationTests.test_get_time_returns_iso8601` | packages/MCP/Tests/MCPTests/MCPTimeIntegrationTests.swift:26 | **R** | Spawns real `mcp-time` helper subprocess, parses ISO8601 against wall clock. Gold-standard. |
| 10 | `MCPClipboardIntegrationTests.*` | packages/MCP/Tests/MCPTests/MCPClipboardIntegrationTests.swift | R | Real helper spawn + `NSPasteboard`. |
| 11 | `MCPClientHappyPathTests.*` | packages/MCP/Tests/MCPTests/MCPClientHappyPathTests.swift | R | Spawns real `MockHelperBuilder` subprocess. |
| 12 | `PackageBoundaryTests.testVisionModuleCompilesStandalone` | packages/Vision/Tests/VisionTests/PackageBoundaryTests.swift:14 | **D** | Body is `XCTAssertTrue(true)` with comment "compile is the assertion". Cannot fail. |
| 13 | `PackageBoundaryTests.testPublicAPISurface` | …:24 | D | `let _: PresenceEvent.Type = PresenceEvent.self`. Compile-only existence proof. |
| 14 | `CameraCaptureTCCTests.test*` | packages/Vision/Tests/VisionTests/CameraCaptureTCCTests.swift | M | Tests TCC denial branches with `setAuthStatusProbe`; **never exercises real `AVCapturePhotoOutput`**. The 1×1 black JPEG stub (`CameraCapture.swift:106-115`, BLOCKER-INT-4) sails through every assertion. |
| 14b | `FrameAttachReplayPlaceholderTests.*` | packages/Vision/Tests/VisionTests/FrameAttachReplayPlaceholderTests.swift | M | Asserts replay payload is a placeholder — by design. Cannot detect that *production capture* is also a placeholder. |
| 15 | `PhaseSevenGrepGateTests.testAppDelegateInstallOrder` | packages/Memory/Tests/MemoryTests/PhaseSevenGrepGateTests.swift:89 | **G** | Reads `App/AppDelegate.swift` as text, scans for substrings `installMemory()` / `installVoice()` / `installVision()`. Asserts source-line ordering. Does **not** exercise the runtime install graph. Cannot detect F-E-RACE-1 (mcp install task race) — the bug fixed today. |
| 16 | `PhaseSevenGrepGateTests.test*Gate` (4 others) | …:60–80 | G | Wrap `bash scripts/check-*.sh`. Boundary discipline only. |
| 17 | `HudStateEnumTests.test_bootingAndReconfiguringLabelsMatchSpec` | App/Tests/AppTests/HudStateEnumTests.swift:31 | **D / RUBBER-STAMP** | `XCTAssertEqual(HudState.booting.voiceOverLabel, "Jarvis, starting up")` — asserts the literal in source matches the literal in test. The string ships from one file to the other; nothing else can change. |
| 18 | `HudStateEnumTests.test_switchOnHudStateIsExhaustive` | …:44 | D | Compile-time exhaustiveness ≠ test. |
| 19 | `WebviewBundleLoadTests.test_assetsDirectoryGitignored_documentedInSmokeScript` | App/Tests/AppTests/WebviewBundleLoadTests.swift:60 | **D** | Body is `XCTAssertTrue(true)` with comment "this test intentionally has no assertion — it exists to document the split of responsibility". Documentation masquerading as a test case. |
| 20 | `WebviewBundleLoadTests.test_indexHtmlInRepoWebviewDir` | …:26 | R (file-IO smoke) | Real `FileManager.default.fileExists`. Useful but tiny scope. |
| 21 | `MemoryWiringEndToEndTests.testMemoryEnqueueReceivesNonNilUserAndAssistantText` | packages/Memory/Tests/MemoryTests/MemoryWiringEndToEndTests.swift:33 | R | Real `OrchestratorEventBroadcaster` + real `TurnTranscriptStore`; spy at the enqueue boundary. The kind of test the codebase needs more of. |
| 22 | `TextInputEndToEndTests.*` | packages/AgentCore/Tests/AgentOrchestratorTests/TextInputEndToEndTests.swift | M (with real DB) | Real `ReplayLog` (SQLite), `MockLLMProvider`, `StubToolDispatcher`. Calls `replay.beginSession(...)` explicitly at line 58 — which is exactly why it cannot catch the F-E-FK-1 bug (AppDelegate forgetting to call beginSession). |
| 23 | `AnthropicProviderTests/FixtureReplayTests.*` | packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift | R | Replays recorded SSE bytes through the real decoder. High value. |
| 24 | `OllamaProviderTests/NDJSONDecoderTests.*` | packages/AgentCore/Tests/OllamaProviderTests/NDJSONDecoderTests.swift | R | Same. |
| 25 | `SessionForeignKeyTests.test_FK1_startTurn_withoutBeginSession_throws` | packages/Replay/Tests/ReplayTests/SessionForeignKeyTests.swift:42 | R | Real SQLite. **Added today, in commit 048ab08, after the bug shipped.** Pre-existing `ReplayLogTests` exercised `beginSession + startTurn` happy path only — the *negative* assertion didn't exist. |
| 26 | `MCPRuntimeWiringTests.test_buildMCPRuntime_returnsRuntimeWithFullChain` | App/Tests/AppTests/MCPRuntimeWiringTests.swift:79 | M | Uses `compose(...)` test seam to skip real helper spawn. Spy bus, spy inner dispatcher. **Identical pattern that hid BLOCKER-INT-1**: test wires a `SpyBus`, production wires a `NoopBusGateway` — both satisfy the protocol; only the latter ships. |
| 27 | `WizardStateTests.test_firstUnresolvedStageIsAPIKeyWhenEmpty` | App/Tests/AppTests/WizardStateTests.swift:21 | M | Real state machine, fake keychain. Reasonable unit test. |
| 28 | `webview/bus/tests/round-trip.test.ts` | webview/packages/bus/tests/round-trip.test.ts | R (encode/decode) | Real fixtures, real codec round-trip. Doesn't cross the JS↔Swift boundary. |
| 29 | `webview/hud/tests/RingMesh.test.tsx` | webview/packages/hud/tests/RingMesh.test.tsx:37 | M | Comment: "jsdom has no WebGL context, so R3F's Canvas will log an error … but MUST NOT throw … We catch the render call and verify the container got _something_." Compile-mounting test. **This test is green; F-A1-01 (rings static) is the bug it should be catching.** |
| 30 | `OrchestratorEventBroadcasterTests.*` | packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorEventBroadcasterTests.swift | M | Real broadcaster, in-process subscribers. Doesn't cross to a real Bus. |

**Sample distribution:** REAL ~30%, MOCK ~47%, DEAD/RUBBER-STAMP ~17%, GREP/structural ~6%. Five `XCTAssertTrue(true)` tautologies confirmed across the tree — at least 5 tests mathematically incapable of failing.

## 3. Coverage of the Integration Layer (the seam where bugs live)

| Integration question | Tests that answer it |
|---|---|
| Cold-launch the app and assert one full text turn happens? | **0** |
| Mount the JS bundle in a real WKWebView and exercise input → output? | **2** (RealWKWebViewIntegrationTests, added today; both stop at handshake — neither sends a real outbound `tokenDelta` and asserts JS receipt) |
| Spawn a real MCP helper and verify `get_time` returns a real time? | **1** (`MCPTimeIntegrationTests.test_get_time_returns_iso8601`). `mcp-clipboard` integration also exists. |
| Exercise the orchestrator with a real LLM provider? | **0**. `AnthropicProvider`/`OllamaProvider` decoder tests replay recorded fixtures (high value), but no test drives the orchestrator against a mock-server-backed provider end-to-end. |
| Verify `AppDelegate.applicationWillFinishLaunching` produces a working orchestrator that can serve a turn? | **0**. The wiring tests (AppDelegateWiringTests, AppDelegateBusWiringTests, MCPRuntimeWiringTests) verify *that* objects are constructed and *that* certain subscribers fire on injected stubs. None verifies the runtime install graph reaches a working state. **F-E-RACE-1, F-E-FK-1, F-E-WIRE-1 (commit 048ab08) are exactly the bug class this gap creates.** |
| Real camera frame ≠ 1×1 JPEG? | **0**. `CameraCaptureTCCTests` exercises only denial branches; `FrameAttachReplayPlaceholderTests` *asserts* the payload is a placeholder. |

The `App/Tests/AppTests` target is, per CLAUDE.md and HANDOFF context, also broken on Xcode 26. So even what does exist there cannot be CI-enforced.

## 4. The Specific Pattern That Produced Today's Bugs

Three bugs fixed in 048ab08 (verified against `git show 048ab08`):

**(a) F-E-RACE-1: `installAgent` ran before MCP runtime built.** `AppDelegate.swift:482` (pre-fix) used `Task { … }` with no captured handle; `agentInstallTask` awaited `memoryInstallTask` and `visionInstallTask` but not the MCP one. Existing test that should have caught it: **none**. `PhaseSevenGrepGateTests.testAppDelegateInstallOrder` (Memory/Tests:89) does check `installMemory` < `installVoice` ordering — but it does it by *grepping the source for substrings*, not by exercising the runtime task graph. A textual "vision before voice" assertion cannot detect a missing `await self?.mcpInstallTask?.value` in a Task body.

**(b) F-E-FK-1: ReplayLog beginSession never called.** `installAgent` constructed orchestrator with `SessionID.fresh()` and never inserted the parent row. Existing tests:
- `ReplayLogTests` covers `beginSession → startTurn` happy path. Test calls `beginSession` itself before `startTurn`, so the negative case ("what if production forgets?") is invisible.
- `TextInputEndToEndTests.swift:58` — same pattern: test calls `replay.beginSession(...)` explicitly. Test passes; production silently fails.
- `MCPRuntimeWiringTests` doesn't drive the FK path.
- The new `SessionForeignKeyTests.test_FK1_startTurn_withoutBeginSession_throws` (added today) is the *correct* test pattern but had no precedent. **Pre-existing tests that should have caught it: none.**

**(c) F-E-WIRE-1: OutboundBatcher constructed only inside installVoice.** `.bus` subscriber chained-optional through `outboundBatcher?.postToken(...)`; voice DAG short-circuited on missing OpenWakeWord/Silero models in Debug; batcher stayed nil; tokens silently dropped. Existing tests: `BusForwarderTests` exercise the forwarder in isolation with a real batcher; no test ever runs `installVoice` with the model-load short-circuit and checks that `outboundBatcher` is still non-nil afterwards.

**Common pattern:** Tests pass under "happy fixture" conditions where the test sets up state explicitly. Production assembles the same state via `applicationWillFinishLaunching`'s task graph. The graph is tested as static *order*, not as runtime *completion*.

## 5. Top 10 Most Theatrical Tests

These pass impressively but defend nothing:

1. **`PackageBoundaryTests.testVisionModuleCompilesStandalone`** (Vision/Tests:14) — `XCTAssertTrue(true)`. Comment: "compile is the assertion." Pure tautology.
2. **`PackageBoundaryTests.testPublicAPISurface`** (…:24) — `let _: PresenceEvent.Type = PresenceEvent.self`. Compile-time existence check dressed as a test.
3. **`WebviewBundleLoadTests.test_assetsDirectoryGitignored_documentedInSmokeScript`** (App/Tests:60) — `XCTAssertTrue(true)`. Comment: "intentionally has no assertion." Honest about its uselessness.
4. **`HudStateEnumTests.test_bootingAndReconfiguringLabelsMatchSpec`** (App/Tests:31) — asserts `HudState.booting.voiceOverLabel == "Jarvis, starting up"`. Source string == test string. Cannot fail under any user-meaningful change.
5. **`HudStateEnumTests.test_existingLabelsPreservedFromPhase1`** (…:36) — five lines of the same pattern. Five rubber stamps in a row.
6. **`HudStateEnumTests.test_switchOnHudStateIsExhaustive`** (…:44) — uses an exhaustive switch. The compiler enforces this; the test body adds zero verification.
7. **`PhaseSevenGrepGateTests.testAppDelegateInstallOrder`** (Memory/Tests:89) — greps `App/AppDelegate.swift` text for the substring `await … installMemory()` ordering. Defended against typos; defenseless against the *actual* installation race that shipped.
8. **`FrameAttachReplayPlaceholderTests`** (Vision/Tests) — asserts that the Replay payload IS a placeholder. By design. The test would fail if vision started recording real frames. It's defending a stub against being upgraded.
9. **`WebviewBridgeOutboundTests.test_sendWhenArmedCallsEvaluator`** assertion at line 80 — asserts `call.contentWorld == WKContentWorld.world(name: "JarvisBusWorld")` after production was changed to `.page`. The test currently fails; HANDOFF claimed it was green. (= F-A2-01.) Worse than theatre — a false-positive.
10. **`webview/hud/tests/RingMesh.test.tsx:37`** — "verify the container got _something_". Mounts in jsdom (no WebGL). Cannot observe whether rings animate. F-A1-01 (rings static) ships green here.

## 6. Mock Infrastructure Quality

`MockLLMProvider` (`packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift:12`) is a faithful actor-based fake. It records `(messages, tools, toolChoice, model, images)` tuples and yields scripted `LLMEvent`s. It does **not**:
- Validate Anthropic vs Ollama wire-format quirks (Ollama's `tool_calls` arriving on the chunk *before* `done: true` per CLAUDE.md, the new tokenizer's ~35% inflation, or the SSE parser's `partial_tool_use_at_disconnect` handling).
- Emit failures the way real network providers do (timeouts, partial decodes, mid-stream cancellations).
- Cross-check that the request body the orchestrator sent would be accepted by a real Anthropic endpoint.

The decoder side compensates: `AnthropicProviderTests/FixtureReplayTests` and `OllamaProviderTests/{NDJSON,OpenAICompat}DecoderTests` replay recorded byte streams through the real decoder, which is the right shape. But these never connect to the orchestrator. There is **no end-to-end test that verifies the orchestrator + a (mock-server-backed) real provider produces tokens that reach a real WKWebView.**

`SpyBus` (App/Tests/AppTests/MCPRuntimeWiringTests.swift:55) is a particularly dangerous fake: it satisfies `BusGateway` with counters. Production uses `NoopBusGateway` (`AppDelegate.swift:1606-1618`) which **also** satisfies `BusGateway` with empty bodies. Both pass the type system. The test passes with `SpyBus`; production silently swallows tool-call events with `NoopBusGateway`. **The mock and the production stub are semantically divergent in the same direction the production bug exploits.** That is exactly the failure mode of mocks not faithful to their counterparts.

`FakeJSEvaluator` in Bus tests bypasses the real `WKScriptMessageHandler` ↔ `WKContentWorld` interaction. It satisfies the protocol; it cannot reproduce the per-world isolation that produced the WKContentWorld bug. The 30 May 2026 audit-and-fix session learned this the hard way; the fix was to add `RealWKWebViewIntegrationTests`.

## 7. High-Leverage Recommended Additions

1. **End-to-end text turn through a real WKWebView.** Cold-launch a test `AppDelegate`, drive `applicationWillFinishLaunching`, wait for handshake, post a `chatSubmit` from JS, mock-server an Anthropic SSE response (3 tokens + endTurn), assert the JS-side `chatEvents` store receives `turnStarted`, ≥1 `tokenDelta`, `turnEnded`. This single test catches BLOCKER-INT-1 / -2 / -3 / F-E-RACE-1 / F-E-WIRE-1 simultaneously.
2. **Cold-launch FK assertion.** After `applicationWillFinishLaunching` settles, query the `sessions` table and assert exactly one row exists for the orchestrator's `sessionId`. Catches F-E-FK-1 directly.
3. **Real `mcp-applescript` confirmation flow.** Spawn the helper, dispatch a `run_applescript` call, drive the confirmation broker through the bus, assert `emitToolCallStart`/`End` are observed in the JS-side bus listener. Catches BLOCKER-INT-1 (NoopBusGateway) and validates HUD-07.
4. **Real-camera capture asserts JPEG dimensions ≠ 1×1.** Decode the captured JPEG with `CGImageSourceCreateWithData` and assert `width ≥ 320 && height ≥ 240`. Catches BLOCKER-INT-4. Skip on CI without camera, fail loudly on local dev.
5. **Install-graph runtime ordering test.** Instrument each `installX` to write to a queue. Run `applicationWillFinishLaunching` and assert observed completion order matches expected — at runtime, not at source-grep. Catches F-E-RACE-1 generically.
6. **R3F ring animation observer.** Use `@react-three/test-renderer` (or a Playwright-based webview harness) and sample the `ParticleRing`'s mesh `position`/`rotation` across two frames; assert non-zero delta. Catches F-A1-01.
7. **TTS tier round-trip with real `AVSpeechSynthesizer`.** Synthesize "test", capture the audio buffer (not just verify the API didn't throw), assert ≥ 50 ms of non-silent samples. Catches WARN-INT-1 (engine nil).
8. **Webview-side outbound producer presence test.** Static analysis or a JS unit test that asserts at least one component in `webview/packages/hud/src/` calls `bus.send({ type: 'chatSubmit', ... })`. Catches BLOCKER-INT-3 (no chat input UI) at TS layer, before runtime.
9. **`sessionHistory` hydration test.** On `webviewReady`, assert at least one `sessionHistory` outbound is emitted; assert the JS store receives it. Catches WARN-INT-2.
10. **A "two-stub-protocol-conformance" lint.** Whenever `BusGateway` (or any other shipping protocol) has a `Noop*` and a `Spy*` conformer, fail tests when prod constructs the `Noop*` one in non-test code. This is the structural defense against the SpyBus/NoopBusGateway divergence that hid BLOCKER-INT-1.

## Verdict

The test pyramid is **C–**. Unit suites are diligent, decoder/codec tests are excellent, and ~30% of the sampled tests are genuine real-subsystem exercises. But: the integration apex has **2** real-WKWebView tests (added today) and **0** end-to-end orchestrator-to-webview round-trips. The SpyBus/NoopBusGateway pair, the install-order grep test, and the PackageBoundaryTests' `XCTAssertTrue(true)` all illustrate the same pattern — tests verify shapes the compiler already enforces, while the seams ship untested. The user's 50+ hours of "agent work, nothing demonstrably working" is consistent with the test pyramid's actual coverage: the bugs that have repeatedly shipped (WKContentWorld isolation, NoopBusGateway, install race, FK violation, OutboundBatcher gating, 1×1 JPEG) all live in the same untested seam. **The 400+ green tests are real but not load-bearing where the user's experience lives.** Phase F1 (top-level IntegrationTests target) is the structural fix; until it lands, every future milestone audit will surface the same shape of finding.
