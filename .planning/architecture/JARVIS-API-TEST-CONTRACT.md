# Jarvis API Test Contract — v1.0

**Status:** v1.0 contract locked; harness implementation begins post-Phase-6 (M-0..M-7)
**Date:** 2026-05-07
**Author:** Phase 5 — test contract author
**Inputs:** `JARVIS-API-DESIGN-v0.1.md` + `JARVIS-API-DESIGN-v0.2.md` §5 locked decisions + `REVIEW-TEST-CONTRACT.md` harness shape
**Companion:** Skeleton at `Tools/jarvis-diag/` codifies the harness shape; this document specifies *what scenarios* the harness must run.

---

## 1. Goals & non-goals

### Goals

- **Coverage assertion (OQ-T3 ACCEPT):** every Command in v1.0 has at least one harness scenario that issues it; every Event has at least one assertion path; every Query has at least one round-trip test.
- **B-02..B-08 dissolution proof:** for every carry-forward bug, name (a) the scenario that reproduces it on a pre-fix substrate, and (b) the scenario that proves it stays dead post-migration.
- **Cross-surface correlation:** TurnID-based scenarios that span ≥2 surfaces — the bug class this whole pivot exists to dissolve (silent handoffs between Voice → Orchestrator → TTS, Vision → Orchestrator → LLM, Memory → Orchestrator → next turn).
- **Determinism contract:** identify which scenarios produce identical event sequences on re-run (deterministic) and which depend on stub providers (extractor, LLM) for determinism.
- **Transport equivalence (UQ-5):** every scenario runs in two modes — `.inProcessActor` and `.jsonRoundTripWebView` — proving B-03-class bugs are reproducible without a real user click.
- **Honest error coverage (G-005):** annotate every error variant with `[trigger: harness-injectable | real-only | not-yet-triggerable]`.

### Non-goals

- Does not specify scenario *implementation* — that's the migration plan's call. Skeleton method bodies are `fatalError("not implemented")`.
- Does not redefine the API. v0.1 + v0.2-locked is canon.
- Does not catalog DOM-level webview tests (B-06 stays out of scope per v0.2 R-014 / G-006).
- Does not catalog real-hardware perf benchmarks (TTFA, etc.) — those live in `.planning/evals/` env-flag suites.

---

## 2. Harness architecture (refers to skeleton)

The harness is `JarvisTestHarness` (see `Tools/jarvis-diag/Sources/JarvisDiag/JarvisTestHarness.swift`):

```swift
public actor JarvisTestHarness {
  public init(
    transport: TransportMode,                  // UQ-5 — .inProcessActor | .jsonRoundTripWebView
    clock: APIClock,                           // G-002 — usually ManualClock
    providerOverrides: ProviderOverrides,      // G-004 — anthropic/ollama/embedder/extractor doubles
    errorInjector: ErrorInjector?,             // G-005 — code injection
    tccOverrides: [TCCPermission: Bool]?       // G-003 — synthetic TCC state
  ) async throws

  // Surface accessors — every Command/Query callable, every Event observable.
  public var turn: TurnSurface { get }
  public var voice: VoiceSurface { get }
  public var memory: MemorySurface { get }
  public var vision: VisionSurface { get }
  public var settings: SettingsSurface { get }
  public var diagnostics: DiagnosticsSurface { get }
  public var selfSurface: SelfSurface { get }

  // Scenario primitives
  public func awaitEvent<E>(matching: (E) -> Bool, timeout: Duration) async throws -> E
  public func awaitTurnEnded(_ turnId: TurnID) async throws -> TurnEnded
  public func snapshotState() async -> JarvisStateSnapshot

  // Test seams (only effective when JARVIS_HARNESS=1)
  public func injectAudioFrame(pcm: [Float], sampleRate: Int) async   // G-001
  public func injectWakeWord(confidence: Float) async                 // G-001
  public func injectSTT(text: String, isFinal: Bool) async            // G-001
  public func injectTCC(_ permission: TCCPermission, granted: Bool) async // G-003
  public func advanceClock(by: Duration) async                        // G-002
  public func setConfirmationDefault(_ outcome: ConfirmationOutcome) async // orch-default
}
```

**Test seam gate (UQ-1):** every test seam — both as harness methods and as first-class API ops (`Voice._injectAudioFrame`, `Self._forceTCCStatus`, `Settings._setConfirmationDefault`, `_forceError`, `ProviderOverrides`) — runs only when `ProcessInfo.processInfo.environment["JARVIS_HARNESS"] == "1"`. Production launches don't set the env var; the gate fails closed.

**Harness data isolation (orch-default):** when `JARVIS_HARNESS=1`, the host writes to `~/Library/Application Support/Jarvis-Harness/` (separate SQLite, replay log, config) so harness runs never touch production state.

**Identifiers (orch-default):** `TurnID`, `ConfirmationID`, `FrameCaptureID` are server-generated `UUID()` strings. Tests do not pass IDs in; they capture them from `TurnAccepted` / `BargeInAccepted` / `confirmationRequested` / `FrameAttachArmed` and correlate.

**Scenario runner (UQ-5):** `ScenarioRunner.run(_:in:)` invokes a scenario closure once with `transport: .inProcessActor` and once with `transport: .jsonRoundTripWebView`. Default mode for new scenarios is `both`; explicit `actor`-only or `json`-only overrides are documented per scenario.

---

## 3. Coverage map

Every Command, Event, and Query in v1.0 (v0.1 + v0.2 amendments §2) maps to ≥1 scenario below. **Scenarios in §4 reference these IDs.** Operations marked **NEW** were added in v0.2.

### 3.1 Turn surface

