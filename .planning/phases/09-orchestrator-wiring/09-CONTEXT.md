# Phase 9: Orchestrator Wiring - Context

**Gathered:** 2026-05-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 9 instantiates `AgentOrchestrator` in production `AppDelegate` and replaces every Null/placeholder adapter with real wiring so the four cross-phase dispatches identified in `v0.12.0-MILESTONE-AUDIT.md` (INT-07-01..04) actually run end-to-end:

1. **INT-07-01 — Memory extraction:** `agentOrchestratorEvents()` returns the live channel; `MemoryExtractionCoordinator.start(...)` runs in production.
2. **INT-07-02 — Vision dispatch:** A turn carrying `TurnInput.images != nil` reaches `VisionRouter` from inside `runTurn`.
3. **INT-07-03 — Presence-aware prompt:** `PresenceEvent` flow actually mutates per-turn system prompt per Phase 7 D-10.
4. **INT-07-04 — Frame-attach lifecycle:** `FrameAttachController` is instantiated; HUD camera-icon Bus message routes into `requestAttach(reason: .hudButton)`; `onAssistantTurnComplete()` fires after every image-bearing turn.

Plus the symmetric Phase 6 dead-end:

5. **NullVoiceAdapters replacement:** `NullOrchestratorAdapter` / `NullTTSAdapter` / `NullBusEmitterAdapter` (in `App/Voice/NullVoiceAdapters.swift`) become real adapters forwarding to `AgentOrchestrator.submit(_:)` / `cancelAndSubmit(_:)` / `TTSEngineActor` / Bus.
6. **Text-input symmetric path:** Chat-panel text submissions reach `AgentOrchestrator.submit(.text(...))` so the chat panel is no longer a dead-end.
7. **`SubmitOutcome.rejected` user surface:** Voice + text rejections (`.turnInFlight`, `.providerUnavailable`, `.configError`) reach the user via HUD banner + Bus toast.

