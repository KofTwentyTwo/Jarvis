---
phase: 09-orchestrator-wiring
plan: 02
subsystem: agent
tags: [agent, orchestrator, vision-dispatch, frame-attach, escalation, bus, blocker-2, int-07-02, int-07-04, d-01, d-02, d-15, d-16]

# Dependency graph
requires:
  - phase: 09-orchestrator-wiring
    provides: AgentOrchestrator instantiation in installAgent + OrchestratorEventBroadcaster fan-out (Plan 09-01)
  - phase: 07-memory-vision
    provides: VisionRouter + FrameAttachController + ContextBuilder + FrameAttachReplaySink + ImageBlock (Plans 07-04, 07-05)
provides:
  - "AgentOrchestrator constructor visionRouter: VisionRouter? = nil parameter (D-01)"
  - "AgentOrchestrator runTurn vision branch + post-response T1→T2 escalation hook (D-02, WARNING-3 LOCKED labeled-loop continue outer)"
  - "AgentOrchestrator.turnHadImage(_:) public accessor (D-16 release subscriber consumer)"
  - "AgentOrchestrator.turnSourceWasVoice(_:) public accessor (BLOCKER-2 — Plan 4 voice subscriber filter)"
  - "ReplayEvent.escalationAttempt(turnId:kind:) case + EscalationKind.t1ToT2 (D-02 marker, distinct from AGENT-09 stream_truncated)"
  - "AppDelegate FrameAttachController instantiation in installVision (D-15, INT-07-04)"
  - "AppDelegate broadcaster .frameAttach release subscriber (D-16)"
  - "AppDelegate Bus inbound handler — frameAttachRequested → requestAttach(reason: .hudButton)"
  - "AppDelegate.tryPhraseAttachIfMatch(_:) helper for Plan 4 chat handlers"
  - "BusInbound.frameAttachRequested case + BUS_PROTOCOL_VERSION 2.2.0 (Swift + TS mirror)"
affects:
  - "Plan 09-03 (presence enrichment): AgentOrchestrator constructor needs presenceSnapshot arg next"
  - "Plan 09-04 (voice/text adapters): chat handlers MUST call tryPhraseAttachIfMatch from BOTH chatSubmit AND chatCancelAndSubmit (WARNING-4); voice subscriber drain MUST gate emitTurnEnded on orchestrator.turnSourceWasVoice(turnId) (BLOCKER-2)"

# Tech tracking
tech-stack:
  added:
    - "VisionRouter integration into AgentOrchestrator.runTurn (image-bearing turn pre-dispatch + post-response escalation)"
    - "Multimodal stream() overload usage on the AgentOrchestrator's currentProvider when input.images is non-empty"
  patterns:
    - "Labeled-loop `continue outer` for D-02 same-turnId T1→T2 escalation (WARNING-3 strategy lock)"
    - "Distinct turnId semantics: D-02 escalation reuses turnId (one user-visible turn); AGENT-09 stream_truncated_retry allocates fresh turnId"
    - "FrameAttach adapter triad: CameraCapture wrapper for FrameAttachController.CaptureSource; ReplayLog wrapper for FrameAttachReplaySink.ReplayLogProtocol; bridging actor for FrameAttachReplaySink → FrameAttachController.ReplaySink"
    - "Broadcaster .frameAttach priority subscriber gates onAssistantTurnComplete on orchestrator.turnHadImage (D-16 lifecycle release)"

