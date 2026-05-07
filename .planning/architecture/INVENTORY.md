# Jarvis Capability Inventory

**Generated:** 2026-05-07
**Branch / HEAD:** `develop` @ `1b7fb81`
**Purpose:** substrate for the API design swarm. Every capability the system
currently exposes (or wires but does not exercise), with file:line citations.
The Architect phase will collapse and re-group these into coherent API
surfaces. This file does not propose the API.

## How to read

- Each row is one capability the new API must represent (or explicitly retire).
- "Site" is the canonical Swift / JS file:line where the capability is
  defined or routed. Where multiple sites are equally relevant the primary
  is given first; secondary sites are in parentheses.
- "Notes" classifies status:
  - **ALIVE** — wired AND invoked end-to-end in production.
  - **DEAD** — wired (type exists, callers exist, registration exists)
    but no path delivers it end-to-end. The B-02..B-08 bug class lives here.
  - **DEFERRED** — wired but kept dormant behind a flag / placeholder
    (Vision T2 sidecar, WhisperKit, Orpheus, Voice Log, presence-from-camera).
  - **RETIRED-CANDIDATE** — implementation exists but is unreachable from
    production install code (no registration, no menu item, no call site).
- Where the capability is the *pre-fix* shape of an open carry-forward bug,
  the bug ID (B-02..B-08) is included.

## 1. Bus inbound (JS → Swift)

Defined by `BusInbound` enum (`packages/Bus/Sources/Bus/BusInbound.swift`)
and dispatched in `AppDelegate.installBus` (`App/AppDelegate.swift:2108-2125`).

| Capability | Site | Notes |
| --- | --- | --- |
| `helloAck(version:)` (handshake response from JS) | `packages/Bus/Sources/Bus/BusInbound.swift:12`, dispatched inline in `WebviewBridge.handleInboundString` `packages/Bus/Sources/Bus/WebviewBridge.swift:220` | ALIVE |
| `uiReady` (UI mount marker, no-op) | `packages/Bus/Sources/Bus/BusInbound.swift:13`, routed at `App/AppDelegate.swift:2111` | ALIVE (no-op) |
| `frameAttachRequested` (HUD camera-icon click) | `packages/Bus/Sources/Bus/BusInbound.swift:17`, routed at `App/AppDelegate.swift:2115-2117` to `FrameAttachController.requestAttach(reason: .hudButton)` | DEAD (B-03) — emit exists in webview source + dist; click never lands at the AppDelegate handler |
| `chatSubmit(text:)` (chat panel Send) | `packages/Bus/Sources/Bus/BusInbound.swift:21`, routed at `App/AppDelegate.swift:2118-2120` to `handleChatSubmit` `App/AppDelegate.swift:1710` | ALIVE |
| `chatCancelAndSubmit(text:)` (chat panel barge-in) | `packages/Bus/Sources/Bus/BusInbound.swift:24`, routed at `App/AppDelegate.swift:2121-2123` to `handleChatCancelAndSubmit` `App/AppDelegate.swift:1735` | ALIVE |

## 2. Bus outbound (Swift → JS)

Defined by `BusOutbound` (`packages/Bus/Sources/Bus/BusOutbound.swift`) +
`HudState` / `TurnTerminator` (`packages/Bus/Sources/Bus/Protocol.swift:33,46`).
Wire send routes through `WebviewBridge.send` / `sendRaw`
(`packages/Bus/Sources/Bus/WebviewBridge.swift:167,180`) and the coalescing
`OutboundBatcher` (`packages/Bus/Sources/Bus/OutboundBatcher.swift`).