| Operation | Type | Scenarios |
|---|---|---|
| `submitTurn(text:source:)` (images:` dropped per F-007) | Command | T-001, T-002, T-003, T-004, X-001..X-005, B02-* |
| `cancelTurn(turnId:)` | Command | T-005, T-006 |
| `bargeIn(text:source:)` (NEW: moved from Voice per UQ-4) | Command | T-007, T-008, T-009 |
| `respondToConfirmation(confirmationId:outcome:)` | Command | T-010, T-011, T-012, X-004 |
| `turnStarted` | Event | T-001, X-001..X-005 |
| `tokenStreamed(seq:)` (NEW: F-018 seq) | Event | T-001, T-013 |
| `thinkingStreamed(seq:)` | Event | T-014 |
| `toolCallStarted/Updated/Ended` | Event | T-015, X-002 |
| `confirmationRequested/Resolved` | Event | T-010, T-011 |
| `turnEnded(terminator:)` | Event | T-001, T-005, T-008 |
| `turnError(code:)` | Event | T-016, T-017, T-018, T-019, B02-fix |
| `turnTextComplete` (NEW: G-006) | Event | T-020 |
| `getActiveTurn` (NEW: toolCalls + accumulatedThinking per F-019) | Query | T-021 |
| `listTurns` | Query | T-022, B02-* |

### 3.2 Voice surface (UQ-4 trimmed: runtime verbs only)

| Operation | Type | Scenarios |
|---|---|---|
| `pttDown` / `pttUp` | Command | V-001, V-002, V-003 |
| `cancelTTS` | Command | V-004 |
| `synthesizeTurn(turnId:text:tier:)` (NEW: UQ-3) | Command | V-005, B05-fix |
| `_injectAudioFrame` (test seam) | Command | V-006, B04-fix |
| `_injectWakeWord` (test seam) | Command | V-007 |
| `_injectSTT` (test seam) | Command | V-008 |
| `_observeTTSAudio` (test seam) | Query | V-005, B05-fix |
| `voiceStateChanged` | Event | V-001, V-007 |
| `audioLevelChanged` | Event | V-006, B04-fix |
| `wakeWordDetected` | Event | V-007 |
| `sttTranscriptPartial/Final` | Event | V-008 |
| `ttsStarted/ttsEnded` | Event | V-005, V-009, B05-fix |
| `voiceDegraded` | Event | V-010, V-011 |
| `getVoiceState` | Query | V-012 |

### 3.3 Memory surface

| Operation | Type | Scenarios |
|---|---|---|
| `forgetFact(factId:)` (`requiresConfirmation:` dropped per F-009) | Command | M-001, M-002 |
| `factMutated` | Event | M-003, X-001 |
| `factsRetrieved` | Event | M-004 |
| `listRecentFacts` | Query | M-005 |
| `searchFacts` | Query | M-006, M-007 |

### 3.4 Vision surface

| Operation | Type | Scenarios |
|---|---|---|
| `requestFrameAttach(reason:)` | Command | Vis-001, Vis-002, B03-fix |
| `cancelFrameAttach` | Command | Vis-003 |
| `framePending(captureId:)` (NEW: F-007 captureId) | Event | Vis-001 |
| `frameSent(turnId:captureId:)` (NEW: F-007) | Event | Vis-001, X-002 |
| `frameExpired(captureId:)` (NEW: F-007) | Event | Vis-004 |
| `cameraDegraded` | Event | Vis-005 |
| `getFrameAttachState` | Query | Vis-006 |

### 3.5 Settings surface (UQ-4: canonical configuration writer)

| Operation | Type | Scenarios |
|---|---|---|
| `setProvider` | Command | S-001 |
| `setTTSTier` | Command | S-002 |
| `setSTTBackend` | Command | S-003 |
| `setFeatureFlag` | Command | S-004, S-005 |
| `storeAPIKey` | Command | S-006, S-007 |
| `setHotkey` | Command | S-008, S-009 |
| `setWakeWordMuted` | Command | S-010 |
| `setVoiceRunning(Bool)` (NEW: UQ-4 absorbs startVoice/shutdownVoice) | Command | S-011, B04-fix |
| `setLaunchAtLogin` (NEW: F-017) | Command | S-012 |
| `_setConfirmationDefault` (NEW: orch-default test seam) | Command | T-010, T-011 |
| `settingsChanged` | Event | S-001..S-012 |
| `getSettings` | Query | S-013 |

### 3.6 Diagnostics surface

| Operation | Type | Scenarios |
|---|---|---|
| `toggleDevOverlay` | Command | D-001 |
| `copyStateDump` | Command | D-002 |
| `dismissBanner(bannerId:)` (NEW: F-016) | Command | D-003 |
| `devSnapshotUpdated` | Event | D-004 |
| `systemBannerEnqueued/Dismissed` | Event | D-003, D-005 |
| `hudStateChanged` (NEW: moved from Turn per F-003) | Event | D-006, X-001 |
| `hardBlockTriggered(reason:)` (NEW: G-012) | Event | D-007 |
| `getHudState` (NEW: F-003 connect-time hydration) | Query | D-006 |
| `getDevSnapshot` | Query | D-008 |
| `getStateDump` | Query | D-009 |
| `streamReplayEvents(filter:)` (NEW: G-008) | Query/Stream | D-010, B02-fix |
| `snapshotReplayEvents(turnId:)` (NEW: G-008) | Query | D-011 |

### 3.7 Self surface

| Operation | Type | Scenarios |
|---|---|---|
| `selfStateChanged` (atDesk + presenceConfidence per F-021) | Event | Sf-001 |
| `tccStatusChanged` | Event | Sf-002, V-010 |
| `_forceTCCStatus(permission:granted:)` (NEW: G-003 test seam) | Command | Sf-002, V-010, Vis-005 |
| `getSelfState` | Query | Sf-003, B08-fix |
| `listAudioDevices` | Query | Sf-004 |
| `listCameraDevices` | Query | Sf-005 |
| `getActiveAudioRoute` | Query | Sf-006 |

### 3.8 Lifecycle / boot

| Operation | Type | Scenarios |
|---|---|---|
| `JarvisHost.boot() async -> Result<JarvisHost, BootError>` (NEW: OQ-T6) | Lifecycle | L-001..L-005 |
| Handshake `hello/helloAck` dual-version (NEW: R-005) | Lifecycle | L-006 |

**Total operations covered:** 7 surfaces × (commands + events + queries) ≈ 78 distinct API operations. Total scenarios: ~95 (see §4).

---

## 4. Scenario library

**Format:** `ID | Operation(s) | Setup | Action | Assertion | Modes | Gap`. `Modes` ∈ `{actor, json, both}`. `Gap` cites a v0.2 §2 finding when the scenario depends on an amendment.

### 4.1 Turn surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| T-001 | `submitTurn`, `turnStarted`, `tokenStreamed`, `turnEnded` | `MockLLMProvider` emits "hello world" | `submitTurn(text:"hi", source:.text)` | turnStarted with `turnId == result.turnId`; tokenStreamed.seq == [0,1]; turnEnded.terminator == .completed; usage non-nil | both | — |
| T-002 | `submitTurn` | text source, MockLLM emits successfully | submit "first" → submit "second" before T-001 ends | second returns `.failure(.turnInFlight(currentTurnId:))` | both | — |
| T-003 | `submitTurn` | `providerOverrides.anthropic = nil`, real provider raises | submit | returns `.failure(.providerUnavailable(reason:))` | actor | G-005 [trigger: harness-injectable via ErrorInjector] |
| T-004 | `submitTurn`, `factsRetrieved` | seed 5 facts; MockLLM | submit "search facts" | factsRetrieved.factIds.count > 0 | actor | — |
| T-005 | `cancelTurn`, `turnEnded(.cancelled)` | submit, await turnStarted | `cancelTurn(turnId)` then `submitTurn` again with same id | first returns success; turnEnded(t1, .cancelled); no further events for t1; second submit succeeds | both | F-005 |
| T-006 | `cancelTurn` | idle | `cancelTurn(UUID())` | `.failure(.noTurnInFlight)` | both | — |
| T-007 | `bargeIn` | nothing in flight | `bargeIn(text:"go")` | `BargeInAccepted{ supersededTurnId: nil, newTurnId: <new> }` | both | UQ-4 (Turn surface) |
| T-008 | `bargeIn`, `turnEnded(.superseded)`, `cancelTTS` invariant | submit T1; await ttsStarted | `bargeIn(text:"stop")` | T1 turnEnded(.superseded); ttsEnded(T1, .cancelled) BEFORE turnStarted(T2) | both | R-018 |
| T-009 | `bargeIn`, `BargeInError.interruptFailed` | submit T1; injector forces cancel-success+submit-fail | barge in | returns `.failure(.interruptFailed(supersededTurnId: T1))` | actor | F-004 [trigger: harness-injectable] |
| T-010 | `respondToConfirmation(.approved)` | tool requires confirmation; auto-approve disabled | submit; await confirmationRequested(c1); `respondToConfirmation(c1, .approved)` | confirmationResolved(c1, .approved); toolCallEnded.ok == true | both | — |
| T-011 | `respondToConfirmation(.denied)` | same | submit; deny | confirmationResolved(c1, .denied); toolCallEnded with text == "User denied this operation"; turnEnded.completed | both | F-006 |
| T-012 | `respondToConfirmation(timedOut)` | clock = ManualClock; timeout = 30s | submit; await confirmationRequested; advance clock 31s | confirmationResolved(c1, .timedOut); attempting `respondToConfirmation(.approved)` returns `.failure(.alreadyResolved)` | both | G-002, G-011 |
| T-013 | `tokenStreamed.seq` | MockLLM emits 5 tokens | submit | seq sequence == [0,1,2,3,4]; harness asserts no gap | both | F-018 |
| T-014 | `thinkingStreamed.seq` | MockLLM emits thinking blocks | submit | seq monotonic | both | F-018 |
| T-015 | `toolCallStarted/Updated/Ended` | tool with streaming args | submit | argsPreview updates monotonically; toolCallEnded.ok == true | both | — |
| T-016 | `turnError(.streamTruncated)` | MockLLM truncates twice (forces retry exhaustion) | submit | turnError(code: .streamTruncated) | actor | G-005 |
| T-017 | `turnError(.maxTokensExceeded)` | MockLLM emits stop_reason: max_tokens | submit | turnError(code: .maxTokensExceeded) | actor | G-005 |
| T-018 | `turnError(.refusal)` | MockLLM emits stop_reason: refusal | submit | turnError(code: .refusal) | actor | G-005 |
| T-019 | `turnError(.providerError)` | URLProtocol stub returns 500 | submit | turnError(code: .providerError) | actor | G-005 |
| T-020 | `turnTextComplete` | submit with multi-token reply | submit | tokenStreamed* arrive; turnTextComplete(turnId, fullText) precedes turnEnded; fullText == sum of tokens | both | G-006 |
| T-021 | `getActiveTurn` | submit; mid-flight | query before turnEnded | snapshot.turnId matches; phase == .running; toolCalls reflects in-flight; accumulatedText non-empty | both | F-019 |
| T-022 | `listTurns` | run 3 turns | `listTurns(limit: 100)` | turns.count == 3, ordered newest-first; `listTurns(limit:1, beforeTurnId:t3)` returns t2 | both | — |

### 4.2 Voice surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| V-001 | `pttDown`, `pttUp`, `voiceStateChanged` | voice running; Input Monitoring granted | pttDown → injectSTT(final) → pttUp | voiceStateChanged: idle→listening(.ptt)→thinking; turnStarted | both | — |
| V-002 | `pttDown` permission denied | `_forceTCCStatus(.inputMonitoring, false)` | pttDown | `.failure(.inputMonitoringDenied)` | both | G-003 |
| V-003 | `pttDown` voice not running | `setVoiceRunning(false)` | pttDown | `.failure(.voiceNotRunning)` | both | G-005 |
| V-004 | `cancelTTS` | TTS in flight | cancelTTS | ttsEnded(.cancelled) within 100ms (clock-asserted) | both | — |
| V-005 | `synthesizeTurn(turnId:text:tier:)` | MockLLM completes a voice-source turn | observe `Voice._observeTTSAudio`; submit voice turn | synthesizeTurn was issued; ttsStarted(turnId, tier1, "..."); ttsEnded(.completed); TTSSynthesisRecord.turnId matches | both | UQ-3, G-001 |
| V-006 | `_injectAudioFrame`, `audioLevelChanged` | voice running, MockTTS, MockSTT | inject 15 frames | ≥10 audioLevelChanged events within 500ms (ManualClock) | both | G-001 |
| V-007 | `_injectWakeWord`, `wakeWordDetected`, `voiceStateChanged` | voice running | injectWakeWord(confidence: 0.9) | wakeWordDetected; voiceStateChanged → listening(.wakeWord) | both | G-001 |
| V-008 | `_injectSTT`, `sttTranscriptPartial/Final` | listening | injectSTT("hello", false), injectSTT("hello world", true) | sttTranscriptPartial("hello"); sttTranscriptFinal("hello world", turnId); turnStarted | both | G-001 |
| V-009 | `ttsStarted/ttsEnded.error` | MockTTS forced to fail | synthesizeTurn | ttsEnded(.error); voiceState returns to idle | actor | G-005 |
| V-010 | `voiceDegraded(.microphoneRevoked)` | voice running | `_forceTCCStatus(.microphone, false)` | tccStatusChanged(.microphone, false); voiceDegraded(.microphoneRevoked); systemBannerEnqueued | both | G-003 |
| V-011 | `voiceDegraded(.aecUnavailable)` | injector forces AEC fail | _injectAudioFrame triggers reroute | voiceDegraded(.aecUnavailable); on restoration, voiceDegraded(.aecRestored) | actor | G-005, G-001 |
| V-012 | `getVoiceState` | running | query | snapshot fields populated; sttBackend / ttsTier reflect Settings | both | — |

### 4.3 Memory surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| M-001 | `forgetFact` | seed fact F | `forgetFact(F)` | `.success`; later `listRecentFacts` returns F.validTo set; factMutated emitted | both | F-009 |
| M-002 | `forgetFact(notFound)` | empty | `forgetFact(UUID())` | `.failure(.factNotFound)` | both | — |
| M-003 | `factMutated(.add/.update/.noop)` | Stub MemoryExtractor maps "I like coffee" → ADD | submit "I like coffee" | factMutated(op:.add); follow-up "I prefer tea" → factMutated(op:.update, validFrom newer) | actor | G-010 |
| M-004 | `factsRetrieved` | seed 3 facts | submit "what do I like" | factsRetrieved.factIds non-empty; retrievalReason ∈ {hybridSearch, recentActive} | actor | G-010 |
| M-005 | `listRecentFacts` | seed 5 | `listRecentFacts(limit:3)` | returns 3, newest validFrom first | both | — |
| M-006 | `searchFacts` (FTS path) | StubEmbedder returns zero vector → FTS dominates | `searchFacts("coffee", k:5)` | FactRef.matchedBy ∈ {fts5, hybrid} | both | — |
| M-007 | `searchFacts` (vector path) | StubEmbedder returns realistic vector | search | FactRef.matchedBy ∈ {vector, hybrid}; scores monotonic | actor | G-010 [trigger: real-only without ProviderOverrides] |

### 4.4 Vision surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| Vis-001 | `requestFrameAttach`, `framePending`, `frameSent` | camera granted; idle | `requestFrameAttach(.hudButton)` → `submitTurn` | FrameAttachArmed; framePending(captureId); frameSent(turnId, captureId); orchestrator's last LLM call has imageCount > 0 | both | F-007, G-014 |
| Vis-002 | `requestFrameAttach.cameraPermissionDenied` | `_forceTCCStatus(.camera, false)` | request | `.failure(.cameraPermissionDenied)` | both | G-003 |
| Vis-003 | `cancelFrameAttach` | armed | cancel | armed→false; subsequent submitTurn has no image | both | — |
| Vis-004 | `frameExpired` | armed; ManualClock | advance 5.1s | frameExpired(captureId) | both | G-002 |
| Vis-005 | `cameraDegraded` | granted; revoke mid-flight | `_forceTCCStatus(.camera, false)` | cameraDegraded; getFrameAttachState.cameraTCCGranted == false | both | G-003 |
| Vis-006 | `getFrameAttachState` | various | query at each phase | snapshot fields match phase | both | — |

### 4.5 Settings surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| S-001 | `setProvider`, `settingsChanged` | provider=anthropic | `setProvider(.ollama)` | settingsChanged(["provider"]); getSettings.provider == .ollama; selfStateChanged.provider matches | both | — |
| S-002 | `setTTSTier` | tier1 | `setTTSTier(.tier2)` | settingsChanged; subsequent synthesizeTurn observes tier2 | both | F-001 |
| S-003 | `setSTTBackend` | speechAnalyzer | `setSTTBackend(.whisperKit)` | settingsChanged; getVoiceState.sttBackend == .whisperKit | both | — |
| S-004 | `setFeatureFlag` | flag known | `setFeatureFlag("voice.orpheus", true)` | success; getSettings.featureFlags["voice.orpheus"] == true | both | — |
| S-005 | `setFeatureFlag.unknownFlag` | — | unknown flag | `.failure(.unknownFlag)` | both | — |
| S-006 | `storeAPIKey` happy | StubKeyValidator returns valid | `storeAPIKey("sk-...")` | `.success`; getSettings.apiKeyStored == true | actor | G-004 |
| S-007 | `storeAPIKey.validationFailed` | StubKeyValidator returns invalid | store | `.failure(.validationFailed)` | actor | G-004 |
| S-008 | `setHotkey` happy | none bound | `setHotkey(Cmd+Opt+J)` | success; getSettings.hotkey set | both | — |
| S-009 | `setHotkey.collision` | injector forces collision | bind | `.failure(.collision(conflictsWith:))` | actor | G-005 |
| S-010 | `setWakeWordMuted` | unmuted | `setWakeWordMuted(true)` | settingsChanged; getVoiceState.wakeWordMuted == true | both | F-001 |
| S-011 | `setVoiceRunning(false)` | running | toggle | settingsChanged; voice subsystem stops; subsequent pttDown returns voiceNotRunning | both | UQ-4 |
| S-012 | `setLaunchAtLogin` | disabled | `setLaunchAtLogin(true)` | success; getSettings.launchAtLoginEnabled == true | actor | F-017 |
| S-013 | `getSettings` | post-init | query | every documented field present, non-default where set | both | — |

### 4.6 Diagnostics surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| D-001 | `toggleDevOverlay` | hidden | toggle | returns .visible; second toggle .hidden | both | — |
| D-002 | `copyStateDump` | — | invoke | systemBannerEnqueued("Diagnostics copied"); query getStateDump returns same JSON | actor | — |
| D-003 | `dismissBanner`, `systemBannerDismissed` | enqueue 1 | dismiss(bannerId) | systemBannerDismissed(bannerId) | both | F-016 |
| D-004 | `devSnapshotUpdated` | run a turn | submit | devSnapshotUpdated emitted post-turn; cacheHitPercent populated | both | — |
| D-005 | `systemBannerEnqueued` | trigger via voiceDegraded | revoke mic | systemBannerEnqueued with priority>0 | both | — |
| D-006 | `hudStateChanged`, `getHudState` | boot | observe sequence: booting→idle | ordered transitions; getHudState returns current at any moment | both | F-003 |
| D-007 | `hardBlockTriggered` | force handshake mismatch via injector | boot | hardBlockTriggered(reason:) emitted; host terminates within 1s | actor | G-012 |
| D-008 | `getDevSnapshot` | post-turn | query | returns latest snapshot WITHOUT emitting event | both | — |
| D-009 | `getStateDump` | — | query | StateDumpPayload.fields matches copyStateDump JSON | both | — |
| D-010 | `streamReplayEvents(filter:)` | run 2 turns | stream(filter: .turnId(t1)) | yields all replay rows for t1; closes when subscription cancelled | actor | G-008 |
| D-011 | `snapshotReplayEvents(turnId:)` | t1 complete | snapshot(t1) | array contains turnStart/turnEnd/toolCalls/memoryMutation rows for t1 | actor | G-008 |

### 4.7 Self surface scenarios

| ID | Operations | Setup | Action | Assertion | Modes | Gap |
|---|---|---|---|---|---|---|
| Sf-001 | `selfStateChanged` | boot | observe | first emit has modelId == "claude-opus-4-7"; modelDisplayName == "Claude Opus 4.7"; sessionId set; atDesk/presenceConfidence present (DEFERRED-OK if nil) | both | F-021 |
| Sf-002 | `_forceTCCStatus`, `tccStatusChanged` | granted | force(.microphone, false) | tccStatusChanged(.microphone, false); voiceDegraded follows | both | G-003 |
| Sf-003 | `getSelfState` | — | query | all SelfStatePayload fields populated | both | — |
| Sf-004 | `listAudioDevices` | — | query | returns ≥1 device on real hardware; isDefault exactly 1 | both | [trigger: real-only OR mocked via ProviderOverrides hardware] |
| Sf-005 | `listCameraDevices` | — | query | similar | both | real-only |
| Sf-006 | `getActiveAudioRoute` | voice running | query | non-nil; nil after `setVoiceRunning(false)` | both | — |

### 4.8 Cross-surface scenarios (TurnID correlation)

These prove the bug class is dissolved: silent handoffs across surfaces become observable invariants.

| ID | Surfaces | Scenario | Asserted invariant | Modes |
|---|---|---|---|---|
| **X-001** | Voice → Turn → Memory → Diagnostics | Voice turn produces fact, HUD reflects | injectWakeWord; injectSTT("I like coffee", final); MockLLM responds; StubExtractor emits ADD | turnStarted(t1, .voice) → factMutated(t1, .add) → hudStateChanged transitions listening→thinking→speaking→idle. **All events carry t1 or t1 contributes; no events orphaned.** | both |
| **X-002** | Vision → Turn → Diagnostics | Frame-attach completes a vision turn | requestFrameAttach(.hudButton); submitTurn(text:"what's this"); MockLLM with image-aware fixture | framePending(c1) → frameSent(t1, c1) → toolCallStarted/Ended → turnEnded(t1, .completed) → devSnapshotUpdated.imageCount > 0 | both |
| **X-003** | Voice → Turn → Voice (TTS handoff: B-05) | Voice turn ends → TTS synthesizes (UQ-3 explicit command) | injectWakeWord/STT; await turnEnded(t1, .completed) | within 500ms (ManualClock): `Voice.synthesizeTurn(turnId: t1, ...)` was issued; ttsStarted(t1) emitted; turnId equals turnId of the voice turn | both |
| **X-004** | Turn → Memory → Turn (B-02 history threading) | Two turns; second references first | submit "I'm James"; submit "what's my name" | second LLM call's `messages` includes first user+assistant turn (asserted via `Diagnostics.lastLLMCall` snapshot or MockLLM call recorder); second turnEnded.completed | both |
| **X-005** | Turn → Memory + Turn confirm + Voice cancelTTS | Multi-tool turn with confirmation, fact mutation, TTS, then barge-in | voice turn requesting `forget_fact` (confirmation) + `get_time` | confirmationRequested(c1, "forget_fact"); approve; toolCallEnded(c1.ok); factMutated(forgotten); turnEnded; ttsStarted; bargeIn → ttsEnded(.cancelled) before turnStarted(t2) | both |
| **X-006** | Settings → Voice → Turn | Mid-session provider swap mid-conversation | run T1 with anthropic; setProvider(.ollama); run T2 | T1.turnStarted.provider == "anthropic"; settingsChanged; T2.turnStarted.provider == "ollama"; selfStateChanged.provider observed twice | both |
| **X-007** | Self → Voice (TCC revocation cascade) | Mic revoked mid-listening | injectWakeWord; mid-stream `_forceTCCStatus(.microphone, false)` | tccStatusChanged → voiceDegraded(.microphoneRevoked) → voiceStateChanged(idle) → systemBannerEnqueued; in-flight STT turn (if any) ends with turnError | both |
| **X-008** | Diagnostics → all (replay roundtrip oracle) | Run a fixture; replay it; assert event sequence equality modulo nondeterminism | execute scenario X-001; capture replay; submitTurn(source: .replay) | replayed event sequence has identical: turnId-relative ordering, factMutated ops, toolCalls. Tolerates: timestamps, durations, batch boundaries | actor |

---

## 5. B-02..B-08 reproduction + dissolution matrix

Each row: pre-fix scenario reproduces the bug on today's HEAD; post-fix scenario passes only after migration milestone lands.

| Bug | v0.2 disposition | Pre-fix scenario (reproduces) | Post-fix scenario (proves dead) | Modes |
|---|---|---|---|---|
| **B-02** history threading | UQ-2: tactical patch + M-4 regression gate (R-006) | **B02-repro:** submit "I'm James"; submit "what's my name"; assert MockLLM 2nd call's `messages` does NOT contain T1's user/assistant turns (asserts current bug). | **B02-fix (= X-004):** same setup; assert 2nd call's messages DOES contain T1. Plus **B02-r006:** "two short turns then a third turn" — assert no `turnError(.streamTruncated)`. | both |
| **B-03** camera button dead | F-007 + UQ-5 (transport equivalence required to surface this class) | **B03-repro:** `transport: .jsonRoundTripWebView`; webview emits `frameAttachRequested`; assert no `framePending` arrives within 200ms (current bug). | **B03-fix:** same; assert `FrameAttachArmed` returned within 100ms; framePending(captureId) emitted. | json (ESSENTIAL — actor mode passes today) |
| **B-04** voice dead | M-6 gate (R-007) | **B04-repro:** `setVoiceRunning(true)`; assert NO `audioLevelChanged` within 500ms with real audio path (current bug). | **B04-fix:** `setVoiceRunning(true)` returns success; ≥10 `audioLevelChanged` within 500ms. Failure path: `_forceError("setVoiceRunning", "audioGraphFailed")` → `.failure(.audioGraphFailed(reason:))` not silent log. | actor + JARVIS_REAL_AUDIO=1 hardware |
| **B-05** TTS silent | UQ-3 explicit `synthesizeTurn` command + M-6 | **B05-repro:** voice turn completes; assert `Voice.synthesizeTurn` was NEVER issued (matches current silent handoff). | **B05-fix (= X-003):** voice turn completes → orchestrator issues `synthesizeTurn(turnId:t1, ...)` within 500ms → ttsStarted(t1) emitted. Direct command-issued assertion via `Diagnostics.lastVoiceCommand` or call recorder. | both |
| **B-06** chat scroll | G-006 PARTIAL — out of harness scope per R-014 | **B06-repro:** **GAP-FLAGGED** — DOM observability not in v1.0 contract. Vitest layer + manual UAT cover this. | **B06-fix:** `Turn.turnTextComplete(turnId, fullText)` event arrives between final tokenStreamed and turnEnded. Webview-side `scrollAnchored` ack is out of scope. | json — partial |
| **B-07** Voice Log menu missing | DEFERRED to Plan 10-05 re-scope | **B07-repro:** `Diagnostics.getStateDump.fields["voiceLogVisible"]` absent on current HEAD. | **B07-fix:** post Plan 10-05 — `getStateDump.fields["voiceLogVisible"]` exists; toggle command flips it. Scenario lives at the Diagnostics surface. | both |
| **B-08** model paraphrase | M-1 (Self surface) | **B08-repro:** submit "what model are you"; capture tokenStreamed text; assert NO `"4.5"` substring (probabilistic — soft assert). With current `get_self_state` tool result, this can fail. | **B08-fix:** `Self.getSelfState.modelDisplayName == "Claude Opus 4.7"`; tool result string includes `"model_display_name": "Claude Opus 4.7"`; harness asserts `"Opus 4.5"` substring count ≤ 0 across 5 paraphrase prompts (still probabilistic, structural fix raises floor). | both |

**Coverage:** 6/7 bugs are reproducible via API alone post-migration. B-06 stays gap-flagged (vitest territory). B-07 awaits Plan 10-05 re-scope.

---

## 6. Failure-injection scenarios

Every error variant in v1.0 annotated. Per UQ-1 + G-005, harness uses `_forceError(operation:code:)` debug command (gated by `JARVIS_HARNESS=1`) plus `ErrorInjector` collaborator.

| Surface.Operation.ErrorCase | Trigger | Scenario | Modes |
|---|---|---|---|
| Turn.submitTurn.turnInFlight | natural | T-002 | both |
| Turn.submitTurn.providerUnavailable | harness-injectable (ErrorInjector) | T-003 | actor |
| Turn.submitTurn.configError | harness-injectable | T-003-cfg (variant) | actor |
| Turn.cancelTurn.noTurnInFlight | natural | T-006 | both |
| Turn.cancelTurn.turnIdMismatch | natural (pass wrong UUID) | T-006-mismatch | both |
| Turn.bargeIn.providerUnavailable | harness-injectable | T-009-provider | actor |
| Turn.bargeIn.configError | harness-injectable | T-009-cfg | actor |
| Turn.bargeIn.interruptFailed | harness-injectable (cancel-success+submit-fail) | T-009 | actor |
| Turn.respondToConfirmation.noSuchConfirmation | natural | T-010-nosuch | both |
| Turn.respondToConfirmation.alreadyResolved | natural (double-resolve) | T-012 (post-timeout) | both |
| Turn.respondToConfirmation.timedOut (boundary reject) | clock + natural | T-012 | both |
| Turn.turnError.providerError | URLProtocol stub 500 | T-019 | actor |
| Turn.turnError.streamTruncated | MockLLM truncation | T-016 | actor |
| Turn.turnError.maxTokensExceeded | MockLLM stop_reason | T-017 | actor |
| Turn.turnError.refusal | MockLLM stop_reason | T-018 | actor |
| Turn.turnError.configError | harness-injectable | T-019-cfg | actor |
| Turn.turnError.internalError | harness-injectable | T-019-internal | actor |
| Voice.pttDown.inputMonitoringDenied | _forceTCCStatus | V-002 | both |
| Voice.pttDown.voiceNotRunning | natural | V-003 | both |
| Voice.pttUp.* | as above | V-002/003 mirror | both |
| Voice.synthesizeTurn TTSError.providerUnavailable | harness-injectable | V-009-prov | actor |
| Voice.synthesizeTurn TTSError.synthesisFailed | harness-injectable | V-009 | actor |
| Voice.voiceDegraded.aecUnavailable | harness-injectable | V-011 | actor |
| Voice.voiceDegraded.aecRestored | harness-injectable | V-011 | actor |
| Voice.voiceDegraded.microphoneDenied | _forceTCCStatus | V-002 cascade | both |
| Voice.voiceDegraded.microphoneRevoked | _forceTCCStatus | V-010 | both |
| Memory.forgetFact.factNotFound | natural | M-002 | both |
| Memory.forgetFact.alreadyForgotten | natural (double) | M-002-double | both |
| Memory.forgetFact.confirmationDenied | natural | M-001-deny | both |
| Vision.requestFrameAttach.cameraPermissionDenied | _forceTCCStatus | Vis-002 | both |
| Vision.requestFrameAttach.alreadyArmed | natural (double) | Vis-001-double | both |
| Vision.requestFrameAttach.turnInFlight | natural (mid-turn) | Vis-001-midturn | both |
| Settings.setFeatureFlag.unknownFlag | natural | S-005 | both |
| Settings.storeAPIKey.keychainWriteFailed | harness-injectable (FakeKeychain failure) | S-006-fail | actor |
| Settings.storeAPIKey.validationFailed | StubKeyValidator | S-007 | actor |
| Settings.setHotkey.inputMonitoringDenied | _forceTCCStatus | S-008-tcc | both |
| Settings.setHotkey.collision | harness-injectable | S-009 | actor |
| Settings.setHotkey.bindFailed | harness-injectable | S-009-bind | actor |
| Settings.setLaunchAtLogin.* (LaunchAtLoginError) | harness-injectable | S-012-fail | actor |
| Diagnostics.dismissBanner.bannerNotFound | natural | D-003-nosuch | both |
| Lifecycle.boot BootError.* | harness-injectable | L-002..L-005 | actor |

**Triggers — annotation legend:**
- `[trigger: harness-injectable]` — `_forceError`, `ErrorInjector`, or `ProviderOverrides` route. Default for harness suite.
- `[trigger: real-only]` — requires real OS state or hardware (`JARVIS_REAL_*` env flag suite).
- `[trigger: not-yet-triggerable]` — variant in v1.0 not yet wired to any production codepath; flagged as documentation-only until M-N closes it.

---

## 7. Determinism / replay roundtrip contract

### 7.1 Deterministic scenarios (must produce identical event sequence on re-run)

When run with `ManualClock`, `ProviderOverrides{anthropic: MockLLMProvider(fixture:), ollamaEmbedder: StubEmbedder(constant), memoryExtractor: StubMemoryExtractor(map:)}`, and harness-controlled TCC: **every scenario in §4.1, §4.3, §4.4, §4.5, §4.6, §4.7 except those explicitly marked actor-only with real provider** must produce byte-identical event sequences modulo:

- absolute timestamps (relative ordering preserved)
- elapsedMs / durationMs values (relative comparisons asserted via clock arithmetic, not raw ms)
- `OutboundBatcher` batch boundaries (harness flat-maps; G-009)
- replay log SQLite row IDs (use turnId correlation, not row IDs)

### 7.2 Nondeterministic surfaces (require ProviderOverrides to be deterministic)

| Surface area | Source of nondeterminism | Determinism strategy |
|---|---|---|
| LLM streaming output | provider tokenization / sampling | `MockLLMProvider(fixtureURL:)` — replay byte-for-byte |
| Memory extraction (factMutated) | local Qwen 2.5-Coder | `StubMemoryExtractor(turnText → ops map)` |
| Embedding-backed search | nomic-embed-text | `StubEmbedder` constant or `JARVIS_REAL_MODELS=1` |
| Wake-word DAG (real audio) | mel/embedding floating-point | covered by `_injectWakeWord(confidence:)` shortcut |
| TTS synthesis duration | model + audio renderer | `_observeTTSAudio` records {sampleCount, started, ended} not waveform |
| Hardware enumeration | host machine | `Sf-004/005` are `real-only` or use `ProviderOverrides.hardware` mock |

### 7.3 Replay roundtrip oracle (X-008)

**Contract:** for any deterministic scenario S, running S, capturing `streamReplayEvents`, then `submitTurn(source: .replay)` with the captured fixture must produce an event sequence that compares-equal to S's sequence under the equality relation defined in §7.1. **This is the dissolution of the entire pivot-justifying bug class:** any silent regression that breaks an internal handoff causes the replayed sequence to diverge.

---

## 8. TCC / hardware / network gating (env-flag suite)

Default harness run = no env flags = all mocks. Real-* runs are interactive / pre-merge gates.

| Env flag | Scenarios | Required state |
|---|---|---|
| `JARVIS_HARNESS=1` | ALL harness scenarios | (default for any harness invocation; UQ-1) |
| `JARVIS_REAL_MODELS=1` | M-007 (vector search), M-003-real, X-008-real | Ollama running with `nomic-embed-text` + `qwen2.5-coder:32b`; vec0.dylib loadable |
| `JARVIS_REAL_AUDIO=1` (NEW) | B04-fix-real (smoke), V-006-real | Real input device; mic TCC granted; AEC functional |
| `JARVIS_REAL_CAMERA=1` | Vis-001-real, Sf-005 | Real AVCaptureDevice; camera TCC granted |
| `JARVIS_REAL_ANTHROPIC=1` | T-001-real, S-007-real (round-trip key validation), B08-real | Live API key in Keychain; cache TTL behavior tests opt-in |
| `JARVIS_TCC_DENIED_MIC=1` | V-002-real, V-010-real | Host with mic TCC explicitly denied (separate machine or revoked) |
| `JARVIS_TCC_DENIED_CAMERA=1` | Vis-002-real, Vis-005-real | Camera TCC denied |

**Default harness suite (no env flags):** every scenario in §4 runs with `_forceTCCStatus` for permission states + `ProviderOverrides` for LLM/embedder/extractor + `_injectAudioFrame` for audio + `_injectWakeWord` / `_injectSTT` for voice events. **No real network or hardware required.**

---

## 9. Transport equivalence (UQ-5)

Per UQ-5 lock: **every scenario in §4 runs in two modes** — `transport: .inProcessActor` (direct Swift actor calls) and `transport: .jsonRoundTripWebView` (encodes Commands as JSON, drives a real WKWebView via existing `RealWKWebViewIntegrationTests` infrastructure, reads Events back through `WKScriptMessageHandler`).

**Exceptions** (mode-restricted):
- **actor only:** scenarios depending on `URLProtocol` stubs that the JSON transport path can't observe (T-016, T-017, T-018, T-019, S-006, S-007, M-007, V-009, V-011, X-008-replay, D-002, D-007, D-010, D-011). Reasoning: these test internal substrate behavior that doesn't require transport equivalence.
- **json essential:** B-03 reproduction (B03-repro / B03-fix). Reasoning: bug only reproduces over the WebView round-trip; this is the canonical proof of why UQ-5 was accepted.

**Transport diff oracle:** `ScenarioRunner` records the event sequence for each transport. Post-run, the runner asserts: `eventsActor` and `eventsJSON` compare-equal under §7.1's equivalence relation. A divergence is a transport bug; flag with `TransportDivergenceError`.

**Bus protocol handshake (R-005):** harness boots accept versions `["2.3.0", "2.4.0-rc"]` during M-0..M-7. After M-7, only `2.4.0` is accepted; the harness drops `2.3.0` from the accept set.

---

## 10. Open issues for Phase 6 (migration plan)

1. **Tactical B-02 patch sequencing.** UQ-2 mandates B-02 fix lands as a one-commit tactical patch (not part of M-1..M-7). Migration plan must specify: does the tactical patch ship before M-0 (cleanest — pre-API regression test wedge gates against re-introduction during M-4) or in parallel? Companion regression `B02-r006` MUST run on every commit touching `AgentOrchestrator.process` until M-4.

2. **Skeleton compiles but doesn't link to JarvisAPI yet.** `Tools/jarvis-diag/Package.swift` declares a dependency on `packages/JarvisAPI/` which doesn't exist until M-0. Migration plan should make M-0 step #1 = "create `packages/JarvisAPI/` with type signatures only," then step #2 = "set `Tools/jarvis-diag/` Package.swift product dependency to JarvisAPI," then step #3 = "harness scaffolding stubs become callable." Skeleton in this PR ships with the dependency commented-out and `// IMPL:` stubs.

3. **Real-WKWebView substrate coupling.** `transport: .jsonRoundTripWebView` requires `packages/Bus/Tests/RealWKWebViewIntegrationTests.swift` (existing) to be lifted into a public harness-callable runner. Migration plan must own this lift — it's a packages/Bus refactor, not a Tools/jarvis-diag concern. Coordinate with M-0 step list.

---

*End of test contract.*
