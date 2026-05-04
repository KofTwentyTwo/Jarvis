# Test Quality Audit — 2026-05-04

## Verdict: MIXED, trending STRONG at the seam, still WEAK at one critical layer

The 2026-05-04 day's work materially raised test quality at the boundaries that 2026-05-03 flagged as theatre. New tests for vision (camera capture delegate, frame-stream fan-out, real-hardware), memory (Brutus end-to-end, priorFacts UPDATE op, install cascade), audio (BufferBroadcaster fan-out), and the MCP bus gateway are mostly **load-bearing**: they exercise real production types, drive real data through them, and assert content rather than presence. They would have caught the bugs they were written for.

That said:

- **The macOS 26 `LiveSpeechAnalyzerBridge` body — the actual STT brain — is still untested.** PCMBufferBuilder (the input adapter) is well covered, but the SpeechAnalyzer pipeline itself has only HUMAN-UAT coverage. This is the single biggest hole.
- **The production `chunkPump` closure in `App/AppDelegate.swift:892-922`** — `BufferBroadcaster.subscribe()` + `RingBuffer.readMono16k(into:)` + 1024-frame windowing + 10ms-on-starve loop — is **not exercised by any test**. All 7 tests that drive a chunk pump (E1/E2/E3 + VAD-1/2/4/5) construct synthetic pumps that do not go through the production code path. Same structural gap that produced BLOCKER-INT-1 (SpyBus / NoopBusGateway divergence) — repeated.
- A handful of structural / grep-the-source assertions remain (FrameAttachConfirmSendWiring, MissingT2Provider's AppDelegate grep, CameraCapture source greps). They're useful regression fences but cannot verify runtime behavior.
- **Two pre-existing failures are still red on a clean tree:** `TTSInterruptTests.testI3` (10s deterministic block, root cause identified below) and `InputMonitoringDenialTests.swift` (compile failure, trivial 1-line fix). Neither was triaged in today's batch despite being called out in SESSION-STATE.

The test pyramid moved from C– (2026-05-03) to roughly **B-**: integration apex still thin, but the new tests are honest. The remaining theatrical patterns are a small minority and are now quarantined to known surfaces.

## Today's new tests — load-bearing assessment

### Vision (Track C)

- **`CameraCaptureDelegateTests` (3 cases)** — `packages/Vision/Tests/VisionTests/CameraCaptureDelegateTests.swift` — **LOAD-BEARING (mostly)**.
  - `testCaptureFrameRoutesThroughOverrideSeam` (line 18) opens a real `AVCaptureSession`, primes a `photoCaptureOverride`, and asserts the override's bytes flow through `captureFrame()` — this would catch a regression where `captureFrame` short-circuits to a fixture before reaching the override seam. Skips cleanly without a camera. Good.
  - `testCaptureFrameThrowsSessionNotRunningBeforeOpen` (line 54) — strong negative-path test.
  - `testCaptureFrameSourceDoesNotEmbedHardcodedJPEG` (line 77) is a **source-grep test**. It greps `CameraCapture.swift` for "onePixelJPEG" / "photoOutput.capturePhoto" / "AVCapturePhotoCaptureDelegate". Useful as a regression fence (the literal stub's name was the original BLOCKER-INT-4 fingerprint), but it cannot detect a *new* hardcode under a different name. Acceptable in tandem with the hardware test, weak alone.
  - **Gap:** the override seam means `PhotoCaptureProxy`'s actual delegate-callback bridging (the retain-self + break-cycle-on-didFinishProcessingPhoto logic SESSION-STATE describes) is not directly tested without the hardware path. C-6 covers it for hosts with a camera; CI would not.

- **`CameraCaptureFrameStreamTests` (4 cases)** — **LOAD-BEARING**.
  - `testFrameStreamYieldsInjectedSamplesAfterOpen` (line 13) opens a real session, registers a frameStream subscription, polls for the subscription to attach (via `delegate.subscriberCount() >= 1`), then injects a `.syntheticDetection` and asserts it surfaces. Real fan-out exercise.
  - `testShutdownFinishesOutstandingStreams` (line 68) and `testFrameStreamFinishesImmediatelyWhenNotOpen` (line 107) cover the lifecycle invariants directly.
  - `testFrameStreamSourceNoLongerImmediatelyFinishes` (line 133) is again a source-grep gate. Same caveat as above.
  - `try await Task.sleep(for: .milliseconds(10))` in a loop up to 20 iterations (line 43) is a cooperative wait, well-bounded — fine.

- **`CameraCaptureRealHardwareTests` (2 cases)** — **LOAD-BEARING when run** but **DEFAULT-SKIPPED**.
  - The right pattern: triple-gated on `JARVIS_REAL_CAMERA=1` env + device-present + `.authorized` TCC; explicitly does NOT call `requestAccess` so headless runs never block. Assertions are content-based: `jpegData.count > 1000`, SOI marker prefix, width/height > 1, `.sampleBuffer` (not `.cgImage` / `.syntheticDetection`).
  - **Gap:** never runs in CI by default. Documented well, but if no developer runs it locally, the path it defends will rot. Recommend a one-line entry in the runbook: "before merging to develop, run `JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision`".

- **`FrameAttachConfirmSendWiringTests` (3 cases)** — **MIXED**.
  - `testAppDelegateCallsConfirmSendInChatSubmitPath` and `testConfirmSendIsReachableFromBothChatHandlers` are pure source greps against `App/AppDelegate.swift`. They catch a regression that *removes* the wiring; they cannot catch a regression that calls `consumePendingFrameIfAny` but threads the wrong `userText` or invokes `submit(.text)` instead of `submit(.withImages)`. The same pattern that hid F-E-RACE-1 (grep verifies position, not behavior).
  - `testConfirmSendNilWhenNothingPending` (line 59) is the only behavioral test in this file. It's good but limited.
  - **Gap:** there is no test that drives a real `FrameAttachController` armed with a frame, calls one of the two AppDelegate handlers, and asserts the orchestrator received `.withImages(...)`. That's the test that would actually catch BLOCKER-INT-4-class regressions in this surface.

- **`MissingT2ProviderTests` (4 cases)** — **LOAD-BEARING**.
  - `testStreamFinishesWithExplicitError` and `testMultimodalStreamFinishesWithExplicitError` exercise both entry points and assert the explicit `VisionError.t2ProviderUnavailable`. Good — solves "silent T1-as-T2 fallback" by making the contract observable.
  - `testRouterStillStaysOnT1WhenT2Unavailable` (line 66) is a re-assertion of an existing invariant; harmless.
  - `testAppDelegateNoLongerCarriesSilentT1Fallback` (line 81) is again a source-grep regression fence. Acceptable — the symptom it defends against was a single literal in code.

- **`CameraButton.test.tsx` (3 cases)** — **LOAD-BEARING**.
  - `webview/packages/hud/tests/CameraButton.test.tsx`. Mocks `webkit.messageHandlers.jarvisBus.postMessage`, renders the real `<CameraButton/>`, fires `click`, then parses the captured payloads and asserts a `frameAttachRequested` envelope with exactly `['type']` keys. This is content-bearing — would fail under a wrong message type or extra payload field.

### Memory (Track D)

- **`MemoryInstallWiringTests` (5 cases)** — **LOAD-BEARING**.
  - `App/Tests/AppTests/MemoryInstallWiringTests.swift`. Real `AppDelegate.installMemory()` driven, with fakes only at the keychain / entitlement / HID seams. Asserts on real properties (`memoryStore == nil`, `memoryExtractionOrchestrator != nil`, `memoryExtractionCoordinator != nil`, `inProcessToolRegistry?.registered()` set membership).
  - The D-2 positive paths (`test_D2_bothToolsRegisterWhenBothDispatchersPresent`, `…_onlyForgetRegisters…`, `…_emptyRegistry…`) drive `AppDelegate.buildInProcessToolRegistry` directly with `StubForget` / `StubHybrid` and assert which tools register. Good shape — the seam is a static method that mirrors the production gating logic.
  - The `XCTAssertNotNil(memoryExtractionOrchestrator)` at line 67 is a property-existence check, but in this case it is the **D-1 invariant directly**: the bug was "this property goes nil"; the fix is "make sure it's not nil"; the test is honest.

- **`RememberBrutusEndToEndTests.testExtractionWriteThenSearchFindsBrutus`** — **STRONG LOAD-BEARING**.
  - `packages/Memory/Tests/MemoryTests/RememberBrutusEndToEndTests.swift:113`. Drives the full extraction → store → search loop with real `MemoryExtractor`, real `MemoryExtractionOrchestrator`, real `HybridSearch`. Fakes are only at the SQLite/vec/Ollama boundaries (`FakeStore` actor, `StubEmbedder`, `BrutusProvider`).
  - Final assertion is content-based: `hits.first?.summary == "Brutus breed Bernese Mountain Dog"`. That's the right shape — the contract is the surfaced text, not the count.
  - Cooperative wait (line 142): `while await store.snapshot().isEmpty && Date() < deadline` with a 2s deadline + 10ms poll. Bounded; no hardcoded sleep racing.
  - **Gap:** the boundary stops at `HybridSearch.searchFacts`. The MCP-side dispatch (SearchMemoryTool → HybridSearchAdapter → HybridSearch) is covered separately in `InProcessMemoryToolsTests` per the comment, but no test crosses *both* boundaries in one run. Reasonable scope choice; flag for awareness.

- **`MemoryExtractionOrchestratorTests` D-3 additions (2 cases)** — **LOAD-BEARING**.
  - `testD3_priorFactsLookupDrivesUpdateOp` (line 191) is excellent: it asserts `MemoryOp.update(supersedes: 99, …)` is the op the spy receives — content-level, not count-level. The `PriorAwareProvider` only emits UPDATE when it actually sees `[99]` in the system prompt, so the test fails if the priorFacts lookup is wired but the prompt-rendering is broken.
  - `testD3_priorFactsLookupErrorDegradesToEmpty` (line 278) hardcodes `Task.sleep(nanoseconds: 250_000_000)` — typical pattern; flake risk on heavily loaded CI but borderline acceptable. Final assertion is `spy.calls.count == 1` — count-level, but the contract is "drain task survives", which is binary so count == 1 is correct.

### Audio / Voice (Track B-7)

- **`BufferBroadcasterTests` (5 cases, swift-testing)** — **STRONG LOAD-BEARING**.
  - `packages/Voice/Tests/VoiceTests/BufferBroadcasterTests.swift`. BB-1 is sample-identity (writes a ramp, reads it back, asserts every sample matches with `< 1e-6` epsilon). BB-2 verifies multi-subscriber non-stealing — both subscribers see ALL frameCount samples. BB-3 verifies idempotent unsubscribe. BB-4 asserts late-joining subscriber sees only post-subscribe frames (assertion checks the value `0.1` not `0.9`, so the wrong-buffer regression would trip immediately). BB-5 is concurrent stress: 2 publisher tasks × 500 + 2 churn tasks × 200, asserts `read > 0` — weaker than the per-sample BB-1..BB-4 pattern but adequate as a deadlock/crash detector.
  - The stress test's `read > 0` is the only weak final assertion in the file. Could be tightened, but it's defending against deadlock + crash, which are binary outcomes; under-specifying the count is the right choice.

### MCP / Bus (BLOCKER-INT-1)

- **`MCPBusGatewayAdapterTests` (5 cases)** — **STRONG LOAD-BEARING**.
  - `App/Tests/AppTests/MCPBusGatewayAdapterTests.swift`. The `RecordingSink` captures every `BusOutbound` envelope; tests destructure them via `case let .toolCallStart(id, name, argsPreview)` and assert `name == "run_applescript"`, `argsPreview == "{\"awaitingApproval\":true}"`. Content-bearing.
  - `test_emitToolCallEnd_idMatchesStart` (line 91) asserts the **stable UUID equality** between start and end emissions — that's the actual HUD-reconciliation contract. Not a count, not a presence check, the actual semantic invariant.
  - `test_updateArgsPreview_reEmitsStartWithSameId` (line 122) similarly asserts the patched-card invariant.
  - `test_nilBatcher_dropsEventSilently` (line 155) is the one test in this file with no assertion ("must not throw or trap"). It's flagged in the comment as intentional; legit pattern given the contract is "fail closed silently when batcher not yet built", but borderline.
  - This file is the textbook fix to the SpyBus / NoopBusGateway divergence pattern flagged in 2026-05-03 §6.

## Pre-existing tests — issues found

### Tautological / vacuous

A clean tree has **zero `XCTAssertTrue(true)` and zero `#expect(true)` literal tautologies remaining** — `08125a4` removed all five flagged in the prior audit. The only remaining matches are *comments* explaining what was removed (e.g., `App/Tests/AppTests/AppDelegateWiringTests.swift:107`, `packages/Vision/Tests/VisionTests/PackageBoundaryTests.swift:18`). Good cleanup.

Pre-existing tautological *patterns* (assert literal A equals literal A in source):

- **`HudStateEnumTests.test_bootingAndReconfiguringLabelsMatchSpec`** (`App/Tests/AppTests/HudStateEnumTests.swift:31`) — `XCTAssertEqual(HudState.booting.voiceOverLabel, "Jarvis, starting up")`. Source string compared to test string. Cleanup batch comment says "rubber-stamps left as-is (a11y labels are user-facing, load-bearing)". Plausible defense — these are localizable strings that ship to VoiceOver — but as written they cannot fail under any user-visible regression because the test string is just a copy of the source string. To make this load-bearing, snapshot the rendered label or assert against an external locale resource. Flag, not actionable today.
- **`HudStateEnumTests.test_existingLabelsPreservedFromPhase1`** (line 36) — same pattern, five times in a row.
- **`HudStateEnumTests.test_switchOnHudStateIsExhaustive`** (line 44) — Swift's compiler enforces exhaustiveness on a switch with no `default`. The test body adds zero verification beyond what compilation already proves. Comment acknowledges this ("compile-time contract"). Either delete or upgrade to "the switch produces a stable rawValue for each case".
- **`MenuBarIconControllerTests`** (`App/Tests/AppTests/MenuBarIconControllerTests.swift:66-69`) — repeats the same source-string-equals-test-string pattern for HudState labels. Same caveat.

### Mocked-without-asserting

- **`MCPBusGatewayAdapterTests.test_nilBatcher_dropsEventSilently`** (line 155) — three calls, zero assertions, comment "the call must not throw or trap". Acceptable but borderline; the contract IS "no crash" so there's no other shape, but consider asserting `sink.sent.isEmpty` once a sink is materialized.

- **`MCPRuntimeWiringTests.test_replayRecordingSink_writeThrough`** (`App/Tests/AppTests/MCPRuntimeWiringTests.swift:235-269`) — comment is unusually honest:
  > "we don't have a public reader; the implicit assertions are: (a) `try await Task.sleep` does not throw, (b) `await drainTask.value` returns"
  Final assertion `XCTAssertTrue(drainTask.isCancelled == false)` is checking a debug invariant, not the actual behavior under test (which is "the two writes landed in the DB"). The comment defers DB fixity to `ReplayLogTests`. Honest about its uselessness, which is better than the prior `XCTAssertTrue(true)` it replaced — but the seam between this test and `ReplayLogTests` means a regression where the channel drops the envelope before reaching the DB would trip neither test. Worth a follow-up: open a public reader for the test, or assert the channel's emitted-count snapshot.

- **`AppDelegateBusWiringTests.swift:72-77`** — three `XCTAssertNotNil(delegate.hudPanel)`, `XCTAssertNotNil(delegate.webviewBridge)`. Property-existence tests after `applicationWillFinishLaunching`. Reasonable as smoke checks; would not detect "the bridge is constructed but the bus is not armed".

- **`MenuBarIconControllerTests.swift:61`** — `XCTAssertNotNil(settings)` then `XCTAssertFalse(settings!.isEnabled)`. The NotNil is the prerequisite for the subsequent meaningful assertion; fine.

### Hardcoded sleeps / flaky timing

Quick triage of every `Task.sleep` in tests:

- **`MemoryExtractionOrchestratorTests`** uses 200ms / 250ms / 300ms / 800ms sleeps to wait for drain (lines 170, 261, 296, 325, 358, 370, 405, 467, 498). Most are documented ("wait for drain") and the bound is comfortable for the underlying `TimedMockProvider` 50ms-per-call latency. Could be replaced with cooperative polling like `RememberBrutusEndToEndTests` does, but not flake-prone today.
- **`VADGatedSessionTests.swift:84`** — `Task.sleep(for: .milliseconds(300))` for "pump deliver + VAD process + hangover counter trip + submit to land". Good comment. 300ms is comfortable.
- **`VoiceLoopE2ETests`** — 80ms / 120ms / 40ms / 80ms / 20ms / 80ms. The 20ms wait at line 195 before `pttUp` is the tightest; in a heavily loaded CI this could occasionally fail to deliver any chunks before pttUp closes the session. Acceptable in practice (test flake hasn't been reported).
- **`MCPRuntimeWiringTests:48`** — `try? await Task.sleep(nanoseconds: 1_000_000)` (1ms) inside a polling loop. Cooperative; fine.
- **`MCPRuntimeWiringTests:252`** — `Task.sleep(nanoseconds: 300_000_000)` (300ms) before `endTurn`. Documented as "Allow drain + ReplayLog batch flush". Fine.

No tests with sub-50ms hardcoded sleeps that look like guesses. The 2026-05-03 audit's flake concern is not present in today's additions.

### Coverage holes at critical boundaries

1. **`LiveSpeechAnalyzerBridge`** (`packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:176`) — the macOS 26 SpeechAnalyzer body has zero unit-test coverage. PCMBufferBuilder is well-tested (`PCMBufferBuilderTests`), but the bridge that opens the SpeechAnalyzer + AsyncStream pipe + result-drain Task is HUMAN-UAT only. The new VoiceLoopE2E tests' comment at line 29 explicitly disclaims this: "Real macOS 26 SpeechAnalyzer. Covered by LiveSpeechAnalyzerBridge's internal wiring (Track B-4) — exercised in HUMAN-UAT, not unit tests." This is the single largest hole in the suite.

2. **Production `chunkPump` closure at `App/AppDelegate.swift:892-922`** — the actual-shipped pump (subscribe via `audioGraphOwner.subscribe()`, read via `RingBuffer.readMono16k(into:)`, 1024-frame windowing, 10ms-on-starve loop, finish on cancel + unsubscribe) is **not exercised by any test**. Every test that drives a chunk pump (E1/E2/E3 in VoiceLoopE2ETests, VAD-1/2/4/5 in VADGatedSessionTests) constructs a synthetic `chunkPump` closure that bypasses the production one. This is structurally identical to the SpyBus / NoopBusGateway divergence that produced BLOCKER-INT-1 — test wires the test seam, production wires the real pump, only the latter ships. Recommended: extract the production pump to a static factory method (e.g., `AppDelegate.makeProductionChunkPump(audioGraphOwner:)`) and write a test that drives it against a real `BufferBroadcaster` with a known buffer pre-loaded.

3. **`BufferBroadcaster.publish` from a real Core Audio thread** — BB-5 stress test runs publishers as `Task.detached`, which is **not** a real-time tap thread. A test that fakes the tap-thread context (e.g., `DispatchQueue` with realtime QoS) and verifies no `os_unfair_lock` contention or actor-hop accidentally introduced would catch a future "added a `Task { ... }` to publish" regression that BB-5 would silently pass. Lower priority than the pump and bridge gaps.

4. **`MemoryExtractionOrchestrator.priorFacts` lookup error path** — `testD3_priorFactsLookupErrorDegradesToEmpty` covers the happy "lookup throws → degrade to empty" path. The further question — "lookup hangs, does the drain task have a timeout / does it block the queue forever?" — is not tested. The orchestrator's source should be checked for whether the lookup is awaited unconditionally; if so, that's a latent bug.

5. **End-to-end tool-call card flow** orchestrator → `MCPBusGatewayAdapter` → `OutboundBatcher` → real WKWebView → JS-side `upsertToolCall`. The new `MCPBusGatewayAdapterTests` cover up to OutboundBatcher.Sink (good); the JS-side is covered by `webview/packages/hud/tests/streaming.test.tsx D5/D5b` (per the comment). No single test crosses both boundaries. The two-layer split would not have caught a regression where the Swift envelope encoding diverges from the JS-side decoder. Recommendation: extend `RealWKWebViewIntegrationTests` to drive a real tool-call start → end through the adapter and assert the JS-side store reconciles.

6. **`MCPBusGatewayAdapter` resolveBatcher late-binding race** — the test exercises "resolver returns nil" and "resolver returns batcher", but not "resolver returns nil for the start emission then returns batcher for the end emission". That race is the kind of thing that could ship and only surface under cold-launch jitter. Low priority.

## Pre-existing failures triage

### `TTSInterruptTests.testI3_completionTimeoutRespected` — 10s deterministic block

**File:** `packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift:109`.

**Symptom (per SESSION-STATE):** `XCTAssertLessThan failed: ("10.4...") is not less than ("0.08")`. The 80ms timeout assertion fails because `InterruptSequence.run` actually takes ~10s.

**Root cause:** `InterruptSequence.run` (`packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift:60`) does:
1. `await engine.hasSynthInFlight` (suspends to enter the actor — should be fast under reentrancy)
2. `await engine.cancel()` (`TTSEngineActor.swift:192`) — this awaits `taskToCancel?.value` after cancelling the outer Task.

The outer Task body calls `try await orpheusActor.synthesize(text, voice: voice, into: sink)` which iterates `model.makeStream(...)`. `ScriptedSpeechModel.makeStream` (`OrpheusSerializationTests.swift:155`) is:

```swift
return AsyncThrowingStream { continuation in
    Task {
        for i in 0..<count {
            try await Task.sleep(for: d)
            try Task.checkCancellation()
            continuation.yield(.token(i))
        }
        ...
    }
}
```

The detached `Task { ... }` inside the stream's makeStream closure is **not a child task of the outer cancellation chain**. Cancelling the outer TTSEngineActor task cancels the `for try await event in stream` loop in `OrpheusTTS.synthesize`, but the stream's own producer Task continues until it hits its own `Task.checkCancellation()` — which it never does, because *it* never received the cancellation signal. The stream object's `cancel`/`onTermination` would propagate, but a generic `AsyncThrowingStream { Task { ... } }` doesn't connect the consumer's cancellation to the producer Task. The producer runs to completion (100 tokens × 100ms = 10s), at which point the outer `cancel` call's `try? await taskToCancel?.value` finally returns.

**Triage recommendation:** This is a **test-fixture bug, not an InterruptSequence bug**. `ScriptedSpeechModel.makeStream` should propagate cancellation by either (a) using `continuation.onTermination = { @Sendable _ in producerTask.cancel() }` or (b) capturing a `Task` handle and tying it to the continuation. Fix is local to `OrpheusSerializationTests.swift:155-170`. Once the producer Task is cancelled when its consumer drops, the I3 timeout test will pass. The `InterruptSequence` itself is correct (the 20ms timeout is enforced by the task-group race at line 87).

The pre-existing 10s timeout has been silently signalling "the test fixture doesn't model the production cancellation contract", which is exactly the failure mode the user complained about — except this time the test is actually red, just pre-existing.

### `InputMonitoringDenialTests` compile failure

**File:** `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift:6`.

**Root cause:** `MockProbe` conforms to `HIDAccessProbe` but is missing the protocol's `isListenEventAccessGranted() -> Bool` requirement (added at `packages/Shell/Sources/Shell/InputMonitoringProbe.swift:15`).

```
error: type 'InputMonitoringDenialTests.MockProbe' does not conform to protocol 'HIDAccessProbe'
note: protocol requires function 'isListenEventAccessGranted()' with type '() -> Bool'
```

**Minimal fix:** add the missing method to `MockProbe`:

```swift
private struct MockProbe: HIDAccessProbe {
    let granted: Bool
    func requestListenEventAccess() -> Bool { granted }
    func isListenEventAccessGranted() -> Bool { granted }   // <-- add this
}
```

This is a 1-line fix. The fact it has been red since at least before today means the Shell package's test target doesn't run in any pre-merge gate; that's a separate process issue worth surfacing.

## Top 5 tests to strengthen first

1. **Add `LiveSpeechAnalyzerBridge` unit tests.** The bridge body in `packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:176` is the most-load-bearing-and-least-tested code in the project. Even one test that constructs the bridge, feeds 5 PCM buffers via `feed(_:)`, and asserts the result-drain Task surfaces a partial would close the gap. Gate on `@available(macOS 26)`.
2. **Test the production `chunkPump` closure directly.** Refactor `App/AppDelegate.swift:892-922` to a static factory method `AppDelegate.makeProductionChunkPump(owner:)`. Write a test that pre-fills a `BufferBroadcaster.Subscription`'s ring with 4096 samples, runs the pump for 100ms, and asserts the chunks yielded match the buffer content. Catches the SpyBus/NoopBusGateway-shaped regression in voice.
3. **Fix `TTSInterruptTests.testI3` by patching `ScriptedSpeechModel`.** Add `continuation.onTermination = { @Sendable _ in producerTask.cancel() }` to `OrpheusSerializationTests.swift:160`. Restores the I3 timeout invariant; turns a red test green honestly (not by suppression).
4. **Fix the `InputMonitoringDenialTests` compile failure.** One-line addition. Surfaces the broader issue that the Shell package's tests are not in a pre-merge gate.
5. **End-to-end tool-call card flow.** Extend `RealWKWebViewIntegrationTests` (Bus package) to drive a real `MCPBusGatewayAdapter` event through OutboundBatcher → WKWebView → JS-side `upsertToolCall`. Single test that crosses both Swift and JS boundaries and asserts the HUD-side store reconciles by id.

## Things that are actually good

- **`RememberBrutusEndToEndTests.testExtractionWriteThenSearchFindsBrutus`** is a reference example of how to test a pipeline end-to-end with judiciously-faked boundaries. Real `MemoryExtractor`, real `MemoryExtractionOrchestrator`, real `HybridSearch`, fakes only at SQLite and Ollama. Final assertion is content (`hits.first?.summary == "Brutus breed Bernese Mountain Dog"`), not count.
- **`BufferBroadcasterTests`** BB-1 through BB-4 test sample identity, not just count. BB-2's "neither subscriber steals" assertion is the exact contract the broadcaster was added for.
- **`MCPBusGatewayAdapterTests.test_emitToolCallEnd_idMatchesStart`** asserts the *invariant* (start.id == end.id) that the HUD reconciliation relies on — not a presence check, not a count check, the actual semantic contract. The fact that `MCPBusGatewayAdapter.stableUUID(from:)` is exposed as a static for the test to call means the test can verify both halves of the contract independently.
- **`testD3_priorFactsLookupDrivesUpdateOp`** — the stub provider conditionally emits UPDATE only when it sees `[99]` in the system prompt, so the test fails if priorFacts is wired but the prompt-rendering is broken. The provider doesn't just trust the orchestrator's instrumentation; it exercises the actual prompt path.
- **`CameraCaptureRealHardwareTests`** is an exemplar of the gating pattern: triple-gated (env + device + TCC), explicitly does NOT call `requestAccess` so headless runs never hang, content-bearing assertions (`> 1000` bytes, SOI marker, dimensions > 1) that would trip a regression to the historical 125-byte 1×1 stub immediately.
- **The 2026-05-04 cleanup batch (`08125a4`)** removed all five flagged `XCTAssertTrue(true)` tautologies and replaced them with either honest behavioral assertions or deletion. No new ones have been introduced. That's a meaningful improvement to the suite's signal-to-noise.
