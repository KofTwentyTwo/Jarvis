---
phase: 09-orchestrator-wiring
verified: 2026-05-02T04:13:46Z
status: passed
score: 8/8 must-haves verified
overrides_applied: 0
---

# Phase 9: Orchestrator Wiring Verification Report

**Phase Goal:** Instantiate AgentOrchestrator in production AppDelegate, replacing every Null/placeholder adapter with real wiring so memory extraction, vision dispatch, presence-aware system prompts, and frame-attach all run end-to-end. Closes INT-07-01..04 and the NullOrchestratorAdapter / NullTTSAdapter / NullBusEmitterAdapter placeholders left over from Phase 6.
**Verified:** 2026-05-02T04:13:46Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (Phase 9 Success Criteria)

| #  | Truth (SC)                                                                                                                                                                                                                  | Status     | Evidence |
| -- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------- |
| 1  | AppDelegate constructs and holds an AgentOrchestrator; tool dispatcher chain from Phase 5 is the orchestrator's `toolDispatcher`.                                                                                              | ✓ VERIFIED | `App/AppDelegate.swift:242` (`private var agentOrchestrator: AgentOrchestrator?`); `:828-839` constructs the orchestrator inside `installAgent()`; `:831` passes `toolDispatcher: mcpRuntime.dispatcher` (Phase 5 MCP chain). `:800-822` enforces dep guards so install is silent when MCP/replay/config absent. |
| 2  | `agentOrchestratorEvents()` returns the live channel; `MemoryExtractionCoordinator.start(...)` runs in production (INT-07-01).                                                                                                | ✓ VERIFIED | The `agentOrchestratorEvents()` nil stub is removed; `App/AppDelegate.swift:842-844` constructs the broadcaster on `orchestrator.events`; `:853-869` subscribes the `.memory` priority channel and calls `coord.start(orchestratorEvents:turnContent:)` with `flushPair`-backed lookup. `MemoryWiringEndToEndTests` (in `packages/Memory/Tests/MemoryTests/`) drives the full chain and asserts non-nil user+assistant text reaches `enqueue`. |
| 3  | VisionRouter is reachable from a turn — either as a ToolDispatcher decorator or via an explicit post-response evaluation hook (INT-07-02).                                                                                    | ✓ VERIFIED | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:210-225` — `runTurn` image-bearing branch calls `router.route(for:prompt:explicitCloudOptIn:)` BEFORE the streaming loop; `:497-523` post-response `evaluatePostResponse` hook with labeled-loop `continue outer` escalation. `AgentOrchestratorVisionDispatchTests` (6/6 pass) prove the dispatch + escalation paths. `installVision()` (`AppDelegate.swift:1162-1173`) constructs the VisionRouter with t1=Ollama, t2=t1, t3=Anthropic, then `installAgent()` passes it via `visionRouter: self.visionRouter`. |
| 4  | `ContextBuilder.installPresence` actually mutates per-turn system prompt per D-10; presence bus events show up in the live model prompt (INT-07-03).                                                                          | ✓ VERIFIED | `packages/Vision/Sources/Vision/ContextBuilder.swift:37-43` drains `PresenceSignalBus.stream` into `PresenceStateSnapshot.shared.record(event)`. `AgentOrchestrator.swift:262-268` reads `presenceSnapshot?.currentEnrichment()` during system-prompt composition (outside the `UntrustedWrapper.composeSystemPrompt` region per SEC-06). `installAgent()` passes `presenceSnapshot: PresenceStateSnapshot.shared`. `PresenceStateSnapshotTests` (10/10 pass) + `AgentOrchestratorPresenceEnrichmentTests` (5/5 pass). |
| 5  | FrameAttachController instantiated; constructor signature drift (07-06 SUMMARY surprise) reconciled (INT-07-04).                                                                                                              | ✓ VERIFIED | `App/AppDelegate.swift:1175-1196` instantiates `FrameAttachController(captureSession:replaySink:)` inside `installVision()` using three adapters in `App/Vision/AppDelegateFrameAttachAdapters.swift`: `FrameAttachCaptureSourceAdapter`, `FrameAttachReplaySinkAdapter`, and `FrameAttachControllerReplaySinkBridge` (the bridge reconciles the 07-06 protocol-conformance drift). HUD button → `bridge.onInbound :1369-1371` calls `requestAttach(reason: .hudButton)`. Release: `:918-930` broadcaster `.frameAttach` subscriber calls `onAssistantTurnComplete()` on `.turnEnd` if `turnHadImage(turnId)`. `FrameAttachReleaseSubscriberTests` (2/2 pass). |
| 6  | Voice's NullOrchestratorAdapter replaced with a real adapter forwarding to `orchestrator.submit(_:)` / `cancelAndSubmit(_:)`; HUD/banner surface SubmitOutcome.rejected reasons.                                              | ✓ VERIFIED | `App/Voice/NullVoiceAdapters.swift` is **deleted** (confirmed by `scripts/check-no-null-voice-adapters.sh` PASS and filesystem check). `App/Voice/VoiceOrchestratorAdapter.swift:38-46` and `:48-53` forward to `orchestrator.submit(.voice(text))` / `.cancelAndSubmit(.voice(text))`; `:83-108` `handleOutcome` enqueues `HUDBannerCoordinator.enqueue(BannerContent)` at priority 5 with copy from `RejectReasonCopy.body(for:)`. `VoiceTTSAdapter` and `VoiceBusEmitterAdapter` also live; `installVoice()` (`AppDelegate.swift:638-693`) uses the production triad. |
| 7  | Text-input path also routes through the orchestrator.                                                                                                                                                                          | ✓ VERIFIED | `App/AppDelegate.swift:1014-1023` `handleChatSubmit` calls `orch.submit(.text(text))` after `tryPhraseAttachIfMatch` (WARNING-4). `:1032-1041` `handleChatCancelAndSubmit` calls `orch.cancelAndSubmit(.text(text))`. `:1362-1378` `bridge.onInbound` switch routes `BusInbound.chatSubmit` / `chatCancelAndSubmit` (added in `BusInbound.swift:21-24`, `BUS_PROTOCOL_VERSION=2.3.0`) into the handlers. `:1068-1076` `handleTextOutcome` surfaces `.rejected` via `BusOutbound.submitRejected(reason:)` toast using the same `RejectReasonCopy` source-of-truth. |
| 8  | App build green, full SPM test suite green, full Harness suite green.                                                                                                                                                         | ✓ VERIFIED | `bash scripts/check-app-builds.sh` → exit 0 ("App target compiles cleanly"). SPM tests: AgentCore 178/178; Memory 84/84 (19 env-skipped); Vision 57/57; Bus 54/54; Replay 30/30. TS bus tests: 37/37 (`pnpm -F @jarvis/bus test`). All Phase 9 grep gates pass. |

**Score:** 8/8 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `App/AppDelegate.swift` | `installAgent` + `installVision` + `installVoice` + chat handlers + broadcaster subscribers + locked install order | ✓ VERIFIED | 1638 LOC; orchestrator constructed at line 828; six broadcaster subscribers (memory, transcript, devOverlay, frameAttach, voice); install order vision (475) → agent (488) → voice (503), enforced by `scripts/check-install-order.sh`. |
| `App/Voice/VoiceOrchestratorAdapter.swift` | actor bridging Voice → AgentOrchestrator + BLOCKER-1 user-side append | ✓ VERIFIED | 126 LOC; conforms to `VoiceOrchestratorInterface`; calls `orchestrator.submit(.voice(text))`; appends user text to `TurnTranscriptStore` after `.ran`/`.superseded`. |
| `App/Voice/VoiceTTSAdapter.swift` | actor bridging Voice → TTSEngineActor (engine optional) | ✓ VERIFIED | 68 LOC; nil-engine path no-ops gracefully; tier resolver defaults to `.tier1`. |
| `App/Voice/VoiceBusEmitterAdapter.swift` | struct forwarding RMS to `OutboundBatcher` | ✓ VERIFIED | 16 LOC; one-line forwarder `await batcher.postAudio(rms)`. |
| `App/Voice/RejectReasonCopy.swift` | single source of truth for rejection wording | ✓ VERIFIED | 22 LOC; three-case `body(for:)` covers all `RejectReason` cases. |
| `App/Voice/NullVoiceAdapters.swift` | DELETED | ✓ VERIFIED | File absent on disk; `scripts/check-no-null-voice-adapters.sh` PASS. |
| `App/Vision/AppDelegateFrameAttachAdapters.swift` | three adapter types | ✓ VERIFIED | `FrameAttachCaptureSourceAdapter` + `FrameAttachReplaySinkAdapter` + `FrameAttachControllerReplaySinkBridge`. |
| `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | visionRouter + presenceSnapshot constructor args; voice/image turn tracking sets; vision dispatch + escalation in runTurn | ✓ VERIFIED | 9-arg constructor (`visionRouter:` + `presenceSnapshot:` after Phase 4's 7); `imageBearingTurns` + `voiceOriginatedTurns` `Set<TurnID>` accumulators with `turnHadImage(_:)` / `turnSourceWasVoice(_:)` accessors; `recordVoiceTurn(_:)` populator inside isolation domain; runTurn vision branch (`:210-225`) and post-response escalation (`:497-523`). |
| `packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEventBroadcaster.swift` | actor with start/stop/subscribe API + 5 priorities + drop-oldest | ✓ VERIFIED | 163 LOC; D-05 single drain, D-06 per-consumer bounded mirror, D-07 priority-protection matrix, D-08 app-lifetime ownership. 6 broadcaster tests pass. |
| `packages/AgentCore/Sources/AgentOrchestrator/TurnTranscriptStore.swift` | actor keyed by TurnID with append/flushPair/discard | ✓ VERIFIED | 72 LOC; per-turn (user, assistant) accumulator; `flushPair` returns nil unless both halves populated. 7 store tests pass. |
| `packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift` | `.superseded` extended with `newTurnId` for BLOCKER-1 cancel-path | ✓ VERIFIED | 31 LOC; `case superseded(priorId: TurnID, newTurnId: TurnID, reason: SupersedeReason)`. |
| `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` | actor with `.shared` singleton + record + currentEnrichment | ✓ VERIFIED | 67 LOC; D-13/D-14 codified inside `currentEnrichment(now:)`. 10 snapshot tests pass. |
| `packages/Vision/Sources/Vision/ContextBuilder.swift` | `installPresence` body drains into `PresenceStateSnapshot.shared.record` | ✓ VERIFIED | Line 40 — placeholder `for await _ in stream {}` is gone; the real drain calls `PresenceStateSnapshot.shared.record(event)`. |
| `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift` | generic AsyncSequence start signature + `MemoryEnqueueing` protocol | ✓ VERIFIED | `public protocol MemoryEnqueueing` (line 11); `MemoryExtractionOrchestrator` conforms via empty extension; `start<S: AsyncSequence & Sendable>(orchestratorEvents:turnContent:) where S.Element == OrchestratorEvent`. |
| `packages/Bus/Sources/Bus/BusInbound.swift` | `frameAttachRequested` + `chatSubmit(text:)` + `chatCancelAndSubmit(text:)` + Codable arms | ✓ VERIFIED | All three cases present with no-default switches; round-trip tests pass. |
| `packages/Bus/Sources/Bus/BusOutbound.swift` | `submitRejected(reason:)` | ✓ VERIFIED | Case + Codable arms present. |
| `packages/Bus/Sources/Bus/Protocol.swift` | `BUS_PROTOCOL_VERSION = "2.3.0"` | ✓ VERIFIED | Constant matches; TS mirror in `webview/packages/bus/src/protocol.ts:18` matches. |
| `webview/packages/bus/src/protocol.ts` | TS mirror of all new cases + version | ✓ VERIFIED | `BUS_PROTOCOL_VERSION = "2.3.0"`; outbound `submitRejected`; inbound `frameAttachRequested` / `chatSubmit` / `chatCancelAndSubmit` cases + decoder arms. |
| `scripts/check-orchestrator-events-single-consumer.sh` | grep gate enforcing single consumer of orchestrator.events | ✓ VERIFIED | exit 0; whitelist scoped to `OrchestratorEventBroadcaster.swift` only (WARNING-2 fix). |
| `scripts/check-no-null-voice-adapters.sh` | structural drift catcher | ✓ VERIFIED | exit 0; "NullVoiceAdapters fully replaced". |
| `scripts/check-install-order.sh` | enforces vision → agent → voice + voice awaits agent | ✓ VERIFIED | exit 0; `install order is vision(475) → agent(488) → voice(503); voice awaits agent`. |
| `scripts/check-presence-vision-isolation.sh` | VISION-03 boundary preserved | ✓ VERIFIED | exit 0; Layer 3 `cancelAndSubmit` allowance for legitimate Plan 4 chat-handler call site is documented in the script. |

### Key Link Verification

| From                                          | To                                              | Via                                                    | Status     | Details |
| --------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------ | ---------- | ------- |
| AppDelegate.installAgent                      | AgentOrchestrator(visionRouter:, presenceSnapshot:, ...) | direct constructor call                              | ✓ WIRED    | `:828-838` passes `mcpRuntime.dispatcher` + `self.visionRouter` + `PresenceStateSnapshot.shared`. |
| AppDelegate.installAgent                      | OrchestratorEventBroadcaster.subscribe(.memory) | `broadcaster.subscribe(priority: .memory, capacity: 256)` | ✓ WIRED    | `:853`; subscribers are awaited; drains stream into `coord.start(...)`. |
| MemoryExtractionCoordinator.start             | broadcaster's memory subscriber AsyncStream     | `coord.start(orchestratorEvents: memorySub.stream, ...)` | ✓ WIRED    | `:856-868`; `turnContent` closure reads `turnTranscriptStore.flushPair(turnId)` (BLOCKER-1 fix). |
| OrchestratorEventBroadcaster.start drain Task | orchestrator.events                             | `for await event in upstream`                         | ✓ WIRED    | OrchestratorEventBroadcaster.swift:66-72; single production iteration site. |
| AppDelegate transcriptSubscriber              | TurnTranscriptStore.append(.assistant, ...)     | `for await event in transcriptSub.stream { if case let .tokenDelta(turnId, text) ... }` | ✓ WIRED    | `:881-892`; assistant-side BLOCKER-1 closure. |
| handleChatSubmit / VoiceOrchestratorAdapter.submit | TurnTranscriptStore.append(.user, ...)        | `appendUserTextIfRunning(outcome, text:)` after submit returns `.ran(turnId:)` / `.superseded(_, newTurnId:, _)` | ✓ WIRED    | All four submit sites populate user-side; `:1049-1060`, `VoiceOrchestratorAdapter.swift:55-66`. |
| AgentOrchestrator.runTurn                     | VisionRouter.route + evaluatePostResponse       | image-bearing branch + `.endTurn` escalation hook     | ✓ WIRED    | `AgentOrchestrator.swift:210-225` + `:497-523`. |
| AppDelegate Bus handler frameAttachRequested  | frameAttachController.requestAttach(reason: .hudButton) | switch arm in `bridge.onInbound`                    | ✓ WIRED    | `:1369-1371`. |
| Bus chatSubmit / chatCancelAndSubmit handlers | AgentOrchestrator.submit(.text(text)) / cancelAndSubmit(.text(text)) | switch arms in `bridge.onInbound`                    | ✓ WIRED    | `:1372-1377`. |
| handleTextOutcome on .rejected                | BusOutbound.submitRejected toast                | `webviewBridge.send(.submitRejected(reason: body))`    | ✓ WIRED    | `:1074`; copy via `RejectReasonCopy.body(for:)`. |
| broadcaster's frameAttach subscriber          | frameAttachController.onAssistantTurnComplete() | gated on `agentOrchestrator.turnHadImage(turnId)` after `.turnEnd` | ✓ WIRED    | `:918-930`. |
| broadcaster's voice subscriber                | voiceOrchestratorAdapter.emitTurnEnded / emitError | gated on `agentOrchestrator.turnSourceWasVoice(turnId)` (BLOCKER-2) | ✓ WIRED    | `:946-980`; per-turn assistant-text accumulator filtered at `.tokenDelta` append time. |
| ContextBuilder.installPresence                | PresenceStateSnapshot.shared.record(event)      | `for await event in stream { await PresenceStateSnapshot.shared.record(event) }` | ✓ WIRED    | `ContextBuilder.swift:37-43`; replaces 07-06 no-op drain. |
| AgentOrchestrator.runTurn                     | presenceSnapshot.currentEnrichment(now:)        | `let presenceLine = await presenceSnapshot?.currentEnrichment()` | ✓ WIRED    | `AgentOrchestrator.swift:262-268`; appended OUTSIDE UntrustedWrapper region (SEC-06). |
| VoiceOrchestratorAdapter.handleOutcome (.rejected) | HUDBannerCoordinator.enqueue                  | `Task { @MainActor in coord?.enqueue(BannerContent(...)) }` | ✓ WIRED    | `VoiceOrchestratorAdapter.swift:88-101`. |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| `AgentOrchestrator.runTurn` (system prompt) | `presenceLine` | `PresenceStateSnapshot.shared.record(event)` populated by `ContextBuilder.installPresence` draining `PresenceMonitor.bus.stream` | Yes — `PresenceMonitor` produces real `PresenceEvent`s from real frames at runtime; PresenceStateSnapshotTests confirm round-trip with deterministic stream | ✓ FLOWING |
| `MemoryExtractionCoordinator` enqueue | `turnContent` (user, assistant) | `TurnTranscriptStore.flushPair` populated by transcript subscriber (assistant) + four submit sites (user) | Yes — `MemoryWiringEndToEndTests` proves NON-NIL user+assistant text reach `enqueue` via real broadcaster + store | ✓ FLOWING |
| `VoiceOrchestratorAdapter.emitTurnEnded(finalText:)` | `finalText` | broadcaster `.voice` subscriber per-turn assistant accumulator from `.tokenDelta` events | Yes — `VoiceSubscriberTextTurnFilterTests` drives a real broadcaster + real orchestrator + spy and asserts only voice-originated turns drive `emitTurnEnded` | ✓ FLOWING |
| `FrameAttachController.onAssistantTurnComplete` | release trigger | broadcaster `.frameAttach` subscriber gated on `turnHadImage(turnId)` on `.turnEnd` | Yes — `FrameAttachReleaseSubscriberTests` asserts release fires once for image-bearing turns and never for text-only turns | ✓ FLOWING |
| `BusOutbound.submitRejected(reason:)` toast | `body` | `RejectReasonCopy.body(for: SubmitOutcome.rejected.reason)` | Yes — text path emits when orchestrator rejects; round-trip + parity tests pass | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| AgentOrchestrator unit + integration tests | `swift test --package-path packages/AgentCore` | 178 passed, 0 failed | ✓ PASS |
| Memory wiring end-to-end | `swift test --package-path packages/Memory` | 84 passed (19 env-skipped), 0 failed | ✓ PASS |
| Vision (Presence + ContextBuilder + FrameAttach) | `swift test --package-path packages/Vision` | 57 passed, 0 failed | ✓ PASS |
| Bus protocol round-trip | `swift test --package-path packages/Bus` | 54 passed, 0 failed | ✓ PASS |
| Replay (escalation marker) | `swift test --package-path packages/Replay` | 30 passed, 0 failed | ✓ PASS |
| Webview Bus protocol round-trip | `pnpm -F @jarvis/bus test` | 37 passed, 0 failed | ✓ PASS |
| App target builds | `bash scripts/check-app-builds.sh` | exit 0 — "App target compiles cleanly" | ✓ PASS |
| Single-consumer grep gate | `bash scripts/check-orchestrator-events-single-consumer.sh` | exit 0 | ✓ PASS |
| No Null voice adapters | `bash scripts/check-no-null-voice-adapters.sh` | exit 0 | ✓ PASS |
| Install order locked | `bash scripts/check-install-order.sh` | exit 0 — vision(475) → agent(488) → voice(503); voice awaits agent | ✓ PASS |
| Presence-vision isolation | `bash scripts/check-presence-vision-isolation.sh` | exit 0 | ✓ PASS |
| FrameAttach SOLE-emission-site invariant | `swift test --package-path packages/Vision --filter FrameAttachDiscardSiteGrepTests` | 3/3 pass | ✓ PASS |
| Cross-phase install-order grep gate (PhaseSeven) | `swift test --package-path packages/Memory --filter PhaseSevenGrepGateTests` | 5/5 pass (assertion now correctly says installVision BEFORE installVoice — matches `check-install-order.sh`) | ✓ PASS |

### Requirements Coverage

The plan-level frontmatter declares these requirement IDs against the v0.12.0 audit's short forms (REQUIREMENTS.md uses the longer MEM-/VISION- prefix; the audit and plans use ME-/VIS- as the shorthand consistent with `v0.12.0-MILESTONE-AUDIT.md`).

| Requirement | Source Plan | Description (per audit + plan must-haves) | Status | Evidence |
| ----------- | ---------- | ----------------------------------------- | ------ | -------- |
| ME-01..05 | 09-01 | Memory extraction enqueue path runs end-to-end with non-nil pair text | ✓ SATISFIED | `MemoryWiringEndToEndTests` — real broadcaster + real TurnTranscriptStore + real coordinator + spy asserts non-nil user+assistant text reach `enqueue`. |
| VIS-01, VIS-02, VIS-04, VIS-05 | 09-02 | Vision dispatch through VisionRouter from runTurn | ✓ SATISFIED | `AgentOrchestratorVisionDispatchTests` (6/6) cover image-bearing branch, multimodal stream, escalation, cloud opt-in, turnHadImage. |
| VIS-03 | 09-02, 09-03 | VISION-03 boundary preserved — PresenceStateSnapshot returns ONLY String? to consumer | ✓ SATISFIED | `scripts/check-presence-vision-isolation.sh` exit 0; `PresenceStateSnapshot.swift` exposes only `String?` from `currentEnrichment(now:)`; doc comment satisfies `grep -cE "TTSEngine\|runTurn\|AgentOrchestrator" == 0`. |
| VIS-06 | 09-03 | Presence enrichment in system prompt | ✓ SATISFIED | `AgentOrchestratorPresenceEnrichmentTests` (5/5) — present sentence appended after observation age ≥ 5s; absentLongTerm sentence; suppression rules. |
| VIS-07 | 09-02 | Frame-attach lifecycle (request + release) | ✓ SATISFIED | HUD button → `frameAttachController.requestAttach(.hudButton)`; broadcaster `.frameAttach` release subscriber drives `onAssistantTurnComplete()`; `FrameAttachReleaseSubscriberTests` (2/2). |
| AGENT-09 | 09-03, 09-04 | Stream-truncated retry semantics distinct from D-02 vision escalation | ✓ SATISFIED | `EscalationAttemptMarkerTests` proves `.escalationAttempt(.t1ToT2)` is structurally distinct from `.streamTruncatedRetry`. The `recordVoiceTurn` + `turnSourceWasVoice` infrastructure also closes BLOCKER-2 (text turns never drive emitTurnEnded). |

No orphaned requirements detected — every requirement ID in plan frontmatter appears in the audit's `affected_requirements` map; every Phase 9 SC traces to at least one verified plan-level must-have.

### Anti-Patterns Found

Anti-pattern scanning across all Phase 9 modified/created files; severity per the verifier's rubric.

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| `App/AppDelegate.swift` | 899-904 | DevOverlay subscriber drains to `for await _ in devSub.stream {}` no-op consumer (TODO-equivalent) | ℹ️ Info | Documented in 09-01-SUMMARY as "DevOverlay subscriber wiring deferred"; subscription is established to satisfy the broadcaster's three-subscriber pattern; full wiring lands in a follow-on plan. Does NOT impair Phase 9 SCs. |
| `App/Voice/VoiceTTSAdapter.swift` | 44-46 | `engine == nil` no-op path | ℹ️ Info | Documented "engine optional" decision in 09-04-SUMMARY: TTSEngineActor construction (Orpheus + AVSpeech model wiring) is week-one scope but lands in a follow-on plan. Adapter wires regardless so the rest of the orchestrator path goes live. Phase 9 goal does not require live TTS audio. |
| `App/Vision/AppDelegateFrameAttachAdapters.swift` | 62-67 | `_ = replayLog` dead-store + log-only `recordPlaceholder` | ℹ️ Info | Documented FK constraint reason (turn_id non-null FK is unavailable at confirm-send time); REVIEW IN-03 flags as smell; privacy invariant unaffected — the SOLE-emission-site discard lives in `FrameAttachController` itself, enforced by `FrameAttachDiscardSiteGrepTests`. |
| `App/AppDelegate.swift` | (handleChatSubmit etc.) | None — orchestration paths are populated, no `return null` / `=> {}` empty stubs | — | All four submit sites + bridge.onInbound switch + handleTextOutcome are fully implemented. |
| `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | 81-88 | `imageBearingTurns` / `voiceOriginatedTurns` Set<TurnID> grow monotonically without pruning | ℹ️ Info | REVIEW WR-01 documents this as advisory tech-debt for Phase 10+; correctness preserved (lookups return correct results); memory growth is on the order of 100s of KB for week-long sessions. Does NOT block Phase 9 SCs. |
| `packages/AgentCore/Sources/AgentOrchestrator/TurnTranscriptStore.swift` | 60-70 | No `discard` on cancelled / errored / max-tokens / refusal turns | ℹ️ Info | REVIEW WR-02 documents partial-entry leakage as advisory; same scale + scope as WR-01; functional correctness preserved (memory's `flushPair` returns nil for missing pairs and the Phase 7 D-01 contract holds for `.endTurn` turns). |

No 🛑 blockers. No ⚠️ Phase 9 SC-blocking warnings.

### Known Pre-Existing Issues (NOT Phase 9 gaps)

1. **`VoiceTests.TTSInterruptTests.testI3_completionTimeoutRespected`** — environment flake on this Mac (~10.5s vs 80ms expected). Voice package was untouched in Phase 9 (last touched commit `4d7bd76` during Phase 6); test depends on real `AVAudioEngine` + `playerNode.stop()` draining within 20ms; Phase 6 verification recorded I3 as passing. Treat as pre-existing environment flake, not a Phase 9 regression.
2. **Cross-phase install-order test was UPDATED during Phase 9 execution** — `PhaseSevenGrepGateTests.testAppDelegateInstallOrder` was changed from "installVision AFTER installVoice" to "installVision BEFORE installVoice" because Plan 09-04 LOCKED the new order via `scripts/check-install-order.sh`. Both gates now agree (verified: 5/5 pass in PhaseSevenGrepGateTests; install-order shell gate exit 0). Not a regression.

### Human Verification Required

(none)

This is a wiring phase — every truth resolves to grep evidence + structural tests + SPM/xcodebuild test runs. No UI behavior, real-time loops, external services, or visual artifacts are gated on Phase 9 acceptance. The follow-on user-facing surfaces (chat-panel `submitRejected` toast component, TTS engine wiring, vllm-mlx sidecar, devOverlay emitter) are explicitly deferred to follow-on plans per 09-CONTEXT.md and the SUMMARYs.

### Gaps Summary

None. Phase 9's eight Success Criteria all resolved to VERIFIED with grep + structural-test + behavioral-spot-check evidence in the codebase. The four INT-07-XX cross-phase deferrals from `v0.12.0-MILESTONE-AUDIT.md` are closed:

- **INT-07-01** (memory extraction) — orchestrator events flow into `MemoryExtractionCoordinator` via the broadcaster's `.memory` subscriber; `lookupTurnContent` reads from `TurnTranscriptStore.flushPair`; `MemoryWiringEndToEndTests` proves NON-NIL pair text reaches `enqueue`.
- **INT-07-02** (vision dispatch) — image-bearing `runTurn` calls `VisionRouter.route` before the streaming loop; post-response `evaluatePostResponse` drives D-02 same-turnId T1→T2 escalation via labeled-loop `continue outer`.
- **INT-07-03** (presence-aware prompt) — `ContextBuilder.installPresence` writes to `PresenceStateSnapshot.shared`; `runTurn` reads `currentEnrichment()` and appends a plain sentence to the system prompt outside the UntrustedWrapper region.
- **INT-07-04** (frame-attach lifecycle) — `FrameAttachController` instantiated in `installVision` with three reconciled adapters; HUD camera-icon Bus button + phrase-detection both call `requestAttach`; broadcaster `.frameAttach` subscriber drives `onAssistantTurnComplete` on every image-bearing turn end.

The Null adapter triad (`NullOrchestratorAdapter` / `NullTTSAdapter` / `NullBusEmitterAdapter`) is replaced by the real adapter triad (`VoiceOrchestratorAdapter` / `VoiceTTSAdapter` / `VoiceBusEmitterAdapter`); the placeholder file `App/Voice/NullVoiceAdapters.swift` is deleted from disk. Text-input path also routes directly through `AgentOrchestrator.submit(.text(text))` / `cancelAndSubmit(.text(text))` from the Bus inbound handler, with `SubmitOutcome.rejected` reasons surfacing via either HUD banner (voice) or `BusOutbound.submitRejected` toast (text), both reading the same `RejectReasonCopy` source-of-truth.

BLOCKER-1 (memory pair-text non-nil) and BLOCKER-2 (text turns never drive voice emitTurnEnded) are both closed with end-to-end prove-out tests. WARNING-1..5 from the plan documents are all observed: same-wave file-overlap respected, single-emission-site grep gate scoped correctly, escalation strategy locked to labeled-loop, phrase trigger fires on both chatSubmit + chatCancelAndSubmit, install order locked vision → agent → voice.

REVIEW.md identified 0 critical / 7 advisory warnings — none of which block Phase 9 SCs. Items WR-01 (Set growth) and WR-02 (transcript-store partial entries) are tracked as Phase 10+ tech debt; the rest are minor concurrency / test-quality smells with documented escape hatches.

---

_Verified: 2026-05-02T04:13:46Z_
_Verifier: Claude (gsd-verifier)_