key-files:
  created:
    - "App/Vision/AppDelegateFrameAttachAdapters.swift"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVoiceTurnTrackingTests.swift"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/FrameAttachReleaseSubscriberTests.swift"
    - "packages/Replay/Tests/ReplayTests/EscalationAttemptMarkerTests.swift"
    - "packages/Bus/Tests/BusTests/Fixtures/frameAttachRequested.json"
    - "webview/packages/bus/fixtures/frameAttachRequested.json"
  modified:
    - "packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift"
    - "packages/AgentCore/Package.swift (platforms .v13 → .v14; new JarvisVision dep)"
    - "packages/Replay/Sources/Replay/ReplayEvent.swift (.escalationAttempt + EscalationKind)"
    - "packages/Replay/Sources/Replay/Schema.swift (.escalationAttempt = \"escalation_attempt\")"
    - "packages/Replay/Package.swift (platforms .v13 → .v14)"
    - "packages/MCP/Package.swift (platforms .v13 → .v14)"
    - "packages/Memory/Package.swift (platforms .v13 → .v14)"
    - "packages/Bus/Sources/Bus/BusInbound.swift (.frameAttachRequested case + Discriminator + Codable arms)"
    - "packages/Bus/Sources/Bus/Protocol.swift (BUS_PROTOCOL_VERSION 2.1.0 → 2.2.0)"
    - "packages/Bus/Tests/BusTests/CodableRoundTripTests.swift (test_roundTrip_frameAttachRequested)"
    - "App/AppDelegate.swift (frameAttachController + frameAttachReleaseTask properties; installVision FrameAttachController construction; installAgent .frameAttach subscriber + visionRouter pass; agentInstallTask awaits visionInstallTask; tryPhraseAttachIfMatch helper; bridge.onInbound switch with frameAttachRequested arm; cleanup)"
    - "webview/packages/bus/src/protocol.ts (BUS_PROTOCOL_VERSION + frameAttachRequested case + decoder arm)"
    - "webview/packages/bus/tests/round-trip.test.ts (version 2.2.0 + frameAttachRequested round-trip)"
    - "Jarvis.xcodeproj/project.pbxproj (xcodegen regen for new App/Vision source file)"

key-decisions:
  - "WARNING-3 LOCKED: D-02 escalation uses labeled-loop `continue outer` strategy. The streamingPass extraction alternative is rejected because it would require propagating cancellation, retry-budget, and provider-swap state through helper params. The existing `outer:` label on runTurnLoop's while-loop already supports continue-from-switch-arm-inside-for-loop in Swift 6."
  - "D-02 escalation gets ONE shot per turn (escalationConsumed flag). A second low-confidence outcome stays on T1; AGENT-09's stream_truncated_retry is the only retry-with-fresh-turnId path."
  - "ReplayEvent.escalationAttempt is a first-class case (NOT a JSON sidecar payload on userInput). The encoded() switch produces a {turn_id, kind} JSON envelope for forensic readers; ReplayEventKind.escalationAttempt = \"escalation_attempt\" is the SQL kind column value. This keeps the escalation marker visible in `events.kind` queries."
  - "BLOCKER-2 voice-tracking added in Plan 2 (not deferred to Plan 4) because Plan 2 is the earliest wave that already modifies AgentOrchestrator's constructor (visionRouter:) and adds turn-set state (imageBearingTurns). Pruning of voiceOriginatedTurns / imageBearingTurns is deferred — Set growth is monotonic but each entry is a UUID-string TurnID (~16 bytes), so even a long-running app accumulates only kilobytes per session."
  - "FrameAttachController construction uses a 3-layer adapter stack: (1) FrameAttachCaptureSourceAdapter wraps CameraCapture for FrameAttachController.CaptureSource; (2) FrameAttachReplaySinkAdapter wraps Replay.ReplayLog for FrameAttachReplaySink.ReplayLogProtocol; (3) FrameAttachControllerReplaySinkBridge wraps the resulting FrameAttachReplaySink actor (concrete) for FrameAttachController.ReplaySink (protocol). The bridge layer is needed because the Vision package's FrameAttachReplaySink does NOT declare conformance to FrameAttachController.ReplaySink — adding it would either widen the Vision package's public API or require extension-conformance at the App level. The bridge actor is the lighter touch."
  - "FrameAttachReplaySinkAdapter LOGS placeholders (via JarvisLogChannel.replay) rather than persisting to the SQLite events table because recordPlaceholder(_:) does not receive a TurnID at confirm-send time (the orchestrator allocates the turn AFTER the user confirms send), and `events.turn_id` is a non-null FK to `turns(turn_id)`. A synthetic id would fail the FK at flush time. A follow-on plan threads the upcoming TurnID through. The privacy invariant (no raw bytes in the sink) is unaffected — guarded by FrameAttachDiscardSiteGrepTests on the producer side."
  - "BUS_PROTOCOL_VERSION bump 2.1.0 → 2.2.0 chosen MINOR per HUD-05 (additive case; older webviews still decode pre-existing outbound shapes). Strict equality is enforced at handshake — the bump rejects any webview bundle still on 2.1.0 until the TS mirror lands (already shipped in this plan)."
  - "Platform cascade: AgentCore + Replay + MCP + Memory packages all bumped from .v13 to .v14 because AgentOrchestrator now depends on JarvisVision (.v14). Project deployment target was already 14.0; the v13 declarations were stale. No actual API surface impact."

