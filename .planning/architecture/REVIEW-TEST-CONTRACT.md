# Review: Test Contract Feasibility — v0.1
**Reviewer:** Test-feasibility critic (swarm phase 3c, parallel with 3a/3b)
**Target:** JARVIS-API-DESIGN-v0.1.md
**Date:** 2026-05-07

## Summary

**Verdict: mostly-testable-with-named-gaps.** v0.1 is the right shape — typed Result returns, `TurnID` as universal correlation key, Queries to hydrate state on connect, and named error enums per Command. These are sufficient seams for ~70% of operations to be fully testable through the API alone, and they directly dissolve the *signature* of B-02..B-08 (silent void / silent false / unobservable side effects). However, the design punts five categories of testability that, if not addressed before v1.0, will reproduce the bug class on a different axis: (1) the Voice surface has no synthetic-audio injection seam, so B-04 cannot be reproduced by the harness without a real microphone; (2) there is no clock seam, so all `timeoutSeconds` / 5-second frame-attach window / hangover / 2 s handshake / 16 ms batcher operations require either real `Task.sleep` or a hidden `@testable` backdoor; (3) TCC denial scenarios have events but no way for tests to *force* a denial transition; (4) v0.1 talks about events being "delivered in order" but never specifies a transport-level test seam (the harness has to choose between `WKScriptMessageHandler` round-trips and direct actor calls, and the contract doesn't say); (5) B-06 (chat auto-scroll) is explicitly deferred to "headless webview"-class tests, which the existing harness has zero infrastructure for. **Top 3 testability concerns:** no synthetic audio injection (Voice surface), no clock injection (every timeout-bearing operation), no transport-equivalence proof (does API behave identically through actor-call vs WKWebView round-trip?).

## Per-surface testability scorecard

| Surface | Operations | Testable | Partial | Not testable | Notes |
|---|---|---|---|---|---|
| Turn | 4 cmd / 11 evt / 2 qry = 17 | 14 | 2 | 1 | `tokenStreamed` deterministic with MockLLMProvider; `confirmation*` testable via in-process tools; `respondToConfirmation` timeout case requires clock seam (partial); B-06 scroll is webview-DOM only (not testable through API) |
| Voice | 8 cmd / 9 evt / 1 qry = 18 | 6 | 7 | 5 | `startVoice`/`audioLevelChanged`/`wakeWordDetected`/`sttTranscript*`/`ttsStarted`/`ttsEnded` ALL require real audio or a synthetic frame injector that v0.1 does not specify; `voiceDegraded` reasons are not all triggerable |
| Memory | 1 cmd / 2 evt / 2 qry = 5 | 4 | 1 | 0 | Hybrid search requires `nomic-embed-text` via Ollama — only `JARVIS_REAL_MODELS=1` path; FTS-only path testable with stub embedder |
| Vision | 2 cmd / 4 evt / 1 qry = 7 | 3 | 3 | 1 | `frameExpired` (5 s timer) needs clock; `cameraDegraded` needs forced TCC denial; raw frame bytes never cross API boundary so frame *content* untestable |
| Settings | 6 cmd / 1 evt / 1 qry = 8 | 7 | 1 | 0 | `setHotkey.collision` needs a way to simulate competing OS bindings; `storeAPIKey.validationFailed` requires Anthropic round-trip unless `AnthropicKeyValidator` has a stub seam |
| Diagnostics | 2 cmd / 3 evt / 2 qry = 7 | 6 | 1 | 0 | `copyStateDump` writes to NSPasteboard (host-side) — clipboard inspection requires native test |
| Self | 0 cmd / 2 evt / 4 qry = 6 | 4 | 2 | 0 | `tccStatusChanged` cannot be forced from a test; `listAudioDevices` returns hardware-derived data; `getActiveAudioRoute` depends on running audio graph |

**Totals: 44 testable / 17 partial / 7 not-testable out of 68 operations.**

## Gap inventory

### G-001: Voice surface has no synthetic audio injection seam
**Severity:** BLOCKING
**Category:** hardware
**Operations affected:** `Voice.startVoice`, `Voice.audioLevelChanged`, `Voice.wakeWordDetected`, `Voice.sttTranscriptPartial/Final`, `Voice.pttDown/pttUp`, `Voice.ttsStarted/ttsEnded`, `Voice.voiceDegraded(reason: .aecUnavailable)`
**Problem:** v0.1 §5.2 specifies that `startVoice()` returns `audioGraphFailed` and that `audioLevelChanged` "must begin emitting within 500 ms of a successful startVoice()" (per the B-04 dissolution claim in §7), but there is no API command for the harness to *inject* PCM frames or VAD-segmented audio. `VoiceLoopE2ETests` already does this internally via the `chunkPump:` initializer parameter on `VoiceController`, but that is `@testable import Voice` — a backdoor, not part of the API contract. Without an injection seam at the v0.1 boundary, the harness cannot reproduce B-04 by exercising the API alone. Same problem for STT (no way to feed transcripts), wake-word (no way to trigger detection from a fixture), TTS (no way to observe synthesized audio output without a speaker).
**Suggested seam:** Voice surface gains four test-only commands behind `#if HARNESS` or a runtime `harnessMode` flag set at boot:
- `Voice._injectAudioFrame(pcm: [Float], sampleRate: Int)` — feed the audio graph
- `Voice._injectWakeWordDetection(confidence: Float)` — bypass the DAG
- `Voice._injectSTTTranscript(text: String, isFinal: Bool)` — bypass the STT provider
- `Voice._observeTTSAudio() -> AsyncStream<TTSSynthesisRecord>` — capture without speaker output (record `{turnId, tier, durationMs, sampleCount, started, ended}` but never emit PCM beyond the boundary)

The existing `MockTTSForController`, `CapturingSTTProvider`, `MockVADEngine` doubles in `VoiceTests/` should be rehoused as harness-public types so the harness can compose them without `@testable`.
**Acceptable workaround:** real-hardware path follows existing `JARVIS_REAL_CAMERA=1` convention with new `JARVIS_REAL_AUDIO=1` flag. But this only covers smoke tests, not the regression corpus.

---

### G-002: No clock injection across the API
**Severity:** BLOCKING
**Category:** time
**Operations affected:** `Turn.confirmationRequested.timeoutSeconds` (default 30s), `Vision.requestFrameAttach.expiresAt` (5s window → `frameExpired`), `Voice.audioLevelChanged` (~30 Hz cadence assertion), VoiceState 320ms wake-word hysteresis, OutboundBatcher 16 ms coalescing window, handshake 2 s timeout, Anthropic 1h cache TTL behavior, retryTurnId after `streamTruncated`.
**Problem:** v0.1 §3 / §5 quote concrete time values but never expose a `Clock` parameter. The only existing seam is `DevSnapshotEmitter`'s `clock: ContinuousClock = .continuous` parameter, which is internal. Without a clock seam at the API boundary, every test that asserts on a timeout *must* use real `Task.sleep`, blowing test runtime up and adding flake. Worse: any test that needs to assert "frameAttach expired after 5 s" cannot do so without a real 5 s wait.
**Suggested seam:** Add `Clock` (Swift `Clock` protocol or `ContinuousClock`-shaped `ClockProvider` protocol) injection at every surface init. v0.1 should add a top-level type:
```swift
public protocol APIClock: Sendable {
  var now: Date { get }
  func sleep(until: Date) async throws
  func sleep(seconds: Double) async throws
}
```
…with `RealClock` (production) and `ManualClock` (harness) implementations. Then `Turn`, `Voice`, `Vision`, and the `OutboundBatcher` accept `clock: APIClock` at construction. Tests advance the clock manually: `await clock.advance(seconds: 5.1)` → frame expires → `frameExpired` event must fire deterministically. This is a one-paragraph addition to v0.1 §3 and a constructor parameter on each surface — small surface change, enormous testability win.
**Acceptable workaround:** none. Real-time tests are flaky-by-construction for sub-second windows and prohibitive for 30 s confirmation timeouts. This must land before v1.0.

---

### G-003: TCC denial transitions cannot be forced from tests
**Severity:** HIGH
**Category:** TCC
**Operations affected:** `Self.tccStatusChanged` (all 5 permission types), `Voice.startVoice → microphonePermissionDenied`, `Voice.pttDown → inputMonitoringDenied`, `Vision.requestFrameAttach → cameraPermissionDenied`, `Settings.setHotkey → inputMonitoringDenied`, `Voice.voiceDegraded(reason: .microphoneRevoked)`
**Problem:** TCC status is sourced from `AVCaptureDevice.authorizationStatus`, `IOHIDRequestAccess`, and macOS speech-recognition assets — all read from real OS state. v0.1 specifies these as observable Events but provides no harness command to drive `tccStatusChanged(permission: .microphone, granted: false)` synthetically. Today's `CameraCaptureRealHardwareTests` *requires* real grant; there is no test that proves "denied" path emits the right error and degraded banner.
**Suggested seam:** Add a `Self._forceTCCStatus(permission: TCCPermission, granted: Bool)` test-only command behind harness-mode gating. Internally this updates the `SelfStateAdapter`'s cached state and re-emits `tccStatusChanged`; the downstream subsystems (Voice, Vision) re-probe their own state and emit appropriate Degraded events. This is the test-substitute for swizzling AVCaptureDevice — explicit, intentional, recorded in the API contract.
**Acceptable workaround:** maintain a `JARVIS_TCC_DENIED_MIC=1` style env-flag suite that runs on a host with mic TCC denied. Doesn't scale to the 4×2 = 8 grant/deny combinations across the four critical permissions.

---

### G-004: External-service stubbing not specified at the API boundary
**Severity:** HIGH
**Category:** external-service
**Operations affected:** `Settings.storeAPIKey` (calls Anthropic for validation), `Turn.submitTurn` with provider=anthropic (calls Anthropic streaming), `Memory.searchFacts` (calls Ollama for embeddings), `Memory.factMutated` extraction path (calls Ollama for ADD/UPDATE/NOOP), `Self.selfStateChanged.modelId` validation (round-trips a key)
**Problem:** v0.1 lists `Settings.setProvider` and `Self.getSelfState.provider` but never specifies how the harness substitutes a fake provider. Today, `MockLLMProvider` is constructed at the orchestrator-internal level and routes through `URLProtocol`-stubbed `URLSession` — that's deep wiring, far below the API surface. The new contract needs an explicit boot-time injection: when the harness starts the host process, it must be able to say "all Anthropic traffic resolves to fixture X" without monkey-patching internals.
**Suggested seam:** v0.1 adds a top-level `JarvisHost.init(transportConfig:, providerOverrides:)` where `providerOverrides` is `{anthropic: LLMProvider?, ollama: LLMProvider?, ollamaEmbedder: EmbeddingProviding?}`. Production passes nil → real providers; harness passes `MockLLMProvider(fixtureURL:)`. This makes the substitution part of the API contract instead of a hidden test convention. Anthropic 429, refusal, streamTruncated, and partial_tool_use_at_disconnect all become triggerable by curating the fixture corpus.
**Acceptable workaround:** `JARVIS_REAL_MODELS=1` for live integration; matches existing convention but only smoke-tests the happy path.

---

### G-005: Cannot trigger every error variant — many are aspirational
**Severity:** HIGH
**Category:** errors
**Operations affected:** `TurnRejected.providerUnavailable`, `TurnErrorCode.streamTruncated/.refusal/.maxTokensExceeded`, `VoiceStartError.audioGraphFailed`, `PTTError.voiceNotRunning`, `ConfirmationError.timedOut`, `FrameAttachError.alreadyArmed`, `APIKeyError.keychainWriteFailed`, `HotkeyError.bindFailed`, `Voice.voiceDegraded(reason: .aecUnavailable/.aecRestored)`
**Problem:** v0.1 names 30+ error variants per surface but does not specify which can be programmatically triggered. Several require real OS/network conditions (keychain failure, bind failure, AEC unavailable, provider unavailable). Without trigger paths, these are documentation, not contract.
**Suggested seam:** Each surface gets a `_forceError(operation: String, code: String)` debug command behind harness gating. Wire into the same code paths that production uses — e.g., `Voice._forceError("startVoice", "audioGraphFailed")` makes the next `startVoice()` call fail at the audio-graph build step with the canonical reason string. Cheaper alternative: pass an `ErrorInjector` collaborator at `JarvisHost.init` that subsystems consult before each fallible operation.
**Acceptable workaround:** mark each error variant in v0.1 with `[trigger: real-only]` / `[trigger: harness-injectable]` / `[trigger: not-yet-triggerable]`. At least the contract is honest about coverage.

---

### G-006: B-06 (chat auto-scroll) is not API-testable; v0.1 admits this
**Severity:** MEDIUM
**Category:** scenarios / observability
**Operations affected:** `Turn.tokenStreamed`, the absent `Turn.turnTextComplete` (Q-4)
**Problem:** v0.1 §7 B-06 says "the harness cannot fully verify DOM behavior, but the API provides the scroll-anchor contract." That is a gap, not a dissolution. The original bug class is "wired but dead" — B-06 fits perfectly: the webview ignores the contract and the Swift side has no observability into whether the scroll happened.
**Suggested seam:** Resolve Q-4 as YES — add `Turn.turnTextComplete(turnId:fullText:)` as a server-emitted event. Harness can then assert ordering: `tokenStreamed* → turnTextComplete → turnEnded`. The webview's scroll obligation is verified by a separate `WebviewClientReply.scrollAnchored(turnId)` round-trip event the webview emits when it has scrolled. Pair: contract-side event + ack-side event = end-to-end testable. Without an ack from the webview, B-06 stays in the "passes unit tests, ships broken" category.
**Acceptable workaround:** maintain a separate Playwright/headless-WKWebView suite for DOM-scroll assertions. Not part of the Swift harness.

---

### G-007: Transport equivalence is not specified
**Severity:** HIGH
**Category:** observability / scenarios
**Operations affected:** all 68 operations
**Problem:** v0.1 §3 says "test harness substitutes a different transport (direct Swift actor call or IPC)" but never specifies that the API must behave identically across transports. The whole pivot's premise — "tests via the API will catch what unit tests miss" — depends on the in-process actor-call API behaving the same as the JSON-over-WKScriptMessageHandler API. If the harness only tests actor-call, B-03-class bugs (webview emit lost en route to AppDelegate) remain invisible.
**Suggested seam:** v0.1 adds a §3.4 "Transport Equivalence" section requiring every harness scenario to be runnable in two modes — `transport: .inProcessActor` and `transport: .jsonRoundTrip` (drives a real WKWebView, encodes Commands as JSON, reads Events back through the message handler). The harness library exposes a `TransportMode` enum and a single test asserts every scenario passes both. Existing `RealWKWebViewIntegrationTests` in `packages/Bus/Tests/` is the substrate for the JSON path; it just needs to be lifted from a one-off to a parametric runner.
**Acceptable workaround:** declare the JSON transport out of scope for the harness and rely on `check-bus-harness-parity.sh` (already a boundary gate) for byte-shape parity. Risk: parity script is grep-based, not behavioral — it can't catch "frameAttachRequested arrives but is dropped."

---

### G-008: `replayLog` access is not in the API
**Severity:** MEDIUM
**Category:** observability
**Operations affected:** all replay-oracle scenarios; B-02 verification specifically
**Problem:** v0.1 §6 says "harness reads replay file directly for oracle checks." That's a backdoor outside the API. Many B-02..B-08 dissolutions read like "the harness asserts X is in the replay log" — but if the replay log is not part of the API, the contract is being smuggled through a side channel. Worse, the file may not be flushed when the test inspects it (race with `FileLogHandler` rotation).
**Suggested seam:** Add `Diagnostics.streamReplayEvents(filter:) -> AsyncStream<ReplayEvent>` and `Diagnostics.snapshotReplayEvents(turnId:) -> [ReplayEvent]`. Harness reads from these, not the file. v0.1 already commits to replay events as internal — promote them to a documented Diagnostics surface (still gated as "diagnostic only", not for clients).
**Acceptable workaround:** harness-internal `ReplayLogReader` helper that handles flush + tail. Not a contract.

---

### G-009: `OutboundBatcher` 16 ms window leaks nondeterminism past the API
**Severity:** MEDIUM
**Category:** nondeterminism
**Operations affected:** all Events delivered through the webview transport — `tokenStreamed`, `audioLevelChanged`, `toolCallStarted/Updated`, `hudStateChanged`
**Problem:** v0.1 §3 mentions "the OutboundBatcher coalesces sends within a 16ms window; ordering within a turn is preserved." But coalescing collapses N events into 1 batch unpredictably depending on real-clock timing. If a test asserts "exactly 5 `tokenStreamed` events arrived for prompt X," the batcher may deliver them as 5, 3, 2, or 1 batched delivery — depending on test scheduler load.
**Suggested seam:** Two options, pick one.
1. Define batcher behavior as part of the API contract: "events within a coalescing window are delivered as a single ordered array; clients receive the array, not individual elements." Tests assert on flat-mapped events, batch boundaries are unobservable.
2. Replace real clock with `APIClock` (G-002) so batcher window is deterministic. Tests advance clock past 16 ms to force a flush.

Either is fine. Picking neither leaves the API leaking non-determinism.
**Acceptable workaround:** harness flat-maps batches and asserts on the ordered event sequence, ignoring batch boundaries. Document this as a harness convention.

---

### G-010: Fact extraction nondeterminism
**Severity:** MEDIUM
**Category:** nondeterminism / external-service
**Operations affected:** `Memory.factMutated` (op = ADD/UPDATE/NOOP)
**Problem:** Whether a turn produces a `factMutated(op: .add)` vs `.noop` is decided by the local Qwen 2.5-Coder 32B extractor, which is a probabilistic LLM. Tests cannot assert "after this turn, fact X exists" without either pinning extractor output (fixture) or running real Ollama.
**Suggested seam:** Same as G-004 — `providerOverrides` must include `memoryExtractor: MemoryExtracting?` so tests can substitute a deterministic extractor that emits canned `MemoryOp`s based on a turn-text → ops map. Most B-02 regression scenarios don't need real extraction; they need "after `Turn N` fact F is in store; after `Turn N+1` fact F is updated."
**Acceptable workaround:** all memory-extraction tests gated `JARVIS_REAL_MODELS=1`. Existing `MemoryRegressionCorpusTests` already follows this. Harness regression suite skips fact-content assertions.

---

### G-011: Confirmation timeout path requires clock + matching seam
**Severity:** MEDIUM
**Category:** time / errors
**Operations affected:** `Turn.confirmationRequested.timeoutSeconds`, `Turn.respondToConfirmation` returning `ConfirmationError.timedOut`, `Turn.confirmationResolved(outcome: .timedOut)`
**Problem:** Default confirmation timeout is 30 s. Without G-002 clock injection, the only way to test the timeout path is `Task.sleep(31)`. Compounds with G-005 (`ConfirmationError.timedOut` is one of the not-triggerable variants).
**Suggested seam:** subsumed by G-002 + G-005.
**Acceptable workaround:** test-only override of confirmation timeout to 100 ms via a hidden Settings field. Cheap but smells.

---

### G-012: Boot-state observability is asymmetric
**Severity:** MEDIUM
**Category:** observability
**Operations affected:** `Self.selfStateChanged` (boot), wizard stage exposure, hard-block scenarios
**Problem:** v0.1 §3 says hard-block "terminates" on version mismatch. But the harness needs to *observe* the hard-block, not be killed by it. Today's code calls `NSAlert.runModal` directly (`Shell.TCCAlertService.presentHardBlock`) — there is no event the harness can subscribe to that says "hard-block fired with reason X."
**Suggested seam:** Replace direct AppKit hard-block with `Diagnostics.hardBlockTriggered(reason: HardBlockReason)` event followed by `JarvisHost.terminate()` after a 1 s delay. Harness subscribes, asserts the event fired, then synthetically terminates. Production behavior unchanged from user POV.
**Acceptable workaround:** none — current design has the harness watching a process exit code, which loses the reason.

---

### G-013: Cross-surface scenario correlation is `TurnID`-only; insufficient for confirmations across multiple tools
**Severity:** LOW
**Category:** scenarios
**Operations affected:** scenarios spanning `Turn.confirmationRequested` × `Memory.factMutated` × `Voice.ttsStarted`
**Problem:** `TurnID` correlates across surfaces, but a single turn may have multiple confirmations (e.g., AppleScript + forget_fact in the same turn). The harness scenario "submit voice turn → tool A asks confirmation → user approves → tool B asks confirmation → user denies → assistant speaks" needs `ConfirmationID` correlation across `confirmationRequested` and `confirmationResolved`. v0.1 does carry `confirmationId`. Confirm: this works for parallel confirmations, but the API doesn't guarantee ordering across multiple confirmations within one turn. If tool A and tool B both request in the same orchestrator step (parallel tool_use), which `confirmationRequested` arrives first?
**Suggested seam:** v0.1 §5.1 explicitly states "Confirmations within a single turn are emitted in tool-call dispatch order; harness can rely on event ordering." One-line clarification, not a structural change.
**Acceptable workaround:** harness asserts on set membership rather than order for parallel confirmations.

---

### G-014: Image bytes don't cross the API but are part of the contract
**Severity:** LOW
**Category:** observability
**Operations affected:** `Turn.submitTurn(images:)`, `Vision.frameSent`, B-03 reproduction
**Problem:** v0.1 says "image bytes never cross the API" (§6 mapping for `ImageBlock`). Good for security. But the harness needs to *prove* a frame was sent — not its bytes, but that the orchestrator's outbound LLM call included an image block. Today this is `MockLLMProvider`'s message-array assertion, but only with `@testable import`.
**Suggested seam:** the harness's `LLMProvider` substitute (G-004) records each call's `images: [ImageBlock]` length and dimensions in a `Diagnostics`-readable trace. Harness queries `Diagnostics.lastLLMCall.imageCount > 0`. Image content remains opaque.
**Acceptable workaround:** rely on `frameSent(turnId:)` event; trust orchestrator wires it correctly. Doesn't catch a regression where the event fires but the LLM call has no image.

---

### G-015: Wake-word hysteresis (4-frame, 320 ms) has no test affordance at the API
**Severity:** LOW
**Category:** time / hardware
**Operations affected:** `Voice.wakeWordDetected`
**Problem:** Existing `WakeWordHysteresisTests` and `WakeHysteresisRunner` exercise the DAG directly, but only via `@testable`. v0.1 surfaces only `wakeWordDetected(confidence: Float)` — no way to see the underlying frame queue or threshold state.
**Suggested seam:** subsumed by G-001 audio injection + G-002 clock. With both, the harness feeds 3 frames → no detection event; feeds 4th → detection fires. Without both, this test stays at the substrate layer.
**Acceptable workaround:** retain `WakeHysteresisRunner` as a harness-internal substrate test gated on real ONNX model. Document that wake-word hysteresis is verified at the substrate layer, not the API layer.

---

### G-016: `replay` source lacks a contract for replay-roundtrip determinism
**Severity:** LOW
**Category:** scenarios
**Operations affected:** `Turn.submitTurn(source: .replay)`
**Problem:** v0.1 mentions `TurnSource.replay` and `replayTurn(turnId:)` as Q-3. Replay roundtrip is a key oracle (re-running the same input must produce the same output sequence modulo nondeterministic surfaces). v0.1 doesn't specify which surfaces are part of the determinism contract.
**Suggested seam:** Add §3.5 "Replay Determinism." States: given identical fixture providers, `Turn.submitTurn(source: .replay)` produces identical `turnStarted → tokenStreamed* → toolCallStarted/Updated/Ended → turnEnded` event sequences modulo: timestamps, durations, batch boundaries. Memory mutations are part of the determinism contract iff `memoryExtractor` is overridden.
**Acceptable workaround:** declare scope at harness level rather than API level.

---

## Harness shape recommendation

Based on the gap inventory, the harness library lives at `packages/Harness/Sources/Harness/` (existing) but expands its contract surface. Recommended top-level types:

```swift
public actor JarvisTestHarness {
  public init(
    transport: TransportMode,                  // .inProcessActor | .jsonRoundTripWebView
    clock: APIClock,                           // (G-002) usually ManualClock for unit tests
    providerOverrides: ProviderOverrides,      // (G-004) anthropic/ollama/embedder/extractor doubles
    errorInjector: ErrorInjector?,             // (G-005)
    tccOverrides: [TCCPermission: Bool]?       // (G-003)
  ) async throws

  // Surface accessors mirror v0.1 exactly — every Command/Query is callable;
  // every Event is observable as a typed AsyncStream<Event>.
  public var turn: TurnSurface { get }
  public var voice: VoiceSurface { get }
  public var memory: MemorySurface { get }
  public var vision: VisionSurface { get }
  public var settings: SettingsSurface { get }
  public var diagnostics: DiagnosticsSurface { get }
  public var selfSurface: SelfSurface { get }

  // Scenario primitives
  public func observe<E: Sendable>(_ event: KeyPath<Events, AsyncStream<E>>) -> AsyncStream<E>
  public func awaitEvent<E>(matching: (E) -> Bool, timeout: Duration) async throws -> E
  public func awaitTurnEnded(_ turnId: TurnID) async throws -> TurnEnded
  public func snapshotState() async -> JarvisStateSnapshot

  // Test seams (gap-driven)
  public func injectAudioFrame(pcm: [Float]) async   // G-001
  public func injectWakeWord(confidence: Float) async // G-001
  public func injectSTT(text: String, isFinal: Bool) async // G-001
  public func injectTCC(_ permission: TCCPermission, granted: Bool) async // G-003
  public func advanceClock(by: Duration) async       // G-002
}

public enum TransportMode { case inProcessActor; case jsonRoundTripWebView }

public struct ProviderOverrides: Sendable {
  public var anthropic: (any LLMProvider)?
  public var ollama: (any LLMProvider)?
  public var ollamaEmbedder: (any EmbeddingProviding)?
  public var memoryExtractor: (any MemoryExtracting)?
}
```

**Scenarios the harness CAN run (with these seams):**
- All B-02..B-05 + B-08 reproductions; full Turn-surface lifecycle including barge-in, cancel, confirmation, retry, refusal; voice loop with synthetic audio + injected wake/STT; frame-attach happy path + expiry; settings round-trip; replay roundtrip oracle; cross-surface (voice turn → memory mutation → TTS).

**Scenarios it CAN'T run without the listed gaps closed:**
- B-06 (DOM scroll — needs Playwright-class infra; out of scope)
- Anthropic 1h cache TTL behavior end-to-end (needs real key + real cache hit; gated suite)
- Real-mic AEC unavailability (needs real audio device with degraded driver; HUMAN-UAT)
- Hardware enumeration content assertions (`listAudioDevices` returns whatever's on the host)

**Relation to existing `packages/Harness/`:** the existing library's runners (`ToolCapRecoveryRunner`, `WakeHysteresisRunner`, `MCPCrashRunner`, `AudioGraphRebuildRunner`) are substrate-level tests. They become *implementations* of harness scenarios that drive `JarvisTestHarness` rather than the substrate types directly. `MockLLMProvider`'s URL-protocol fixture path is reused as the `ProviderOverrides.anthropic` default for harness scenarios. The corpus folders (`Corpus/`, `Oracle/`) become the harness's scenario library.

## B-02..B-08 reproduction matrix

| Bug | Symptom | Reproducible via API alone? | Scenario | Gap if no |
|---|---|---|---|---|
| B-02 | Conversation continuity lost — "yes" loses prior turn | YES | `submit T1 → assert turnEnded(T1) → submit T2 with "yes" → assert MockLLMProvider.lastCall.messages contains T1.user/T1.assistant` | none — works with G-004 provider override |
| B-03 | Camera button click does nothing | YES (with G-007) | `transport=.jsonRoundTripWebView; click button; assert Vision.framePending arrives within 200 ms` | G-007 (transport equivalence) — without it, in-process call passes while real webview path stays broken |
| B-04 | Voice input dead — wake/STT never fire | YES (with G-001) | `startVoice → injectAudioFrame*15 → injectWakeWord → injectSTT("test", final) → assert turnStarted` | G-001 (audio injection) — without it, only `JARVIS_REAL_AUDIO=1` smoke test |
| B-05 | TTS silent on assistant text | YES (with G-001) | `submit voice turn with mock LLM emitting "hello" → assert ttsStarted(turnId, tier1) within 500 ms of turnEnded` | G-001 — observe-TTS-audio side; without it the assertion is "ttsStarted event fired" which doesn't prove audio was rendered |
| B-06 | Chat panel doesn't auto-scroll | NO | needs DOM observability | G-006 — out of API scope; needs Playwright-class infra |
| B-07 | Voice Log menu item missing | PARTIAL | `assert Diagnostics.getStateDump.fields["voiceLogVisible"] == true after toggle` | depends on Plan 10-05 re-scope; menu item itself is host-UI, not API |
| B-08 | Model paraphrased "Opus 4.5" | YES (probabilistic) | `submit "what model are you" with stub LLM → assert no occurrence of "4.5" in tokenStreamed.text` | structural fix in v0.1 (`modelDisplayName`); soft-failure boundary acknowledged in v0.1 §7 |

**Net:** 5 of 7 fully reproducible via API once gaps G-001 + G-004 + G-007 close. B-06 stays out of scope (correctly; v0.1 admits it). B-07 awaits its plan re-scope.

## Open questions you'd add

- **OQ-T1 — Harness mode at boot vs. always-available test seams?** The injection commands (G-001, G-003, G-005) need a switch: are they `#if HARNESS` (compile-out for production) or runtime-gated (`if processInfo.environment["JARVIS_HARNESS"] == "1"`)? Compile-time is safer; runtime allows shipping a single binary that supports both. Decide before v1.0.
- **OQ-T2 — Does v0.1 commit to test fixture corpus shape?** `MockLLMProvider` consumes `.sse` and `.ndjson` fixtures today. Should v0.1 specify a fixture format for every provider override, or is that purely a harness internal? Argument for in-spec: cross-AI peer review wants to assert the byte-shape contract is testable.
- **OQ-T3 — Coverage requirement per Command/Event?** Should v1.0 mandate "every Command has at least one harness scenario; every Event has at least one assertion path"? If yes, the migration plan needs to enumerate them as acceptance gates per migration step. Without this, the bug class can recur in operations that *exist* in v0.1 but were never wired to a test.
- **OQ-T4 — How does the harness verify "single writer" invariants (state ownership in §4)?** The boundary-gate scripts (`check-single-writer-hudstate.sh` etc.) are grep-based. If the API now claims "Active turn is written only by AgentOrchestrator," should the harness be able to *assert* that property at runtime by tagging writes with origin actor IDs? Or is grep good enough?
- **OQ-T5 — Replay-log access as Diagnostics surface (G-008) or harness-only file read?** Affects whether replay events become part of the API contract or stay implementation detail. v0.1 leans toward the latter; G-008 argues for the former.
- **OQ-T6 — Should `JarvisHost` itself be a typed init returning a Result?** Today's boot path can fail in many ways (entitlement verification, SQLite open, MCP helper crash on launch). v0.1 doesn't specify the host's own construction contract — every harness has to discover boot failures by their downstream symptoms. Add `JarvisHost.boot() async -> Result<JarvisHost, BootError>` so the harness can deterministically test boot failure paths.