**No new capabilities.** Every type is already implemented and unit-tested in Phases 4–7. Phase 9 is dispatch glue — closing four documented "live behaviour the code claims to implement but doesn't actually run" gaps. The vllm-mlx sidecar (Phase 7 Claude's-discretion item) and the Phase 8 operator-action items remain out of scope.

</domain>

<decisions>
## Implementation Decisions

### Area 1 — VisionRouter dispatch shape

- **D-01:** **Pre-turn branch in `runTurn`.** When `TurnInput.images.isEmpty == false`, `AgentOrchestrator.runTurn` calls `VisionRouter.route(for:prompt:explicitCloudOptIn:)` BEFORE the existing `providerFactory(perTurn.resolvedProvider)` line, swaps the resolved provider for the routed-tier provider, and runs the standard streaming loop on it. T2 is reached only via the post-response escalation hook, never via `route(...)`. AgentOrchestrator gains an optional `visionRouter: VisionRouter?` constructor dep.
- **D-02:** **Internal retry, same `turnId`** for silent T1 → T2 escalation. After `LLMEvent.messageStop` flushes the T1 response, `runTurn` calls `VisionRouter.evaluatePostResponse(...)` and — on `.escalateToT2` — discards the T1 response from model-facing history, swaps to `t2Provider`, re-streams, and emits a single `.turnEnd` with the T2 result. ReplayLog records both attempts under the same `turnId` with an `escalation_attempt` marker. User sees one in-progress turn and one final answer (no flicker, no second turn row).
- **D-03:** **Image-bearing detection lives in `runTurn`**, gated by `TurnInput.images.isEmpty == false`. ~15 LOC + a `visionRouter: VisionRouter?` optional dep on the orchestrator constructor. Keeps the dispatch policy in one place. No `VisionTurnAdapter` / no LLMProvider-conformance refactor for `VisionRouter`.
- **D-04:** **Ship as-is: `t2Provider == t1Provider`** in `installVision()`. The T2 silent-equals-T1 wiring is exercised end-to-end in production; the no-op escalation runs the dispatch path without the vllm-mlx sidecar landing first. Tech-debt note in 09 SUMMARY pointing forward to a vllm-mlx sidecar plan. `evaluatePostResponse(...)` already correctly stays-on-T1 when `t2Available == false`, so the same dispatch code paths cover both wiring states.

### Area 2 — Orchestrator events fan-out

- **D-05:** **AppDelegate-owned broadcaster shim.** New `OrchestratorEventBroadcaster` actor (~50 LOC) owns the single `for await event in orchestrator.events` and re-emits to N child `AsyncStream<OrchestratorEvent>`s — one per consumer (memory, devoverlay, frame-attach release subscriber). AgentOrchestrator's `nonisolated let events: BoundedAsyncChannel<OrchestratorEvent>` (capacity 256, suspend) stays unchanged; the multi-consumer concern is localized to the wiring layer.
- **D-06:** **Per-consumer bounded queue, drop-oldest** as the broadcaster's drop policy. Each child stream has its own bounded buffer (default 256). When a consumer's buffer is full, the broadcaster drops the oldest event for THAT consumer only. Isolates a stuck consumer from blocking everyone else; mirrors the `TokenDeltaDropOldestChannel` pattern from Phase 4's Replay package.
- **D-07:** **Priority filter on the memory subscriber:** `.turnEnd`, `.toolCallStart`, `.toolCallEnd` are NEVER dropped on the memory subscriber regardless of buffer state. Only `.tokenDelta` and `.thinkingDelta` are eligible for drop-oldest. Guarantees Phase 7 D-01's "every turn pair is enqueued for extraction" invariant against the drop-oldest policy from D-06.
- **D-08:** **Broadcaster lives for app lifetime, owned by `AppDelegate`.** Created in `installAgent()` (the new install function added by Phase 9), held strongly. Consumers come and go; broadcaster's drain `Task` ends only on app termination. Matches how `voiceController`, `memoryExtractionOrchestrator`, and other long-lived AppDelegate-held subsystems behave today.

### Area 3 — Null adapter replacement + text-input path

- **D-09:** **New adapters live in `App/Voice/`**, replacing `NullVoiceAdapters.swift`. Three production files: `VoiceOrchestratorAdapter.swift`, `VoiceTTSAdapter.swift`, `VoiceBusEmitterAdapter.swift`. Each imports `AgentOrchestrator` + `Voice` + `Bus` (or the relevant subset) and bridges the protocol into the production type. Mirrors the `AppDelegateBannerAdapter` / `AppDelegateContextBuilderAdapter` pattern. No SPM-graph changes — keeps the adapters in the App target where dep cycles already resolve.
- **D-10:** **HUD banner + Bus toast** for `.rejected(reason:)` surfacing. Voice path: the new `VoiceOrchestratorAdapter` enqueues a banner via `HUDBannerCoordinator` ("Already thinking — wait or say cancel" / "Provider unavailable" / "Config error"). Text path: AppDelegate's Bus inbound handler emits a `submitRejected{reason}` event the chat panel renders as a transient toast. Two surfaces because voice and text have different attention models. Cardinal: never silently drop a user's submission.
- **D-11:** **`String → TurnInput` conversion lives inside `VoiceOrchestratorAdapter`.** Adapter implementation: `func submit(text: String) async { let outcome = await orchestrator.submit(.voice(text)); handleOutcome(outcome) }`. Symmetric: `func cancelAndSubmit(text: String) async { ... .cancelAndSubmit(.voice(text)) ... }`. Voice's `VoiceOrchestratorInterface` protocol stays text-only; the adapter encapsulates the lift into orchestrator vocabulary. Same shape applies to the text-path (which calls `.text(...)` instead of `.voice(...)`).
- **D-12:** **Text-input path is direct in the Bus handler, no controller.** AppDelegate's Bus inbound handler for `chatSubmit` / `chatCancelAndSubmit` calls `orchestrator.submit(.text(message))` / `cancelAndSubmit(.text(message))` directly, then handles the `SubmitOutcome` (banner / toast / log). No `TextController` layer; text input has no state machine to manage. Adds ~10 LOC to the Bus handler. Symmetric with how Phase 5's MCP runtime handles `confirmation.response` Bus messages.

### Area 4 — Presence enrichment + Frame-attach lifecycle

- **D-13:** **`PresenceStateSnapshot` actor, read at `runTurn`.** New `PresenceStateSnapshot` actor stores `(latestEvent: PresenceEvent, observedAt: Date)`. `ContextBuilder.installPresence` becomes a real implementation that writes to the snapshot on each event (replacing the no-op drain). `AgentOrchestrator.runTurn` calls `await presenceSnapshot?.currentEnrichment()` while building the system prompt and appends the result. Read-only from the orchestrator's perspective; honors VISION-03 (orch never references `PresenceSignalBus` directly — only the snapshot's text output). `ContextBuilder` stays a `Sendable` struct per 07-05's locked surface.
- **D-14:** **Plain sentence appended to system prompt.** Inject literal text — e.g., `"User is at the desk."` (when `present` and last-seen ≤ 5 minutes) or `"User has been away from the desk for 7 minutes."` (when `absent` ≥ 5 minutes per Phase 7 D-11's secondary threshold). Suppress entirely when state is `present` AND last-seen < 5 seconds (avoid noise on every turn). No structured XML/JSON tags. Models handle this format natively; small token cost; consistent with how Anthropic's documented system-prompt examples handle ambient context.
- **D-15:** **`FrameAttachController` instantiated in `installVision()`** right after `VisionRouter`. `CaptureSource` adapter wraps `CameraCapture`; `ReplaySink` adapter wraps `ReplayLog` (or the existing `FrameAttachReplaySink` from `packages/Vision`). AppDelegate's Bus inbound handler for `frameAttachRequested` calls `frameAttachController.requestAttach(reason: .hudButton)`. Phrase-detection path: `ContextBuilder.matchesFrameAttachPhrase(text)` runs at submit-time inside the same handler / adapter that submits the turn; on match, calls `requestAttach(reason: .phraseDetected(in: text))` BEFORE submitting the turn so the captured `ImageBlock` can be attached to `TurnInput.images` after the user confirms. Reconciles the 07-06 SUMMARY constructor-signature drift by aligning to the current public init.
- **D-16:** **`FrameAttachReleaseSubscriber` on the broadcaster** for `onAssistantTurnComplete()`. The broadcaster (D-05) gets a third subscriber that watches for `OrchestratorEvent.turnEnd`. When `turnEnd` arrives AND the turn had an image attached (tracked via a turn-id-keyed lookup populated when the orchestrator started the turn), the subscriber calls `frameAttachController.onAssistantTurnComplete()`. Decouples the controller from `runTurn` internals; uses the same observer pattern as memory and dev overlay. Honors D-15 "discard immediately after response."

### Claude's Discretion

- **Snapshot sentence wording for D-14** — exact phrasing and the absent/present/duration threshold tuning. Planner picks.
- **`OrchestratorEventBroadcaster` internal data structures** — actor vs `AsyncChannel` vs hand-rolled. Planner picks (subject to D-05/06/07/08 invariants).
- **Per-consumer buffer size** for D-06 (default 256 each, but DevOverlay may want smaller, memory may want larger). Planner tunes.
- **`SubmitRejectionBanner` / `chat.submitRejected` Bus message schema** — payload field names, presentation timing. Planner picks.
- **Vision-escalation `escalation_attempt` marker shape** in ReplayLog (D-02) — column or JSON sidecar. Planner picks.
- **`FrameAttachController` adapters** for `CaptureSource` + `ReplaySink` — protocol-conforming wrappers around `CameraCapture` and `ReplayLog`. Planner names them.
- **Whether `installAgent()` is a new install function or folded into existing `installMCP()` / `installVoice()`** — Phase 9 introduces the orchestrator instantiation, so it likely deserves its own install function in AppDelegate (mirrors `installMemory()` / `installVision()`); planner confirms.
- **Test surface for the broadcaster** — likely a new `OrchestratorEventBroadcasterTests` target proving fan-out + drop-oldest + priority-filter behaviour.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 9 audit anchors
- `.planning/v0.12.0-MILESTONE-AUDIT.md` — INT-07-01..04 evidence + affected REQ-IDs (ME-01..05, VIS-01..07, AGENT-09); the audit's `gaps.integration` block enumerates each deferral with file:line site evidence. **The driving document for Phase 9.**
- `.planning/ROADMAP.md` §Phase 9 — goal statement + 8 success criteria.
- `.planning/STATE.md` §"Phase 6 → Phase 8 Deferred Items" — operator-action context that Phase 9 explicitly does NOT inherit (those remain Phase 8 tech debt).

### Phase 7 carry-forward (read for D-locked invariants)
- `.planning/phases/07-memory-vision/07-CONTEXT.md` — D-01 (auto-extract every turn pair), D-10 (presence affects context-prompt + HUD ring; HUD side already wired), D-13/D-14/D-15 (frame-attach SOLE-emission-site invariant via `discardFrame()`), D-16/D-17/D-18 (vision T1→T2 silent escalation; T3 only on explicit user opt-in).
- `.planning/phases/07-memory-vision/07-VERIFICATION.md` — `deferred` block listing the four cross-phase wiring debts being closed here.
- `.planning/phases/07-memory-vision/07-06-SUMMARY.md` — "Deferred Wiring" + "Surprises Encountered" (the FrameAttachController constructor-signature drift mentioned in D-15).

### Project-level
- `CLAUDE.md` — Settled architecture, AGENT-06 invariants, observability-from-day-one, "no silent failures" principle (D-10 surface decisions).
- `.planning/REQUIREMENTS.md` — affected REQ-IDs: ME-01..05, VIS-01..07, AGENT-09 (each at the dispatch-glue layer; the type-level implementations are already verified).
- `.planning/PROJECT.md` — core value, evolution rules, "incremental delivery; no large-batch code drops" (Phase 9 fits in 3–4 small plans).
- `.planning/research/RESEARCH-DELTAS.md` — D7 (Orpheus mlx-audio-swift in-process — sets precedent for VllmMlxProvider when sidecar lands later).

### Cross-phase dependency surfaces (the actual code Phase 9 wires)
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` — `submit` / `cancelAndSubmit` / `runTurn`; the events channel at line 51; constructor signature where `visionRouter: VisionRouter?` gets added (D-01).
- `packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift` — `.ran` / `.superseded` / `.rejected(reason:)` enum + the three `RejectReason` cases (D-10 surfaces all three).
- `packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift` — the events the broadcaster fans out; SEC-06 invariant (turnNonce never appears).
- `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift` — `.text(...)` / `.voice(...)` factories + the `images: [ImageBlock]` field (D-03 detection).
- `packages/Vision/Sources/Vision/VisionRouter.swift` — `route(for:prompt:explicitCloudOptIn:)` + `evaluatePostResponse(_:config:t2Available:)` + `providerForTier(_:)` (D-01, D-02, D-04).
- `packages/Vision/Sources/Vision/ContextBuilder.swift` — `installPresence` becomes a real implementation in D-13; `matchesFrameAttachPhrase` + `matchesCloudOptIn` (D-15 phrase trigger).
- `packages/Vision/Sources/Vision/FrameAttachController.swift` — `requestAttach` / `confirmSend` / `cancel` / `onAssistantTurnComplete` / `discardFrame` (D-15, D-16); SOLE-emission-site grep gate via `FrameAttachDiscardSiteGrepTests`.
- `packages/Vision/Sources/Vision/PresenceSignalBus.swift` + `PresenceMonitor.swift` — bus is constructed exactly once by `PresenceMonitor`; D-13 reads from `bus.stream` only.
- `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift` — `start(orchestratorEvents:turnContent:)` becomes reachable; the `agentOrchestratorEvents()` placeholder in `AppDelegate.swift:641` returns the broadcaster's memory subscriber (D-05/07).
- `App/AppDelegate.swift` — installVision (line 667) gets `FrameAttachController` instantiation (D-15); installMemory (line 539) gets the live events stream from the broadcaster; new `installAgent()` (Claude's discretion) constructs the orchestrator + broadcaster.
- `App/Voice/NullVoiceAdapters.swift` — entire file replaced by D-09's three production adapters.
- `App/MCP/AppDelegateContextBuilderAdapter.swift` — pattern for the new adapter files.
- `App/MCP/MCPRuntimeWiring.swift` — the `ToolDispatcher` chain that becomes `AgentOrchestrator.toolDispatcher` (Phase 9 SC#1).
- `packages/Voice/Sources/Voice/VoiceController.swift` + `VoiceOrchestratorInterface` / `VoiceTTSInterface` / `VoiceBusEmitterInterface` — adapter target protocols.
- `App/HUD/HudStateCoordinator.swift` — three-subscriber pattern; D-13's `attachPresence` is already wired; D-10's banner enqueue is the new surface.
- `App/HUD/HUDBannerCoordinator.swift` — banner enqueue surface for D-10 voice-rejection banner.

### External documentation
- [Anthropic Messages API — system prompts](https://docs.anthropic.com/en/api/messages) — D-14 plain-sentence injection format precedent.
- [`AsyncStream` (Swift Concurrency)](https://developer.apple.com/documentation/swift/asyncstream) — broadcaster's per-consumer child-stream type (D-05).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`AppDelegateBannerAdapter` + `AppDelegateContextBuilderAdapter`** (App/MCP/) — naming + dependency-injection pattern for the three new voice adapters in D-09.
- **`HUDBannerCoordinator.enqueue(...)`** (Phase 1, reused in Phase 6 AEC + Phase 7 Camera) — banner surface for D-10 voice-rejection banners.
- **`TokenDeltaDropOldestChannel`** (packages/Replay, Phase 4) — drop-oldest pattern that informs D-06's broadcaster drop policy.
- **`MCPRuntimeWiring.toolDispatcher`** (App/MCP/) — `ToolDispatcher` chain that becomes the orchestrator's `toolDispatcher` constructor argument (Phase 9 SC#1).
- **`MemoryExtractionCoordinator.start(orchestratorEvents:turnContent:)`** (packages/Memory) — already takes the exact channel type the broadcaster's memory subscriber emits; no signature changes required on consumer side.
- **`DevSnapshotEmitter.subscribe(to:)`** (packages/AgentCore) — already takes `BoundedAsyncChannel<OrchestratorEvent>`; broadcaster can hand it a child stream wrapped in the same type or expose an `AsyncStream` consumer signature (planner picks).
- **`FrameAttachReplaySink`** (packages/Vision) — likely the `ReplaySink` adapter for D-15 (or planner writes a thin AppDelegate-side wrapper).
- **`CameraCapture.frameStream(forPresence:)` and similar capture entry points** (packages/Vision) — `CaptureSource` adapter source for D-15.
- **`AppDelegate.installVoice() / installMemory() / installVision()` six-step bootstrap pattern** — template for the new `installAgent()` function (Claude's discretion).

### Established Patterns
- **Single-emission-site invariants enforced by grep gates** (Phase 6 `\.ttsStopped` count == 1; Phase 7 `FrameAttachDiscardSiteGrepTests`; Phase 7 `scripts/check-presence-vision-isolation.sh`) — Phase 9 may need a similar grep gate ensuring `agentOrchestratorEvents()` only has one production caller (memory) and that no production code reads `orchestrator.events` directly except the broadcaster.
- **Compile-time package boundary as architectural guard** (Phase 6/7 VISION-03 boundary scripts) — D-13's PresenceStateSnapshot must NOT be importable from packages/Voice or packages/AgentCore in a way that creates a presence→orch direct dep; planner verifies by reading the SPM graph before placing the actor's home package.
- **Dormant continuations for HUD state intent streams** (Phase 1+3 — three streams for agent/voice/confirmation; Phase 3 SUMMARY notes them as "dormant producers wired in subsequent phases"). Phase 9 wakes the agent stream by emitting from the orchestrator-derived broadcaster.
- **`@MainActor` adapters bridging actor-protected types into AppDelegate** (Phase 6/7 banner + presence adapters) — D-09's voice adapters follow the same convention.
- **Worktree mode with executor-per-plan + orchestrator post-wave validation** (Phase 6/7) — Phase 9 should expect the same flow; orchestrator re-runs `swift test` + `bash scripts/check-app-builds.sh` against the merged develop tree before marking each plan done.

### Integration Points
- **Phase 4 AgentOrchestrator** — gains optional `visionRouter: VisionRouter?` constructor dep (D-01) and an `images`-aware branch in `runTurn` (D-03). Public `submit`/`cancelAndSubmit`/`SubmitOutcome` surface unchanged.
- **Phase 5 MCP Runtime** — its `ToolDispatcher` chain is passed as `AgentOrchestrator(toolDispatcher: ...)` at construction time. No internal changes.
- **Phase 6 Voice** — `NullVoiceAdapters.swift` is deleted. `VoiceController` constructor is unchanged; only the concrete adapter types it receives change.
- **Phase 7 Memory + Vision** — `agentOrchestratorEvents()` placeholder is replaced by a real implementation that returns the broadcaster's memory subscriber (D-05/07). `ContextBuilder.installPresence` body changes from no-op drain to PresenceStateSnapshot writer (D-13). `FrameAttachController` is constructed in `installVision()` (D-15).
- **Phase 8 Hardening** — Phase 9 does NOT inherit Phase 8's operator-action items (Orpheus TTFA, AVAudioEngine device-change injection, wake-hysteresis corpus). Phase 9 closes the `live functionality the code claims to implement but doesn't actually run` category from the audit; Phase 8's deferrals stay where they are.
- **Bus** — gains `chatSubmit` / `chatCancelAndSubmit` (text-input path, D-12) and `submitRejected` (rejection toast, D-10) inbound message types. Add to `BUS_PROTOCOL_VERSION` handshake.

</code_context>

<specifics>
## Specific Ideas

- **The audit identified Phase 9 as the one real decision point.** Quote from `v0.12.0-MILESTONE-AUDIT.md` Executive Summary: *"ship-ready if the four Phase 7 dispatch deferrals are either (a) accepted as tech debt for v0.13.x or (b) closed by a small plan that wires them."* Phase 9 is the (b) path. Audit explicitly calls these "live functionality that the code claims to implement but doesn't actually run."
- **Fan-out without back-pressure.** The user's concern around the broadcaster is the implicit one: a stuck DevOverlay subscriber must never back-pressure memory extraction. The priority-filter (D-07) + drop-oldest (D-06) combo is the minimum-coupling answer. Mirrors Phase 4's `TokenDeltaDropOldestChannel` pattern that already exists in the Replay package.
- **VisionRouter's existing API was designed for this.** `route(...)` returns a `RouteDecision` (tier + modelID); `evaluatePostResponse(...)` returns a `EscalationOutcome` enum that already includes `.useT1Result` for the t2-unavailable case. Phase 7's design was looking ahead to this dispatch shape — Phase 9 just calls the functions.
- **Minimal-blast-radius bias throughout.** D-01 / D-03 / D-09 / D-12 all picked the option with fewest cross-package signature changes. Phase 9 is a wiring phase; it should not refactor the surfaces that prior phases locked.

</specifics>

<deferred>
## Deferred Ideas

### Out-of-scope for Phase 9 (deferred to follow-on phases / backlog)
- **vllm-mlx sidecar landing** — D-04 ships `t2Provider == t1Provider`; the real T2 path lands in a future plan that wires the sidecar lifecycle (Phase 7 Claude's-discretion item).
- **Replay-time vision escalation viewer** — D-02 records both attempts under one `turnId` with an `escalation_attempt` marker, but no Replay viewer surface for it lives in Phase 9. Deferred until a vision-aware replay viewer is needed.
- **NullBusEmitterAdapter → real Bus emitter** for voice-side outbound events beyond rejection (e.g., voice-state telemetry the chat panel might want). D-09 replaces it with a real adapter, but the *surface* of what it emits stays minimal in Phase 9 — additional voice→Bus events come later as needed.
- **AGENT-09 retry semantics around vision escalation** — D-02's same-turnId retry is a different beast from AGENT-09's `stream_truncated` retry-with-fresh-turnId. Phase 9 keeps them visibly distinct (the escalation marker is not an AGENT-09 retry). If the two paths ever need to reconcile (e.g., T2 stream truncates), planner picks the conservative resolution: AGENT-09 wins, escalation gets one shot.
- **`PresenceStateSnapshot` time-machine queries** — D-13 stores only the latest event; Phase 7 D-08 already deferred point-in-time recall. Reaffirmed.
- **Voice-rejection banner localization / wording polish** — D-10 ships English copy. UX/localization waits.
- **`SubmitRejectionMetrics` telemetry** — counting rejections per session for evals would be useful but is Phase 8 / Hardening territory, not Phase 9.

### Reviewed Todos (not folded)
None — `gsd-sdk query todo.match-phase 9` returned `todo_count: 0`.

</deferred>

---

*Phase: 09-orchestrator-wiring*
*Context gathered: 2026-05-01*