requirements-completed: [VIS-01, VIS-02, VIS-03, VIS-04, VIS-05, VIS-07]

# Metrics
duration: 245min
completed: 2026-05-01
---

# Phase 9 Plan 2: Vision dispatch + frame-attach lifecycle Summary

**AgentOrchestrator now dispatches image-bearing turns through VisionRouter with D-02 silent T1→T2 escalation under same turnId; FrameAttachController instantiated in installVision; HUD camera-icon Bus button + phrase trigger wired; broadcaster's frame-attach subscriber drives onAssistantTurnComplete after image-bearing turns. Closes INT-07-02 + INT-07-04. BLOCKER-2 voice-tracking added pre-emptively to support Plan 4's voice subscriber.**

## Performance

- **Duration:** ~4h elapsed (significant time spent recovering from a worktree-path confusion: my early absolute-path edits were going to the parent repo's `develop` checkout instead of the worktree at `.claude/worktrees/agent-a0ff3bb0afde40c20/`. Cherry-picked Task 1 into the worktree; copied uncommitted Task 2 work into the worktree; reverted parent's working tree. Net coding time ~2h.)
- **Started:** 2026-05-01T20:34:50Z
- **Completed:** 2026-05-02T00:41:45Z
- **Tasks:** 2 (both autonomous; no checkpoints)
- **Files modified:** 23 (7 created + 16 modified)

## Accomplishments