| Capability | Site | Notes |
| --- | --- | --- |
| `hello(version:)` (handshake initiator from Swift) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:14`; emit `packages/Bus/Sources/Bus/WebviewBridge.swift:154` (`startHandshake`) | ALIVE |
| `hudState(HudState)` (idle/listening/thinking/speaking/awaitingConfirmation/reconfiguring/booting) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:15`; emit closure built in `App/AppDelegate.swift:2073` driven by `HudStateCoordinator` `App/HUD/HudStateCoordinator.swift:59` | ALIVE |
| `tokenDelta(text:)` (assistant text streaming chunks) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:16`; emit `packages/Bus/Sources/Bus/OutboundBatcher.swift:87` from `BusForwarder` chunk channel | ALIVE |
| `audioLevel(rms:)` (~30 Hz mic RMS for ring) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:17`; emit `packages/Bus/Sources/Bus/OutboundBatcher.swift:82` driven by `Voice.AudioLevelEmitter` (`packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:71`) | DEAD (B-04) — no audio frames reach the DAG so RMS never produced |
| `toolCallStart(id:name:argsPreview:)` | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:18`; emit `App/MCPBusGatewayAdapter.swift:60` (and re-emit on args update at line 67) | ALIVE |
| `toolCallEnd(id:ok:previewOrError:)` | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:19`; emit `App/MCPBusGatewayAdapter.swift:75` | ALIVE |
| `turnStarted(id:)` | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:20`; emit `App/AppBusForwarderSink.swift:23` via `BusForwarder` | ALIVE |
| `turnEnded(id:terminator:)` (completed/cancelled/errored/superseded) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:21` + `TurnTerminator` `packages/Bus/Sources/Bus/Protocol.swift:46`; emit `App/AppBusForwarderSink.swift:27` | ALIVE |
| `sessionHistory(turns:)` (chat panel hydration on `uiReady`) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:25`; intended emit on webview-ready by AppDelegate `installMemory` (Plan 07-06) | DEAD — no production emit site found in `App/`; only Bus tests reference the case |
| `submitRejected(reason:)` (text-path rejection toast) | enum case `packages/Bus/Sources/Bus/BusOutbound.swift:31`; emit `App/AppDelegate.swift:1793` (`handleTextOutcome`) and `App/AppBusForwarderSink.swift:35` | ALIVE |
| `TurnRow` (sessionHistory payload row) | struct `packages/Bus/Sources/Bus/BusOutbound.swift:41` | DEAD (rides on dead `sessionHistory`) |
| Bus protocol version constant | `packages/Bus/Sources/Bus/Protocol.swift:28` (`BUS_PROTOCOL_VERSION = "2.3.0"`) | ALIVE |
| Handshake state machine + 2 s timeout | `packages/Bus/Sources/Bus/WebviewBridge.swift:147-288` (`startHandshake` to `handleHelloAck` to `handleTimeout`) | ALIVE |
| Hard-block alert presenter (handshake mismatch / timeout) | `packages/Bus/Sources/Bus/WebviewBridge.swift:34` typealias; production wiring `App/AppDelegate.swift:2058-2060` to `Shell.TCCAlertService.presentHardBlock` | ALIVE |
| Bus reply (`{ok:true}` or error) for inbound JS messages | `packages/Bus/Sources/Bus/BusReply.swift`; routed inside `handleInboundString` `packages/Bus/Sources/Bus/WebviewBridge.swift:222,236` | ALIVE |

## 3. AgentOrchestrator + LLM provider

Defined by `AgentOrchestrator` actor
(`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`).

| Capability | Site | Notes |
| --- | --- | --- |
| `submit(_ input: TurnInput) -> SubmitOutcome` (start a new turn) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:152` | ALIVE |
| `cancelAndSubmit(_ input: TurnInput) -> SubmitOutcome` (barge-in primitive) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:159` | ALIVE |
| `TurnInput.text(_:)` factory | `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift:42` | ALIVE |
| `TurnInput.voice(_:)` factory | `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift:46` | DEAD (B-04) — voice path never produces text |
| `TurnInput.withImages(source:text:images:)` factory (vision dispatch) | `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift:52` | DEAD (B-03) — depends on `frameAttachRequested` |
| `SubmitOutcome.ran / superseded / rejected` | `packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift:16-30` | ALIVE |
| `RejectReason.turnInFlight / providerUnavailable / configError` | `packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift:27` | ALIVE (`turnInFlight` only in practice) |
| `turnHadImage(_:) -> Bool` (read-only inspection) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:131` | ALIVE (paired with B-03) |
| `turnSourceWasVoice(_:) -> Bool` | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:140` | ALIVE |
| `events: BoundedAsyncChannel<OrchestratorEvent>` (the orchestrator's outbound stream) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:77` | ALIVE |
| `OrchestratorEvent.stateChange / tokenDelta / thinkingDelta / toolCardUpdate / usage / turnEnd / error` | `packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift:13-22` | ALIVE |
| `ToolCardUpdate.Phase {pending,running,awaitingApproval,completed,failed}` | `packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift:27` | ALIVE |
| Conversation history threading (prior user/assistant turns prepended to messages array) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:283-286` (only `[system, user(input.userText)]` — no history fetch) | DEAD (B-02) — no prior turns prepended; "yes"/"why?" loses context |
| Per-turn `cacheHints.eligibleForSystemPrompt(...)` gating | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:297` | ALIVE |
| Untrusted-content nonce wrapper around tool results | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:266-282` (uses `UntrustedWrapper`) | ALIVE (SEC-06) |
| Cap-recovery `toolChoice: .none` at budget exhaustion (AGENT-07) | `packages/AgentCore/Sources/AgentCore/ToolChoice.swift:17`; orchestrator branches at runTurnLoop | ALIVE |
| `streamTruncated` 1-shot retry with fresh `retryTurnId` (AGENT-09) | retry branch in `runTurnLoop` (`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:601-650`) | ALIVE |
| Vision-tier T1 to T2 escalation under SAME `turnId` | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` (escalation branch) + `packages/Vision/Sources/Vision/VisionRouter.swift:63` post-response check | DEFERRED — depends on T2 sidecar (`MissingT2Provider` is the default conformer) |
| `BusForwarder.drain(events:sink:)` translation OrchestratorEvent to BusOutbound | `packages/AgentCore/Sources/AgentOrchestrator/BusForwarder.swift:32`, `BusForwarderSink` `:112` | ALIVE |
| `LLMProvider.stream(messages:tools:toolChoice:model:maxOutputTokens:cacheHints:)` (text) | `packages/AgentCore/Sources/AgentCore/LLMProvider.swift:26` | ALIVE |
| `LLMProvider.stream(messages:images:tools:toolChoice:model:maxOutputTokens:cacheHints:)` (multimodal) | `packages/AgentCore/Sources/AgentCore/LLMProvider.swift:41`; default forwards to text when `images.isEmpty` `:55` | DEAD via image path (B-03) |
| `AnthropicProvider` (Claude Opus 4.7 streaming) | `packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift:23,45,73` | ALIVE |
| `OllamaProvider` (Qwen 2.5 / OpenAI-compatible) | `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift:21,36,63` | DEFERRED — Ollama provider toggle exists but Anthropic is the default |
| `VllmMlxProvider` (vision T2 candidate) | `packages/Vision/Sources/Vision/VllmMlxProvider.swift:17` | DEFERRED |
| `MissingT2Provider` placeholder (precondition-fails on call) | `packages/Vision/Sources/Vision/MissingT2Provider.swift:24` | ALIVE-as-stub |
| `LLMEvent` cases — `messageStart, textDelta, thinkingDelta, toolUseRequested, toolUseBuffering, partialToolUseAtDisconnect, stopReason, usage, providerError, messageStop` | `packages/AgentCore/Sources/AgentCore/LLMEvent.swift:15` | ALIVE |
| `StopReason.endTurn / toolUse / maxTokens / refusal / streamTruncated` | `packages/AgentCore/Sources/AgentCore/LLMEvent.swift:33` | ALIVE |
| `TurnUsage` (input/output/cache-creation/cache-read tokens) | `packages/AgentCore/Sources/AgentCore/LLMEvent.swift:61` | ALIVE |
| `DevSnapshot` + `DevSnapshotEmitter` (token + tool-call snapshot for DevOverlay) | `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshot.swift:20`, `DevSnapshotEmitter.swift:22-92` | ALIVE |
| `TurnTranscriptStore.append / flushPair / discard` (per-turn user+assistant text accumulation, fed to memory extraction) | `packages/AgentCore/Sources/AgentOrchestrator/TurnTranscriptStore.swift:23-69` | ALIVE |
| `ToolDispatcher` protocol (orchestrator's tool seam) | `packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift:11` | ALIVE |
| `ProviderSelection.{anthropic,ollama}` switch | `packages/Config/Sources/Config/ProviderSelection.swift:3` | ALIVE |
| Provider identity for system prompt (`claude-opus-4-7` literal) | `App/AppDelegate.swift:1614-1622` (`SelfStateAdapter.providerIdentity`) | ALIVE (B-08 — model name returned correctly but downstream paraphrase) |

## 4. VoiceController + voice subsystem

Defined by `VoiceController` actor
(`packages/Voice/Sources/Voice/VoiceController.swift`).

| Capability | Site | Notes |
| --- | --- | --- |
| `start()` (spawn wake-word + orchestrator consumers) | `packages/Voice/Sources/Voice/VoiceController.swift:151` | DEAD (B-04) — controller starts but receives no audio frames |
| `shutdown()` | `packages/Voice/Sources/Voice/VoiceController.swift:162` | ALIVE |
| `pttDown()` | `packages/Voice/Sources/Voice/VoiceController.swift:190` | DEAD — PTT key never reaches actor (no hotkey bound by default; Input Monitoring may be denied) |
| `pttUp()` | `packages/Voice/Sources/Voice/VoiceController.swift:206` | DEAD (paired with pttDown) |
| `muteWakeWord()` / `unmuteWakeWord()` | `packages/Voice/Sources/Voice/VoiceController.swift:215,221` | DEAD (paired with B-04) |
| `handleAECUnavailable()` / `handleAECRestored()` (banner toggle) | `packages/Voice/Sources/Voice/VoiceController.swift:229,237` | ALIVE (banner path) |
| `setAudioLevelEmitter(_:)` cross-actor setter | `packages/Voice/Sources/Voice/VoiceController.swift:105` | ALIVE |
| Voice state machine `VoiceState.{idle, listening(source), thinking, speaking, reconfiguring(reason)}` | `packages/Voice/Sources/Voice/VoiceState.swift:21` | ALIVE-as-state |
| `ListeningSource.{wakeWord, ptt}` | `packages/Voice/Sources/Voice/VoiceState.swift:30` | ALIVE-as-state |
| `VoiceHudIntent.{silent, listening, reconfiguring}` (HUD intent stream) | `packages/Voice/Sources/Voice/VoiceInterfaces.swift:77` | ALIVE-as-state |
| `VoiceOrchestratorInterface.submit / cancelAndSubmit / voiceEvents` | `packages/Voice/Sources/Voice/VoiceInterfaces.swift:24-36` | ALIVE (production conformer `App/Voice/VoiceOrchestratorAdapter.swift:17`) |
| `VoiceTTSInterface.synthesize / cancelTTS / hasSynthInFlight` | `packages/Voice/Sources/Voice/VoiceInterfaces.swift:44-53` | DEAD (B-05) — interface invoked, but production adapter `App/Voice/VoiceTTSAdapter.swift:25` is not driven on assistant text |
| `VoiceBannerInterface.showBanner / dismissBanner` | `packages/Voice/Sources/Voice/VoiceInterfaces.swift:61-66` | ALIVE |
| `BusOutboundEmitter.postAudio(_:)` (Voice to Bus seam) | `packages/Voice/Sources/Voice/VoiceInterfaces.swift:95-98`, prod adapter `App/Voice/VoiceBusEmitterAdapter.swift:10` | DEAD (B-04) |
| `WakeWordDAG.start / pause / resume / cancel / stopFeed` | `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift:67-158` | DEAD (B-04) |
| `OpenWakeWordSession.feed / runDetection / DetectionDecision / WakeWordEvent` | `packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift:94,108,213,392,398` | DEAD (B-04) |
| `SileroVAD.feed / reset / loadedOpset` | `packages/Voice/Sources/Voice/VAD/SileroVAD.swift:121,190,238,268,292` | DEAD (B-04) |
| `STTProvider.transcribe(stream:) / finalize() async throws -> String` (protocol) | `packages/Voice/Sources/Voice/STT/STTProvider.swift:31` | DEAD (B-04) |
| `SpeechAnalyzerSTT` (primary STT, macOS 26 Tahoe) | `packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:60,75,120` | DEAD (B-04) |
| `WhisperKitSTT` (fallback STT, feature-flag gated) | `packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift:57,68,131` | DEFERRED |
| `STTBackendSelector` (chooses SpeechAnalyzer vs WhisperKit) | `packages/Voice/Sources/Voice/STT/STTBackendSelector.swift:28` | ALIVE-as-selector |
| `TTSEngineActor.synthesize(_:tier:voice:) / cancel() / hasSynthInFlight` | `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift:91,192,47` | DEAD (B-05) for assistant text path; ALIVE in unit tests |
| `AVSpeechSynth.speak / stop` (TTS tier 1) | `packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift:56,72` | DEAD (B-05) |
| `OrpheusTTS.synthesize / cancel` (TTS tier 2 streaming, Apple Silicon MLX) | `packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift:83,125` | DEFERRED |
| `TTSKitFallback.synthesize` (TTS tier 2 fallback) | `packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift:35,52` | DEFERRED |
| `InterruptSequence` (3-step barge-in for TTS) + `InterruptStepRecorder` | `packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift:51,27` | DEFERRED |
| `BufferBroadcaster.subscribe / publish / unsubscribe` (audio fan-out) | `packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift:91,114` | DEAD (B-04) |
| `AudioLevelEmitter.start / stop` (~30 Hz RMS computation) | `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:71,108` | DEAD (B-04) |
| `MuteWakeWord` toggle wrapper | `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift:39,108` | DEAD (B-04) |
| `PushToTalk.bind(keyCode:) / unbind` | `packages/Voice/Sources/Voice/Control/PushToTalk.swift:43,58,114,125` | DEAD — PTT remains unbound at launch (`App/AppDelegate.swift:1015`) |
| AEC degradation banner copy | `App/Voice/VoiceOrchestratorAdapter.swift:110-118` (`bannerForReason`) + `App/Voice/RejectReasonCopy.swift` | ALIVE |
| Mic TCC request (`AVCaptureDevice.requestAccess(for:.audio)`) | `App/AppDelegate.swift:864` | ALIVE |
| Production chunk pump (audio frames to STT continuation) | `App/Voice/ProductionChunkPump.swift:34` (`makeProductionChunkPump`) | DEAD (B-04) — no frames |
| `TTSTier.{tier1, tier2}` selection | `packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift:14`, used by `TTSEngineActor.synthesize` | ALIVE-as-config |

## 5. Memory: store + hybrid search + extraction

Defined under `packages/Memory/Sources/Memory/`.

| Capability | Site | Notes |
| --- | --- | --- |
| `MemoryStore.applyOp(_:sourceTurnId:) -> Fact?` (ADD / UPDATE / NOOP commit) | `packages/Memory/Sources/Memory/MemoryStore.swift:92` | ALIVE |
| `MemoryStore.recordRetrieval(_:triggerTurnId:)` (emit `memoryRetrieval` to replay) | `packages/Memory/Sources/Memory/MemoryStore.swift:239` | ALIVE |
| `MemoryStore.runHybridSearchSQL(query:embedding:k:)` (FTS5 + vec0 hybrid) | `packages/Memory/Sources/Memory/MemoryStore.swift:271` | ALIVE |
| `MemoryStore.recentActiveFacts(limit:)` | `packages/Memory/Sources/Memory/MemoryStore.swift:307` | ALIVE |
| `MemoryStore.queryActiveFacts(matching subject:)` | `packages/Memory/Sources/Memory/MemoryStore.swift:328` | ALIVE |
| `MemoryStore.recentTurnsForSession(sessionId:limit:) -> [TurnRow]` (B-02 raw material — exists but unused by orchestrator) | `packages/Memory/Sources/Memory/MemoryStore.swift:347` | DEAD path for orchestrator history; ALIVE for `SessionHistory` actor |
| `MemoryStore.forgetFact(id:triggerTurnId:) -> Bool` (D-02 forgetting) | `packages/Memory/Sources/Memory/MemoryStore.swift:369` | ALIVE |
| `MemoryStore.searchFacts(...)` | `packages/Memory/Sources/Memory/MemoryStore.swift:491` | ALIVE |
| `MemoryStore.factById(_:)` | `packages/Memory/Sources/Memory/MemoryStore.swift:503` | ALIVE |
| `MemoryStore.activeFacts(subject:predicate:)` | `packages/Memory/Sources/Memory/MemoryStore.swift:542` | ALIVE |
| `MemoryStore.setReplayLog(_:)` (sink wiring) | `packages/Memory/Sources/Memory/MemoryStore.swift:83` | ALIVE |
| `MemoryStore.querySingleString(_:) / queryRowCount(_:) / rawCountFacts(predicate:)` (diagnostic / test surface) | `packages/Memory/Sources/Memory/MemoryStore.swift:64,71,531` | ALIVE-as-diagnostic |
| `Fact` (subject/predicate/object + valid_from/valid_to/superseded_by/forgotten_at) | `packages/Memory/Sources/Memory/Fact.swift:10-22` | ALIVE |
| `MemoryOp` (ADD / UPDATE / NOOP) + `FactRef` (search-result envelope) | `packages/Memory/Sources/Memory/MemoryEvent.swift:7,91` | ALIVE |
| `HybridSearch.searchFacts(query:k:triggerTurnId:) -> [FactRef]` (embedding + FTS combiner; calls `MemoryStore.runHybridSearchSQL` and emits `recordRetrieval`) | `packages/Memory/Sources/Memory/HybridSearch.swift:32` | ALIVE |
| `EmbeddingProviding.embed(_:) -> [Float]` protocol | `packages/Memory/Sources/Memory/HybridSearch.swift:5` | ALIVE |
| `OllamaEmbeddingClient` (nomic-embed-text 768-dim) | `packages/Memory/Sources/Memory/OllamaEmbeddingClient.swift` | DEFERRED — gated on `JARVIS_REAL_MODELS` + Ollama running |
| `SessionHistory.recentTurns(sessionId:limit:)` (read-only TurnRow accessor) | `packages/Memory/Sources/Memory/SessionHistory.swift:14,24` | ALIVE-but-unused-by-orchestrator (B-02) |
| `MemoryExtractionOrchestrator.start / enqueue / shutdown` (background extractor pump) | `packages/Memory/Sources/Memory/MemoryExtractionOrchestrator.swift:60,76,89,94` | ALIVE |
| `MemoryExtractionCoordinator.start(events:) / stop` (orchestrator to extractor bridge listening on `OrchestratorEvent.turnEnd`) | `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift:25,49,84` | ALIVE |
| `MemoryEnqueueing.enqueue(_:)` protocol seam | `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift:11` | ALIVE |
| `MemoryReplaySink` (Memory to Replay log seam) | `packages/Memory/Sources/Memory/MemoryStore.swift:13` (production wiring `App/AppDelegate.swift:2367+`) | ALIVE |
| `MemoryTools` (subject/predicate/object literal helpers) | `packages/Memory/Sources/Memory/MemoryTools.swift:9` | ALIVE |
| `MemoryExtractor` (mem0-style ADD/UPDATE/NOOP LLM extractor) | `packages/Memory/Sources/Memory/MemoryExtractor.swift` | ALIVE |
| `MemoryPrompts` (extractor prompt strings) | `packages/Memory/Sources/Memory/MemoryPrompts.swift` | ALIVE |
| `ReplayEvent.memoryMutation(Data)` / `memoryRetrieval(Data)` (single-emission-site enforced) | `packages/Replay/Sources/Replay/ReplayEvent.swift:120,126` | ALIVE |

## 6. Vision: router, frame attach, camera, presence

Defined under `packages/Vision/Sources/Vision/` and `App/Vision/`.

| Capability | Site | Notes |
| --- | --- | --- |
| `CameraCapture.open() / shutdown() / captureFrame() / becameAuthorized()` | `packages/Vision/Sources/Vision/CameraCapture.swift:72,98,122,94` | ALIVE on TCC grant; DEAD if denied |
| `CameraCapture.degradationStream` (camera-denied / mid-session-revoked banner driver) | `App/AppDelegate.swift:1820-1830` consumes the stream | ALIVE |
| Camera TCC request (`AVCaptureDevice.requestAccess(for:.video)`) | `App/AppDelegate.swift:1846` | ALIVE |
| `CapturedFrame` (jpeg/width/height/timestamp) | `packages/Vision/Sources/Vision/CapturedFrame.swift:11` | ALIVE |
| `PresenceFrameSample` (CVPixelBuffer wrapper for presence tap) | `packages/Vision/Sources/Vision/CameraCapture.swift:255` | DEFERRED |
| `FrameAttachController.requestAttach(reason:)` (HUD-button or phrase trigger arms a 5 s capture window) | `packages/Vision/Sources/Vision/FrameAttachController.swift:68` | DEAD (B-03) |
| `FrameAttachController.confirmSend(userText:) -> ImageBlock?` (consume pending frame) | `packages/Vision/Sources/Vision/FrameAttachController.swift:104` | DEAD (B-03) |
| `FrameAttachController.cancel()` | `packages/Vision/Sources/Vision/FrameAttachController.swift:115` | DEAD (B-03) |
| `FrameAttachController.onAssistantTurnComplete()` (release pending frame after image-bearing turn end) | `packages/Vision/Sources/Vision/FrameAttachController.swift:133` | DEAD (B-03) |
| `FrameAttachController.hasPendingFrame: Bool` | `packages/Vision/Sources/Vision/FrameAttachController.swift:61` | ALIVE-as-query |
| `FrameAttachController.AttachReason.{hudButton, phraseDetected(in:)}` | `packages/Vision/Sources/Vision/FrameAttachController.swift:35` | DEAD (B-03) |
| `FrameAttachReplaySink.recordImageTurn(text:)` (placeholder JSON only — no raw bytes) | `packages/Vision/Sources/Vision/FrameAttachReplaySink.swift:31` | DEAD (B-03) |
| `FrameConfirmationDecision` (sent / cancelled / timed-out) | `packages/Vision/Sources/Vision/FrameConfirmationDecision.swift:9` | DEAD (B-03) |
| `VisionRouter.route(...)` (T1/T2 dispatch decision) | `packages/Vision/Sources/Vision/VisionRouter.swift:50` | DEAD (B-03) |
| `VisionRouter` post-response escalate-to-T2 heuristic | `packages/Vision/Sources/Vision/VisionRouter.swift:63` | DEAD (B-03) |
| `VisionRouter.providerForTier(_:) -> any LLMProvider` | `packages/Vision/Sources/Vision/VisionRouter.swift:80` | DEFERRED (T2 = MissingT2Provider in production) |
| `VisionTier.{t1, t2}` | `packages/Vision/Sources/Vision/VisionTier.swift` | DEAD (B-03) |
| `VisionRouter.EscalationOutcome.{accept, escalateToT2}` | `packages/Vision/Sources/Vision/VisionRouter.swift:27` | DEAD (B-03) |
| `EscalationKind.t1ToT2` replay marker | `packages/Replay/Sources/Replay/ReplayEvent.swift:82`, emitted at orchestrator escalation site | DEAD (B-03) |
| `VisionEscalationHeuristic` (low-confidence detector) | `packages/Vision/Sources/Vision/VisionEscalationHeuristic.swift:15` | DEFERRED |
| `VllmMlxAvailability.Configuration` (T2 sidecar feature flag + binary URL) | `packages/Vision/Sources/Vision/VllmMlxAvailability.swift:16` | DEFERRED |
| `VllmMlxSidecar.ensureRunning() / shutdown()` (Python sidecar lifecycle) | `packages/Vision/Sources/Vision/VllmMlxSidecar.swift:148,209` | DEFERRED |
| `ContextBuilder.matchesFrameAttachPhrase(_:)` (e.g. "what am I looking at?") | `packages/Vision/Sources/Vision/ContextBuilder.swift:21` | ALIVE-as-detector (caller B-03 dead) |
| `ContextBuilder.matchesCloudOptIn(_:)` (cloud-vision opt-in phrase) | `packages/Vision/Sources/Vision/ContextBuilder.swift:28` | DEFERRED |
| `PresenceMonitor.start / pause / resume / cancel` (face-presence detection) | `packages/Vision/Sources/Vision/PresenceMonitor.swift:50,62,69,77` | DEFERRED |
| `PresenceSignalBus.stream` (subscribers: HudStateCoordinator + PresenceStateSnapshot) | `packages/Vision/Sources/Vision/PresenceSignalBus.swift:15-16` | DEFERRED |
| `PresenceEvent.{enter, exit, ...}` / `Presence.{atDesk, away, ...}` | `packages/Vision/Sources/Vision/PresenceEvent.swift:9,22` | DEFERRED |
| `PresenceStateSnapshot.record(_:) / currentEnrichment(now:)` (system-prompt augmentation) | `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift:26,42` | DEFERRED |
| `DisablePresence` toggle (test seam) | `packages/Vision/Sources/Vision/DisablePresence.swift:23,54` | DEFERRED |
| `VisionDegradationReason.{cameraDenied, midSessionRevoked, ...}` | `packages/Vision/Sources/Vision/VisionDegradationReason.swift:7` | ALIVE |

## 7. MCP runtime + tool dispatch

Defined under `packages/MCP/Sources/MCP/` and `App/MCP/`.

| Capability | Site | Notes |
| --- | --- | --- |
| `MCPClient.register(name:binaryURL:requiresConfirmation:)` (stdio helper) | `packages/MCP/Sources/MCP/MCPClient.swift:75,87` | ALIVE |
| `MCPClient.callTool(name:arguments:)` | `packages/MCP/Sources/MCP/MCPClient.swift:136` | ALIVE |
| `MCPClient.toolMetadata(_:)` | `packages/MCP/Sources/MCP/MCPClient.swift:189` | ALIVE |
| `MCPClient.registeredServerNames() / registeredToolNames()` | `packages/MCP/Sources/MCP/MCPClient.swift:200,204` | ALIVE |
| `MCPClient.toolCatalog() -> [ToolSchema]` (10-02b stdio enumeration) | `packages/MCP/Sources/MCP/MCPClient.swift:216` | ALIVE |
| `MCPClient.shutdown()` | `packages/MCP/Sources/MCP/MCPClient.swift:247` | ALIVE |
| `MCPServerHandle.start / shutdown / setRestartTask / claimOrShareRestart / callTool / listTools` | `packages/MCP/Sources/MCP/MCPServerHandle.swift:80,198,221,234,249,265` | ALIVE |
| `ToolMetadata.{name, server, requiresConfirmation}` | `packages/MCP/Sources/MCP/MCPClient.swift:24` | ALIVE |
| `ToolRegistry.server(forTool:) / requiresConfirmation(toolName:) / toolNames` | `packages/MCP/Sources/MCP/ToolRegistry.swift:40,44,50` | ALIVE |
| `MCPToolDispatcher.dispatch(toolUse:) -> Data` (stdio fallback path) | `packages/MCP/Sources/MCP/MCPToolDispatcher.swift:91` | ALIVE |
| `ConfirmingToolDispatcher.dispatch(toolUse:)` (HUD confirmation gating) | `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:104` | ALIVE |
| `BusGateway.emitToolCallStart / updateArgsPreview / emitToolCallEnd` (dispatcher to bus seam) | `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:51`, prod `App/MCPBusGatewayAdapter.swift:55-77` | ALIVE |
| `ConfirmationBroker.request(...) / response(id:outcome:)` + 60 s timeout | `packages/MCP/Sources/MCP/ConfirmationBroker.swift:36,61,114` | ALIVE |
| `ConfirmationOutcome.{approved, denied, timedOut}` | `packages/MCP/Sources/MCP/ConfirmationOutcome.swift` | ALIVE |
| `ConfirmationPresenter.show(id:toolName:argsPreview:) / dismiss(id:)` (HUD-side modal) | `packages/MCP/Sources/MCP/ConfirmationPresenter.swift:59`, prod indirection `App/MCP/MCPRuntimeWiring.swift:221` | ALIVE |
| `InProcessTool` protocol (`name`, `toolDescription`, `requiresConfirmation`, `schemaJSON`, `call(args:)`) | `packages/MCP/Sources/MCP/InProcess/InProcessTool.swift:10` | ALIVE |
| `InProcessToolRegistry.register / contains / dispatch / registered / toolSchemas / confirmationCache` | `packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift:51-92` + `:21-43` (cache struct) | ALIVE |
| `InProcessAwareToolDispatcher.dispatch(toolUse:)` (composite that routes in-process tools, falls through to stdio) | `packages/MCP/Sources/MCP/InProcess/InProcessAwareToolDispatcher.swift:55,76` | ALIVE (B-01b fix) |
| `InProcessConfirmationCache` (sync `requiresConfirmation` lookup for outer ConfirmingToolDispatcher) | `packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift` (cache struct on the registry) | ALIVE (B-01b fix) |
| Stdio MCP tool: `get_time` (mcp-time helper) | registered `App/MCP/MCPRuntimeWiring.swift:101,118` | ALIVE |
| Stdio MCP tool: `get_clipboard` (mcp-clipboard helper) | registered `App/MCP/MCPRuntimeWiring.swift:106,119` | ALIVE |
| Stdio MCP tool: `run_applescript` (mcp-applescript helper, requires confirmation) | registered `App/MCP/MCPRuntimeWiring.swift:111,120` | ALIVE (gated) |
| In-process tool: `forget_fact` (Memory mutation, requires confirmation) | type `packages/MCP/Sources/MCP/InProcess/ForgetFactTool.swift:11`; registration `App/AppDelegate.swift:1210` | ALIVE |
| In-process tool: `search_memory` (HybridSearch wrapper) | type `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift:27`; registration `App/AppDelegate.swift:1213` | ALIVE |
| In-process tool: `search_conversation` (SessionHistory wrapper) | type `packages/MCP/Sources/MCP/InProcess/SearchConversationTool.swift:26` | RETIRED-CANDIDATE — type + tests exist; no production registration found |
| In-process tool: `get_self_state` (SELF-03) | type `packages/MCP/Sources/MCP/InProcess/GetSelfStateTool.swift:57`; registration `App/AppDelegate.swift:1661` | ALIVE (B-08 paraphrase) |
| In-process tool: `list_audio_devices` (SELF-01) | type `packages/MCP/Sources/MCP/InProcess/ListAudioDevicesTool.swift:50`; registration `App/AppDelegate.swift:1573` | ALIVE |
| In-process tool: `list_camera_devices` (SELF-04) | type `packages/MCP/Sources/MCP/InProcess/ListCameraDevicesTool.swift`; registration `App/AppDelegate.swift:1576` | ALIVE |
| In-process tool: `get_active_audio_route` (SELF-02) | type `packages/MCP/Sources/MCP/InProcess/GetActiveAudioRouteTool.swift`; registration `App/AppDelegate.swift:1585` (skipped if `audioGraphOwner` nil) | ALIVE on voice success; DEFERRED otherwise |
| `availableToolsResolver` (lazy late-bound `[ToolSchema]` for the orchestrator) | wired `App/AppDelegate.swift:1161-1185` (`buildInProcessToolRegistry`) into `AgentOrchestrator.init(availableToolsResolver:)` `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:108` | ALIVE (10-02b fix) |
| `MCPRuntime` aggregate (`client`, `dispatcher`, `presenter`, `broker`, `toolResultObserver`) | `App/MCP/MCPRuntimeWiring.swift:56-62` | ALIVE |
| `MCPRuntimeWiring.build(...)` (production builder, registers helpers, composes dispatcher chain) | `App/MCP/MCPRuntimeWiring.swift:89` | ALIVE |
| `MCPRuntimeWiring.compose(...)` (test seam) | `App/MCP/MCPRuntimeWiring.swift:184` | ALIVE-as-test-seam |
| `ConfirmationPresenterHolder` (cycle-breaking presenter indirection) | `App/MCP/MCPRuntimeWiring.swift:221-246` | ALIVE |
| `ToolResultObserver.observe(...)` (replay-log observer protocol) | `packages/MCP/Sources/MCP/MCPToolDispatcher.swift:60` | ALIVE |
| `ReplayingToolResultObserver` (production observer producing into orch->replay channel) | `App/MCP/ReplayingToolResultObserver.swift:84,88` | ALIVE |
| `SanitizeForModel` (sanitize tool result text bytes) | `packages/MCP/Sources/MCP/SanitizeForModel.swift:30` | ALIVE |
| Per-server restart on crash | `MCPServerHandle.claimOrShareRestart` `:234` + start path `:80` | ALIVE |
| Helper child-process spawn through `ChildSpawnGate` (FD_CLOEXEC, minimal env) | `packages/MCP/Sources/JarvisChildSpawn/` (consumed via `MCPServerHandle.start`) | ALIVE |
| `ToolSchema.{name, description, inputSchema}` (provider-facing tool definition) | `packages/AgentCore/Sources/AgentCore/ToolSchema.swift:9` | ALIVE |

## 8. Config + feature flags + Keychain

Defined under `packages/Config/`, `packages/Keychain/`, and consumed
throughout AppDelegate.

| Capability | Site | Notes |
| --- | --- | --- |
| `ConfigStore.launch: LaunchSnapshot` (immutable per-launch config) | `packages/Config/Sources/Config/ConfigStore.swift:6` | ALIVE |
| `ConfigStore.perTurn() -> PerTurnSnapshot` | `packages/Config/Sources/Config/ConfigStore.swift:15` | ALIVE |
| `ConfigStore.updatePerTurn(_:)` | `packages/Config/Sources/Config/ConfigStore.swift:19` | ALIVE |
| `ConfigStore.stream() -> AsyncStream<PerTurnSnapshot>` (per-turn change subscribers) | `packages/Config/Sources/Config/ConfigStore.swift:24` | ALIVE |
| `ConfigLoader.loadSnapshots(from:)` (file to LaunchSnapshot + PerTurnSnapshot) | `packages/Config/Sources/Config/ConfigLoader.swift:4` | ALIVE |
| `ConfigLoader.bundledDefaultConfigURL()` | `packages/Config/Sources/Config/ConfigLoader.swift:36` | ALIVE |
| `ConfigLoader.writeDefaultAndReload(to:)` | `packages/Config/Sources/Config/ConfigLoader.swift:41` | ALIVE |
| `LaunchSnapshot.{schemaVersion, ollama, applescript, toolBlocklist, confirmationPolicy, logging}` | `packages/Config/Sources/Config/LaunchSnapshot.swift:3` | ALIVE |
| `PerTurnSnapshot.{schemaVersion, provider, tts, stt, featureFlags}` | `packages/Config/Sources/Config/PerTurnSnapshot.swift:3` | ALIVE |
| `ProviderSelection.{anthropic, ollama}` | `packages/Config/Sources/Config/ProviderSelection.swift:3` | ALIVE |
| `OllamaConfig.baseURL` (URL of local Ollama daemon) | `packages/Config/Sources/Config/OllamaConfig.swift:6` | ALIVE |
| `AppleScriptPolicy.confirmationRequired` | `packages/Config/Sources/Config/AppleScriptPolicy.swift:3` | ALIVE |
| `ConfirmationPolicy.timeoutSeconds` (default 60s) | `packages/Config/Sources/Config/ConfirmationPolicy.swift:3` | ALIVE |
| `STTConfig.whisperKitFallback` | `packages/Config/Sources/Config/STTConfig.swift:3` | ALIVE |
| `TTSConfig.tier` (`"tier1"` / `"tier2"`) | `packages/Config/Sources/Config/TTSConfig.swift:3` | ALIVE |
| `LoggingLaunchConfig.{fileLevel, osLogLevel}` | `packages/Config/Sources/Config/LoggingLaunchConfig.swift:3` | ALIVE |
| `FeatureFlag.orpheusTTSEnabled` | `packages/Config/Sources/Config/FeatureFlags.swift:10` | DEFERRED |
| `FeatureFlag.whisperKitSTTEnabled` | `packages/Config/Sources/Config/FeatureFlags.swift:11` | DEFERRED |
| `FeatureFlags.isEnabled(_:)` typo-safe lookup | `packages/Config/Sources/Config/FeatureFlags.swift:24` | ALIVE |
| `FeatureFlags.isEnabledDynamic(_:)` (DevOverlay listing) | `packages/Config/Sources/Config/FeatureFlags.swift:32` | ALIVE |
| `SchemaMigrator` (config schema-version migrations) | `packages/Config/Sources/Config/SchemaMigrator.swift` | ALIVE |
| `tool_blocklist` (LaunchSnapshot field, dispatcher-side allow filter) | `packages/Config/Sources/Config/LaunchSnapshot.swift:7` | ALIVE-as-config |
| Config file path (`~/Library/Application Support/Jarvis/config.json`) | `App/AppDelegate.swift:2280` (`configFileURL`) | ALIVE |
| `UserDefaults: features.voice.wakeWordMuted` | `App/AppDelegate.swift:1649` | ALIVE-as-flag |
| `UserDefaults: hotkey` (KeyboardShortcut JSON, persisted by `WizardState.hotkey`) | `App/Wizard/WizardState.swift:31` | ALIVE |
| `UserDefaults: inputMonitoringGranted / inputMonitoringProbed / apiKeyStored / currentStage` (WizardState `@Published` mirrors) | `App/Wizard/WizardState.swift:27-30` | ALIVE |
| `KeychainStore` protocol (`get / set / delete`) | `packages/Keychain/Sources/Keychain/KeychainStore.swift:3` | ALIVE |
| `SystemKeychainStore` (production conformer; `kSecClassGenericPassword` items) | `packages/Keychain/Sources/Keychain/SystemKeychainStore.swift` | ALIVE |
| `KeychainItem.anthropic` (Anthropic API key under stable label) | `packages/Keychain/Sources/Keychain/KeychainItem.swift` | ALIVE |
| `AnthropicAPIKeyProvider` (Keychain-backed `Sendable` resolver consumed by `AnthropicProvider`) | `packages/AgentCore/Sources/AnthropicProvider/AnthropicAPIKeyProvider.swift:26` | ALIVE |
| `AnthropicKeyValidator.validate(key:)` (live Anthropic ping for wizard) | `App/Wizard/AnthropicKeyValidator.swift:62` | ALIVE |

## 9. Menu bar + global hotkey + window control

Defined in `App/MenuBar/`, `App/HUD/`, `packages/Shell/`, and AppDelegate.

| Capability | Site | Notes |
| --- | --- | --- |
| Menu-bar status item construction (`NSStatusItem` + icon controller) | `App/AppDelegate.swift:1977` (`installMenuBar`); `App/MenuBar/MenuBarIconController.swift` | ALIVE |
| Menu-bar left-click drives `toggleHUD()` (handshake-armed gated) | `App/AppDelegate.swift:1987,2004` | ALIVE |
| Menu item: **Setup...** (re-runs onboarding wizard) | `App/MenuBar/MenuBarContextMenu.swift:14` | ALIVE |
| Menu item: **Settings...** (settings window: API key, hotkey rebind, Input Monitoring) | `App/MenuBar/MenuBarContextMenu.swift:21` | ALIVE |
| Menu item: **Show Dev Overlay** (toggle DevOverlay window) | `App/MenuBar/MenuBarContextMenu.swift:26`; routes to `App/AppDelegate.swift:2249` (`toggleDevOverlay`) | ALIVE |
| Menu item: **Copy State Dump** (booleans-only diagnostic JSON to clipboard) | `App/MenuBar/MenuBarContextMenu.swift:27`; impl `App/AppDelegate.swift:2259` (`copyStateDump`) | ALIVE |
| Menu item: **Quit Jarvis** (`Cmd+Q`) | `App/MenuBar/MenuBarContextMenu.swift:31` | ALIVE |
| Menu item: **Voice Log** | (B-07) — not present in `MenuBarContextMenu` build call; Plan 10-05 unrun, salvage in `stash@{0}` | DEAD (B-07) |
| `JarvisHUDPanel.summon(on:) / dismiss() / isSummoned` (borderless transparent floating panel) | `App/HUD/JarvisHUDPanel.swift:99,122,95` | ALIVE |
| `HUDBannerPanel` + `HUDBannerCoordinator.enqueue(_:) / dismissCurrent() / clear() / currentBanner / queuedCount` (priority queue for native AppKit banners) | `App/HUD/HUDBannerCoordinator.swift:14,32,62,87,98,99` | ALIVE |
| Banner content variants (`BannerContent` predefined: AEC, camera-denied, hotkey-bind-failed, input-monitoring-denied, hud-not-ready, state-dump-copied, ...) | `App/HUD/BannerContent.swift` | ALIVE |
| `HudStateCoordinator.start(agent:voice:confirmation:) / markReady() / cancelAll() / attachPresence(_:)` (HUD-08 precedence-ladder resolver, single writer for `BusOutbound.hudState`) | `App/HUD/HudStateCoordinator.swift:59,102,108,135` | ALIVE |
| `HudStateBridge.busHudState(from:)` mapping `App.HudState` to `Bus.HudState` | `App/HUD/HudStateBridge.swift:22` | ALIVE |
| `AgentHudIntent.{idle, thinking, speaking}` | `App/HUD/HudStateIntent.swift:6` | ALIVE |
| `ConfirmHudIntent.{required, cleared}` | `App/HUD/HudStateIntent.swift:21` | ALIVE |
| Global hotkey binding (`HotkeyBinder.bind(...) / unbind() / currentShortcut`) — `NSEvent.addGlobalMonitorForEvents` based | `packages/Shell/Sources/Shell/HotkeyBinder.swift:90,110,137,96` | ALIVE on grant |
| Hotkey bind production wiring (Cmd+Shift+J etc, target = `toggleHUD`) | `App/AppDelegate.swift:2228-2240` (`bindHotkeyFromWizard`) | ALIVE on grant |
| Hotkey-bind-failed banner sink | `App/AppDelegate.swift:2178-2186` | ALIVE |
| Input Monitoring TCC probe (`HIDAccessProbe.requestListenEventAccess / isListenEventAccessGranted`) | `packages/Shell/Sources/Shell/InputMonitoringProbe.swift:24,30,58` | ALIVE |
| Input-Monitoring-denied banner | `App/AppDelegate.swift:2167-2169` (`AdHocBannerSink`) | ALIVE |
| `ShortcutRecorderView` (SwiftUI hotkey-recorder) + `KeyCapView` / `KeyCapRowView` | `packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift:14`, `KeyCapView.swift:8,30` | ALIVE |
| `KeyboardShortcut.{keyCode, modifiers, displayString}` | `packages/Shell/Sources/Shell/KeyboardShortcut.swift:12-34` | ALIVE |
| `CollisionDetector.detect(...)` (warn on Alfred/Raycast/etc.) | `packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift:11` | ALIVE |
| `LaunchAtLoginController.{isEnabled, requiresApproval, enable / disable / openSystemSettingsLoginItems}` (SMAppService wrapper) | `packages/Shell/Sources/Shell/LaunchAtLoginController.swift:19,21,28,35,44,54` | ALIVE |
| `TCCAlertService.presentHardBlock(title:informativeText:)` (NSAlert + terminate) | `packages/Shell/Sources/Shell/TCCAlertService.swift:7` | ALIVE |
| `OnboardingWizardController.open(...) / close()` + `WizardStage.{apiKey, tcc, hotkey}` | `App/Wizard/OnboardingWizardController.swift:25,31,98`, `App/Wizard/WizardState.swift:5,77` | ALIVE |
| `SettingsWindowController.open(...) / close()` (re-grant Input Monitoring, API key edit, hotkey rebind) | `App/Settings/SettingsWindowController.swift:22,29,66` | ALIVE |
| Wizard chapters: `WizardStageAPIKeyView`, `WizardStageTCCView`, `WizardStageHotkeyView` | `App/Wizard/WizardStage*.swift` | ALIVE |

## 10. ReplayLogger + DevOverlay + structured logs

Defined under `packages/Replay/`, `packages/DevOverlay/`,
`packages/Logging/`.

| Capability | Site | Notes |
| --- | --- | --- |
| `ReplayLog.beginSession(appVersion:buildSHA:) -> SessionID` | `packages/Replay/Sources/Replay/ReplayLog.swift:65` | ALIVE |
| `ReplayLog.startTurn(turnId:sessionId:retryOf:turnNonce:source:provider:modelId:)` | `packages/Replay/Sources/Replay/ReplayLog.swift:80` | ALIVE |
| `ReplayLog.record(_:for:)` (per-turn event append, batched) | `packages/Replay/Sources/Replay/ReplayLog.swift:113` | ALIVE |
| `ReplayLog.endTurn(_:stopReason:)` | `packages/Replay/Sources/Replay/ReplayLog.swift:140` | ALIVE |
| `ReplayLog.flush()` / `close()` | `packages/Replay/Sources/Replay/ReplayLog.swift:169,173` | ALIVE |
| Batch policy: 64 events / 50 ms window | `packages/Replay/Sources/Replay/ReplayLog.swift:17-18` | ALIVE-as-policy |
| Replay event: `userInput(Data)` | `packages/Replay/Sources/Replay/ReplayEvent.swift:101` | ALIVE |
| Replay event: `textDelta(String) / thinkingDelta(String)` | `packages/Replay/Sources/Replay/ReplayEvent.swift:102-103` | ALIVE |
| Replay event: `toolCallRequested(id:name:argsJSON:)` | `packages/Replay/Sources/Replay/ReplayEvent.swift:104` | ALIVE |
| Replay event: `toolResultFull(toolUseId:bytes:)` | `packages/Replay/Sources/Replay/ReplayEvent.swift:105` | ALIVE |
| Replay event: `usage(Data) / stopReason(String) / turnEnd / hudEvent(Data) / error(Data)` | `packages/Replay/Sources/Replay/ReplayEvent.swift:106-110` | ALIVE |
| Replay event: `memoryMutation(Data)` (single-emission-site = `MemoryStore.applyOp`) | `packages/Replay/Sources/Replay/ReplayEvent.swift:120` | ALIVE |
| Replay event: `memoryRetrieval(Data)` (single-emission-site = `MemoryStore.recordRetrieval`) | `packages/Replay/Sources/Replay/ReplayEvent.swift:126` | ALIVE |
| Replay event: `escalationAttempt(turnId:kind:)` (T1->T2 marker) | `packages/Replay/Sources/Replay/ReplayEvent.swift:134` | DEFERRED |
| `TurnSource.{text, voice, memoryExtraction, replay(sessionId:), eval(scenarioId:)}` cohort tag | `packages/Replay/Sources/Replay/ReplayEvent.swift:14-26` | ALIVE (`text`, `memoryExtraction` produced; `voice` DEAD per B-04; `replay` and harness-eval for offline runs) |
| `TurnSource.dispatchesToHUD / speaks` (HUD/TTS suppression for non-user turns) | `packages/Replay/Sources/Replay/ReplayEvent.swift:42,51` | ALIVE |
| `SessionID.fresh()` UUID factory | `packages/Replay/Sources/Replay/ReplayEvent.swift:70` | ALIVE |
| `OrphanDetector` (replay-log integrity probe) | `packages/Replay/Sources/Replay/OrphanDetector.swift` | ALIVE-as-test-tool |
| `TokenDeltaDropOldestChannel` (lossy-channel for replay token delta firehose) | `packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift` | ALIVE |
| `Schema.allStatements / pragmas / seedMeta` (SQLite DDL bootstrap) | `packages/Replay/Sources/Replay/Schema.swift:11,20,71` | ALIVE |
| `DevOverlayWindow.show / hide / toggle / isVisible` | `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift:50,54,58,60` | ALIVE (toggled via menu) |
| `DevOverlayBridge.attach(channel:) / detach()` (consume `DevSnapshot` channel) | `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift:30,44` | ALIVE |
| `DevOverlayViewModel.apply(_:) / reset()` | `packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift:32,38` | ALIVE |
| DevOverlay UI surfaces (provider/model, token counts, cache hit %, last 5 tool calls, TTFB / total ms per turn) | `packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift` driven by `DevSnapshot` `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshot.swift:20-61` | ALIVE |
| `DevSnapshotEmitter.subscribe(to: events) / setProvider(provider:modelId:) / cancel / apply` | `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:71,63,84,92` | ALIVE |
| `JarvisLogChannel.{agent, tools, ui, system, bus, replay, devoverlay, mcp}` (8 channels) | `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift:3` | ALIVE |
| `LoggingBootstrap.bootstrap(...)` | `packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift` | ALIVE |
| `OSLogHandler` + `FileLogHandler` + `FileRotatingWriter` (dual-sink swift-log handlers) | `packages/Logging/Sources/JarvisLogging/{OSLogHandler,FileLogHandler,FileRotatingWriter}.swift` | ALIVE |
| `LogPaths.appSupportLogs` (`~/Library/Application Support/Jarvis/Logs/`) | `packages/Logging/Sources/JarvisLogging/LogPaths.swift` | ALIVE |
| `Redact.string(_:)` (PII / token redaction helper) | `packages/Logging/Sources/JarvisLogging/Redact.swift` | ALIVE |

## 11. Misc — surfaces that don't fit neatly above

| Capability | Site | Notes |
| --- | --- | --- |
| `BoundedAsyncChannel<Element>` with `.suspend` / `.dropOldest` policy (orchestrator events, replay envelopes, dev snapshots) | `packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift:14,15,39,50,87,128,134` | ALIVE |
| `ImageBlock(mediaType:data:)` (Claude/Ollama vision payload) | `packages/AgentCore/Sources/AgentCore/ImageBlock.swift:16` | DEAD (B-03) |
| `LLMMessage.{Role, ContentBlock, untrusted}` (provider-agnostic message) | `packages/AgentCore/Sources/AgentCore/LLMMessage.swift:10-31` | ALIVE |
| `CacheHints.eligibleForSystemPrompt(...)` and `CacheTTL` (Anthropic prompt-cache shape) | `packages/AgentCore/Sources/AgentCore/CacheHints.swift:9-25` | ALIVE |
| `ToolChoice.{auto, any, named, none}` | `packages/AgentCore/Sources/AgentCore/ToolChoice.swift:17` | ALIVE |
| `ModelID.rawValue` wrapper | `packages/AgentCore/Sources/AgentCore/ModelID.swift:7` | ALIVE |
| `TurnID.rawValue` wrapper | `packages/AgentCore/Sources/AgentCore/TurnID.swift:5` | ALIVE |
| `TurnNonce.rawValue` (SEC-06 per-turn opaque token; never on bus, only in replay) | `packages/AgentCore/Sources/AgentCore/TurnNonce.swift:15` | ALIVE |
| `ConfirmationID.rawValue` wrapper | `packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift:19` | ALIVE |
| `TurnState.{idle, running(turnId:), awaitingConfirmation(turnId:)}` (orchestrator-side state) | `packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift:7` | ALIVE |
| Eval harness CLI (`packages/Harness/Sources/jarvis-eval/`) — eval matrix runner against Anthropic + local models | `packages/Harness/Sources/jarvis-eval/` | ALIVE-as-cli |
| `Harness` test-double library (MockLLMProvider, etc.) | `packages/Harness/Sources/Harness/` | ALIVE-as-test-lib |
| Webview-side `window.jarvisBus.receive(payload)` injection | `packages/Bus/Sources/Bus/Resources/Injection.js` (loaded via `WebviewBridge.installInjectionScript` `:127`) | ALIVE |
| Replay-roundtrip oracle (Phase 8 Plan 08-01) `TurnSource.replay(sessionId:)` swap path | `packages/Replay/Sources/Replay/ReplayEvent.swift:21` | DEFERRED |
| Harness-eval cohort `TurnSource.eval(scenarioId:)` for matrix runs | `packages/Replay/Sources/Replay/ReplayEvent.swift:26` | ALIVE-via-harness |
| `JarvisEntitlementsVerified` + `verify-entitlements.sh` boot gate | `App/AppDelegate.swift:438,448` `TCCAlertService.presentHardBlock`; `scripts/verify-entitlements.sh` | ALIVE |
| Boot-time hard-block (config-malformed, bundle-missing, entitlement-missing) | `App/AppDelegate.swift:438-448, 1964, 2148` | ALIVE |

## Coverage gaps / `???` flags

- **Webview-side bus client + chat panel scroll behavior (B-06).** The
  webview source lives at `webview/packages/hud/` and is out of scope for
  this Swift-side inventory. The Architect phase needs to expand into
  webview source to enumerate JS-side capabilities (chat panel state,
  scroll, message rendering, ring mesh consumers) — they consume the bus
  events listed above but expose their own component-level surface.
- **MCP helper-app tool schemas (`mcp-time`, `mcp-clipboard`,
  `mcp-applescript`).** Helper sources live at `mcp-servers/` and were
  not enumerated here at the per-tool-argument level — only the three
  tool *names* registered with `MCPClient`. The Architect can choose
  whether the API design represents helper tool argument schemas
  symmetrically with in-process tool schemas.
- **Webview chat session-history hydration emit site.** `BusOutbound
  .sessionHistory(turns:)` is documented as emitted "on webview-ready by
  AppDelegate (Plan 07-06)" but no production emit site was found by
  grep. Marked DEAD pending the Architect's confirmation that this is
  not just an "emit on uiReady" path I missed; if confirmed, the chat
  panel's first paint relies on `BusOutbound.sessionHistory` arriving
  before the user types.

## Statistics

- Total capabilities catalogued: **~190**
  - Bus inbound: 5
  - Bus outbound: 14
  - AgentOrchestrator + LLM provider: 28
  - VoiceController + voice subsystem: 31
  - Memory: 22
  - Vision: 24
  - MCP runtime + tool dispatch: 26
  - Config + Keychain: 24
  - Menu bar + hotkey + windows: 21
  - Replay + DevOverlay + Logging: 24
  - Misc: 17
- **ALIVE**: ~117
- **DEAD (wired but not invoked end-to-end)**: ~33 (B-02..B-08 cluster +
  every voice-graph capability that depends on B-04 + every vision
  capability that depends on B-03 + the four-line `BusOutbound
  .sessionHistory` emit gap)
- **DEFERRED** (flagged / placeholder, intentionally dormant): ~24
  (Orpheus tier-2, WhisperKit, Ollama path, T2 vision sidecar, presence
  pipeline, replay-roundtrip oracle, escalation marker, Cloud-vision
  opt-in)
- **RETIRED-CANDIDATE**: 1 (`SearchConversationTool` — type + tests
  exist; no production registration)

> The DEAD count clusters around 5 root substrate failures (B-02 history
> threading, B-03 frame-attach delivery, B-04 audio-graph wiring, B-05
> TTS invocation on assistant text, B-07 missing menu item). Every other
> "DEAD" entry is a downstream symptom of one of these roots — the bug
> count of 7 in the handoff doc undercounts the affected *capability*
> surface, which is exactly the substrate failure pattern the API
> redesign is meant to dissolve.