- **D-01 vision dispatch.** AgentOrchestrator constructor now takes optional `visionRouter: VisionRouter?`. When `input.images` is non-empty AND visionRouter is non-nil, runTurn calls `router.route(for:prompt:explicitCloudOptIn:)` BEFORE the streaming loop, swaps the resolved provider for the routed-tier provider, and tracks the turn in `imageBearingTurns`. ContextBuilder.matchesCloudOptIn is the cloud-opt-in signal source. The streaming loop uses the multimodal `LLMProvider.stream(messages:images:...)` overload when image-bearing.
- **D-02 escalation (WARNING-3 LOCKED labeled-loop).** Post-response evaluation runs in the `.endTurn` arm of runTurnLoop. On `.escalateToT2`, the assistant text is discarded from `messages`, the T2 provider is swapped in, the accumulator is reset, and `continue outer` re-enters the streaming pass under the SAME turnId. Records `.escalationAttempt(turnId:kind: .t1ToT2)` to ReplayLog under that turnId. Escalation gets exactly ONE shot per turn (`escalationConsumed` flag); a second low-confidence outcome stays on T1 (the AGENT-09 stream_truncated retry path is the only fresh-turnId retry path).
- **D-15 FrameAttachController instantiation.** AppDelegate.installVision now constructs FrameAttachController with three adapters: FrameAttachCaptureSourceAdapter wrapping CameraCapture, FrameAttachReplaySinkAdapter wrapping Replay.ReplayLog (which logs placeholders via JarvisLogChannel.replay — see Decisions for FK rationale), and FrameAttachControllerReplaySinkBridge wrapping the resulting FrameAttachReplaySink actor for the controller's nested protocol.
- **D-15 HUD button + Bus inbound dispatch.** BusInbound gains `.frameAttachRequested` (additive case + matching Discriminator + Codable arms with no `default` clause). `BUS_PROTOCOL_VERSION` bumped from 2.1.0 → 2.2.0 in both Swift constant and TS mirror; matching fixture added in both `packages/Bus/Tests/BusTests/Fixtures/` and `webview/packages/bus/fixtures/` (byte-identical, no trailing newline per `check-bus-protocol-version.sh`). AppDelegate.installBus now sets `bridge.onInbound`, switching on the inbound case and routing `.frameAttachRequested` into `frameAttachController.requestAttach(reason: .hudButton)`.
- **D-16 release subscriber.** AppDelegate.installAgent step 5d subscribes the broadcaster's `.frameAttach` priority (with `.turnEnd` protected per the broadcaster's protection matrix). On every `.turnEnd`, it asks `agentOrchestrator.turnHadImage(turnId)` and, if true, calls `frameAttachController.onAssistantTurnComplete()` to release the in-memory frame bytes. `agentInstallTask` now awaits `visionInstallTask?.value` before calling `installAgent` so the orchestrator constructor sees the live `visionRouter` AND the broadcaster's frame-attach subscriber sees the live `frameAttachController`.
- **BLOCKER-2 voice-tracking.** AgentOrchestrator gains internal `voiceOriginatedTurns: Set<TurnID>` + `recordVoiceTurn(_:)` populator (called when `input.source == .voice`) + `turnSourceWasVoice(_:) -> Bool` public accessor. Plan 4's voice subscriber drain will call this to filter `.tokenDelta` / `.turnEnd` events that belong to text-originated turns (without this, a text-originated `.turnEnd` would drive `VoiceController` back to `.idle` from `.listening`).
- **D-13 phrase-detection helper.** `tryPhraseAttachIfMatch(_ text: String)` is exposed as a `@MainActor` method on AppDelegate. Plan 4 will call it from BOTH `chatSubmit` AND `chatCancelAndSubmit` per WARNING-4 (without that, barge-in after a phrase-matched submit silently drops the frame).
- **ReplayEvent.escalationAttempt distinct from streamTruncatedRetry.** Plan 1's `streamTruncatedRetry` is a turn-row stop_reason (recorded via ReplayLog.endTurn(_:stopReason: "stream_truncated_retry")); Plan 2's `.escalationAttempt(turnId:kind:)` is a first-class events.kind case. The two retry semantics are visibly distinct in `events.kind` queries: `escalation_attempt` reuses the same turnId; `stream_truncated_retry` allocates a fresh turnId via the `retry_of` column. EscalationAttemptMarkerTests + AgentOrchestratorVisionDispatchTests prove the structural distinction.

## Task Commits

Each task was committed atomically.

1. **Task 1: ReplayEvent.escalationAttempt + AgentOrchestrator visionRouter constructor + runTurn vision branch + post-response escalation + voice-turn tracking (BLOCKER-2)** — `5e50dac` (feat)
2. **Task 2: FrameAttachController instantiation in installVision + Bus frameAttachRequested + broadcaster .frameAttach release subscriber + tryPhraseAttachIfMatch helper** — `87aec28` (feat)

## Files Created / Modified

### Created

- **`App/Vision/AppDelegateFrameAttachAdapters.swift`** — three adapter types (FrameAttachCaptureSourceAdapter, FrameAttachReplaySinkAdapter, FrameAttachControllerReplaySinkBridge) bridging Vision public surface to FrameAttachController's nested protocols.
- **`packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift`** — 6 tests: text-only skips VisionRouter, image-bearing reaches multimodal stream, T1→T2 escalation produces ONE turnEnd under same turnId, ContextBuilder cloud opt-in detected, turnHadImage returns true/false correctly, escalationAttempt distinct from memoryMutation.
- **`packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVoiceTurnTrackingTests.swift`** — 3 BLOCKER-2 tests: voice submission tracked, text submission NOT tracked, unknown turnId NOT tracked.
- **`packages/AgentCore/Tests/AgentOrchestratorTests/FrameAttachReleaseSubscriberTests.swift`** — 2 tests proving the broadcaster→onAssistantTurnComplete glue with a ReleaseCounter actor surrogate (image-bearing turn fires release once; text-only turn never fires release).
- **`packages/Replay/Tests/ReplayTests/EscalationAttemptMarkerTests.swift`** — 3 tests: distinct case from memoryMutation, encodes to "escalation_attempt" kind with JSON envelope round-trip, EscalationKind extensibility check.
- **`packages/Bus/Tests/BusTests/Fixtures/frameAttachRequested.json`** + **`webview/packages/bus/fixtures/frameAttachRequested.json`** — byte-identical fixtures for the parity check.

### Modified

- **`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`** — visionRouter ctor param + stored property; imageBearingTurns + voiceOriginatedTurns sets; turnHadImage + turnSourceWasVoice + recordVoiceTurn methods; runTurn vision branch (route + provider swap + tracking); runTurnLoop signature gains `input: TurnInput, t2AvailableForThisTurn: Bool` and drops standalone `source:` (derived from input.source); multimodal stream overload gating on `!input.images.isEmpty`; assistantTextSoFar accumulator on `.textDelta`; `.endTurn` arm post-response evaluation hook + `continue outer` escalation.
- **`packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift`** — RecordedCall gains `images: [ImageBlock]`; new multimodal `stream(messages:images:...)` overload records image arrays.
- **`packages/AgentCore/Package.swift`** — platforms .v13 → .v14; new JarvisVision dep on AgentOrchestrator target + AgentOrchestratorTests test-target.
- **`packages/Replay/Sources/Replay/ReplayEvent.swift`** — new EscalationKind enum (.t1ToT2); new ReplayEvent case `.escalationAttempt(turnId:kind:)`; encoded() arm produces JSON envelope under ReplayEventKind.escalationAttempt; `import AgentCore` added (TurnID resolution).
- **`packages/Replay/Sources/Replay/Schema.swift`** — ReplayEventKind.escalationAttempt = "escalation_attempt".
- **`packages/Replay/Package.swift`** — platforms .v13 → .v14 (cascade).
- **`packages/MCP/Package.swift`** — platforms .v13 → .v14 (cascade).
- **`packages/Memory/Package.swift`** — platforms .v13 → .v14 (cascade).
- **`packages/Bus/Sources/Bus/BusInbound.swift`** — `.frameAttachRequested` case + matching Discriminator + Codable arms (no default).
- **`packages/Bus/Sources/Bus/Protocol.swift`** — BUS_PROTOCOL_VERSION 2.1.0 → 2.2.0.
- **`packages/Bus/Tests/BusTests/CodableRoundTripTests.swift`** — test_roundTrip_frameAttachRequested.
- **`App/AppDelegate.swift`** — frameAttachController + frameAttachReleaseTask properties; installVision FrameAttachController construction; installAgent passes visionRouter:, awaits visionInstallTask, subscribes .frameAttach broadcaster priority + drains release; bridge.onInbound switch with frameAttachRequested arm; tryPhraseAttachIfMatch helper; cleanup in applicationWillTerminate.
- **`webview/packages/bus/src/protocol.ts`** — BUS_PROTOCOL_VERSION + frameAttachRequested case + decoder arm.
- **`webview/packages/bus/tests/round-trip.test.ts`** — version assertion 2.2.0 + frameAttachRequested fixture round-trip.
- **`Jarvis.xcodeproj/project.pbxproj`** — xcodegen regen.

## Decisions Made

(See frontmatter `key-decisions` for the canonical list. Highlights in prose form below.)

- **D-02 escalation strategy LOCKED to labeled-loop `continue outer`.** The plan's WARNING-3 explicitly rejects the streamingPass-extraction alternative. The existing `outer:` label on runTurnLoop's while-loop is exactly the structure needed; `continue outer` from the switch arm INSIDE the inner `for try await event in stream` is valid Swift 6 (verified empirically by the test suite).

- **Platform cascade.** Adding JarvisVision (.v14) as a dep of AgentOrchestrator forced AgentCore the package to .v14, which in turn forced Replay → MCP → Memory to .v14. Project deployment target is already 14.0; the v13 declarations were stale defaults. No real-world API surface impact.

- **ReplayEvent.escalationAttempt as a first-class case (not JSON sidecar).** The plan's <output> mentioned considering "ReplayEvent enum case vs JSON sidecar". I chose the enum case because (a) the existing `.streamTruncatedRetry` analog is also a stop_reason on the turn row + the events.kind machinery already handles novel cases via Schema's ReplayEventKind enum; (b) a sidecar would invert the "events.kind queries surface all marker types" affordance; (c) the exhaustive-switch surface in the Replay package was small enough to absorb the new case (one switch in `encoded()`, plus the test that asserts mutual exclusivity).

- **FrameAttachReplaySinkAdapter logs rather than persists.** `recordPlaceholder(_:)` does not receive a TurnID at confirm-send time (the orchestrator allocates the turn AFTER the user confirms send), and `events.turn_id` is a non-null FK to `turns(turn_id)`. A synthetic id would fail the FK at flush time (PRAGMA foreign_keys=ON). The placeholder is best-effort observability per OBS-02; logging via JarvisLogChannel.replay is the lower-risk path. A follow-on plan threads the upcoming TurnID through. The privacy invariant — no raw bytes in the sink — is unaffected; FrameAttachDiscardSiteGrepTests guards the producer side.

- **BLOCKER-2 voice-tracking pre-loaded.** Plan 2 is the earliest wave that already modifies AgentOrchestrator's constructor (visionRouter:) and adds turn-set state (imageBearingTurns). Pairing voice-tracking with vision-tracking here avoided splitting orchestrator-constructor churn across two waves. Cost: voiceOriginatedTurns and imageBearingTurns Sets grow monotonically per session; pruning is deferred to Phase 10+.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] FrameAttachController.ReplaySink protocol vs FrameAttachReplaySink concrete actor**
- **Found during:** Task 2 first App build attempt
- **Issue:** Plan said "if `FrameAttachReplaySink` is already concrete and Phase 7-tested, USE IT directly and skip the wrapper struct" — but `FrameAttachReplaySink` does NOT declare conformance to `FrameAttachController.ReplaySink` (the controller's nested protocol). Passing it directly fails type-check.
- **Fix:** Added a tiny bridging actor `FrameAttachControllerReplaySinkBridge` in `App/Vision/AppDelegateFrameAttachAdapters.swift` that wraps `FrameAttachReplaySink` and explicitly conforms to `FrameAttachController.ReplaySink`. Three-method shape: capture adapter, replay adapter, controller-replay bridge.
- **Files modified:** `App/Vision/AppDelegateFrameAttachAdapters.swift`, `App/AppDelegate.swift`
- **Committed in:** `87aec28`

**2. [Rule 3 - Blocking] Platform deployment target cascade (v13 → v14)**
- **Found during:** Task 1 first AgentCore build
- **Issue:** Adding `JarvisVision` (.v14) as a dependency of AgentOrchestrator (target inside the AgentCore package) forced the AgentCore package to v14. The cascade then broke MCP, Replay, and Memory — all of which target .v13 and depend on AgentCore.
- **Fix:** Bumped all four packages (AgentCore, Replay, MCP, Memory) from .v13 to .v14. Project deployment target has always been 14.0 (per `project.yml` MACOSX_DEPLOYMENT_TARGET); the v13 declarations were stale. No actual macOS-13-vs-14 API surface impact.
- **Files modified:** `packages/AgentCore/Package.swift`, `packages/Replay/Package.swift`, `packages/MCP/Package.swift`, `packages/Memory/Package.swift`
- **Committed in:** `5e50dac` (first three) + `87aec28` (Memory)

**3. [Rule 1 - Bug] FrameAttachReleaseSubscriberTests SwiftTaskContinuationMisuse**
- **Found during:** Task 2 first run of new test
- **Issue:** Initial test waited for `.stateChange(.idle)` by iterating `orch.events` directly. But the OrchestratorEventBroadcaster is the SOLE consumer of `orch.events` (D-08 single-consumer invariant), so iterating it from the test code competes with the broadcaster's drain — Swift's continuation-receive abandoned a continuation when the test's for-loop exited.
- **Fix:** Subscribed a SECOND broadcaster channel (`.devOverlay` priority) to wait on `.turnEnd`. The fan-out is synchronous per event, so by the time the wait subscriber sees `.turnEnd`, the frame-attach subscriber has already processed the same event in the previous fan-out iteration. Both tests now pass cleanly.
- **Files modified:** `packages/AgentCore/Tests/AgentOrchestratorTests/FrameAttachReleaseSubscriberTests.swift`
- **Committed in:** `87aec28`

**4. [Rule 1 - Bug] testRunTurnWithImagesCallsVisionRouter recorded 2 calls**
- **Found during:** Task 1 first run of vision dispatch tests
- **Issue:** Test 2 expected exactly one stream call but got two. Cause: T1 returned "a coffee mug" (12 chars), which the VisionEscalationHeuristic flags as low-confidence (config.lowConfidenceMinChars = 24). With `t1Provider == t2Provider == mock`, this triggered an unintended T2 escalation, double-counting the recorded calls.
- **Fix:** Lengthened the T1 response in the test to "This is a white ceramic coffee mug on a wooden desk." (>= 24 chars + free of the low-confidence substring set). The escalation now correctly stays on T1; recordedCalls.count == 1 as expected.
- **Files modified:** `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift`
- **Committed in:** `5e50dac`

**5. [Rule 1 - Bug] webview fixture trailing-newline parity failure**
- **Found during:** Task 2 first App build attempt
- **Issue:** `scripts/check-bus-protocol-version.sh` runs as a preBuildScript and `diff -r`s `packages/Bus/Tests/BusTests/Fixtures/` vs `webview/packages/bus/fixtures/`. My initial `Write` for the TS fixture added a trailing newline; the Swift fixture (and existing fixtures) have none. The build failed at the preBuildScript phase.
- **Fix:** Rewrote the TS fixture with `printf` to omit the trailing newline. Both fixtures now byte-identical; `bus parity OK at v2.2.0`.
- **Files modified:** `webview/packages/bus/fixtures/frameAttachRequested.json`
- **Committed in:** `87aec28`

### Non-Plan Deviations (out of scope of Rules 1–4)

**Worktree-path confusion (process incident, no code impact).** The first ~hour of Task 1 work used absolute paths starting with `/Users/james.maes/Git.Local/Kof22/Jarvis/...` for Read/Write/Edit. Those paths point to the parent repo's `develop` checkout, NOT this worktree at `.claude/worktrees/agent-a0ff3bb0afde40c20/`. Net effect: my Task 1 commit `13c8033` landed on `develop` directly. Recovery: cherry-picked `13c8033` onto the worktree branch as `5e50dac`; copied uncommitted Task 2 work into the worktree; ran `git checkout -- ...` on parent to revert its working tree (NOT `git reset --hard`, which a permission rule blocks). The orchestrator's eventual merge of the worktree branch will see `5e50dac` as already-applied (it has the same content as `13c8033`) and `87aec28` as new. Recorded here for transparency; no other deviation.

---

**Total in-scope deviations:** 5 auto-fixed (3 Rule 1 bugs, 2 Rule 3 blocking).
**Impact on plan:** All five were tactical adaptations against the live codebase. Plan 2's substantive contracts (D-01, D-02, D-15, D-16, BLOCKER-2, INT-07-02 + INT-07-04 closure, WARNING-3 strategy lock) all met. No scope creep. No architectural decisions deferred.

## Issues Encountered

- **Worktree-path confusion** (above) ate ~45min of recovery work but did not affect code correctness.
- **Stuck SwiftPM locks** during repeated `swift test` invocations from the agent's bash runtime: a backgrounded test process held `.build/` lock for 12+ minutes, blocking subsequent runs. Resolved by `lsof +D packages/AgentCore/.build/ | awk '{print $2}'` + `kill -9`.
- **`SWIFT TASK CONTINUATION MISUSE`** on the first run of FrameAttachReleaseSubscriberTests (above). Diagnosed and fixed by routing the wait through a second broadcaster subscription.

## Next Plan Readiness

- **Plan 09-03 (presence enrichment):** AgentOrchestrator constructor still doesn't accept `presenceSnapshot:`; Plan 3 adds it. `installAgent` currently uses a fixed placeholder system prompt; Plan 3 swaps to a per-turn system-prompt builder reading from PresenceSignalBus. The constructor now has 9 args (after Plan 1's 7 + Plan 2's 1 visionRouter), so Plan 3 makes it 10.
- **Plan 09-04 (voice + text adapters):**
  - **WARNING-4:** Plan 4's chat handlers MUST call `await self.tryPhraseAttachIfMatch(text)` from BOTH `chatSubmit` AND `chatCancelAndSubmit` BEFORE submitting the turn. Without that, barge-in after a phrase-matched submit silently drops the frame.
  - **BLOCKER-2:** Plan 4's voice subscriber drain MUST gate `emitTurnEnded` on `await orchestrator.turnSourceWasVoice(turnId)`. The accessor already exists on AgentOrchestrator; `recordVoiceTurn` is populated correctly.
  - **TurnTranscriptStore user-side append:** Plan 1 noted Plan 4 owns the user-side append (BLOCKER-1's full closure depends on it).

## Self-Check: PASSED

**Files exist:**
- FOUND: `App/Vision/AppDelegateFrameAttachAdapters.swift`
- FOUND: `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift`
- FOUND: `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVoiceTurnTrackingTests.swift`
- FOUND: `packages/AgentCore/Tests/AgentOrchestratorTests/FrameAttachReleaseSubscriberTests.swift`
- FOUND: `packages/Replay/Tests/ReplayTests/EscalationAttemptMarkerTests.swift`
- FOUND: `packages/Bus/Tests/BusTests/Fixtures/frameAttachRequested.json`
- FOUND: `webview/packages/bus/fixtures/frameAttachRequested.json`

**Commits exist (on this worktree branch):**
- FOUND: `5e50dac` (Task 1: VisionRouter dispatch + post-response escalation + voice-turn tracking)
- FOUND: `87aec28` (Task 2: FrameAttachController + Bus + broadcaster release subscriber)

**Tests pass:**
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorTests` → 65/65 pass (54 existing + 6 vision dispatch + 3 voice tracking + 2 frame-attach release)
- `swift test --package-path packages/AgentCore --filter FrameAttachReleaseSubscriberTests` → 2/2 pass
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorVisionDispatchTests` → 6/6 pass
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorVoiceTurnTrackingTests` → 3/3 pass
- `swift test --package-path packages/Replay --filter EscalationAttemptMarkerTests` → 3/3 pass
- `swift test --package-path packages/Replay` (full suite) → 30/30 pass
- `swift test --package-path packages/Bus` → 51/51 pass (50 existing + new frameAttachRequested round-trip)
- `swift test --package-path packages/Vision --filter FrameAttachDiscardSiteGrepTests` → 3/3 pass (Phase 7 SOLE-emission-site invariant intact)
- `pnpm -F @jarvis/bus test` → 34/34 pass
- `bash scripts/check-app-builds.sh` → exit 0 (App target compiles cleanly)
- `bash scripts/check-orchestrator-events-single-consumer.sh` → exit 0
- `bash scripts/check-presence-vision-isolation.sh` → exit 0
- `bash scripts/check-bus-protocol-version.sh` → `bus parity OK at v2.2.0`

---
*Phase: 09-orchestrator-wiring, Plan 2*
*Completed: 2026-05-01*
