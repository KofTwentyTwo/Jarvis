# Phase 9: Orchestrator Wiring - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-01
**Phase:** 09-orchestrator-wiring
**Areas discussed:** VisionRouter dispatch shape, Orchestrator events fan-out, Null adapter replacement, Presence + frame-attach lifecycle

---

## VisionRouter dispatch shape

### Q1 — When a turn carries an attached frame (TurnInput.images != nil), where does the orchestrator call VisionRouter?

| Option | Description | Selected |
|--------|-------------|----------|
| Pre-turn branch in runTurn | runTurn detects TurnInput.images BEFORE provider selection, calls VisionRouter.route(...) to pick T1/T3, swaps providerFactory result for that turn, runs standard streaming loop on it. T1→T2 escalation runs as second turn AFTER messageStop via evaluatePostResponse. Cleanest mental model — vision is just a different provider for one turn. | ✓ |
| ToolDispatcher decorator | Wrap the Phase 5 tool dispatcher. Vision becomes 'just another tool' — LLM emits a tool call for vision, dispatcher routes to VisionRouter.providerForTier. Symmetric with MCP tools. Downside: forces model to emit a tool call for vision; conflates tool dispatch with provider selection. | |
| Post-response evaluation hook | runTurn always uses configured text provider; after messageStop, if turn had image attached, post-response hook calls VisionRouter.evaluatePostResponse to retroactively re-run on T1 or escalate to T2. Downside: ignores VisionRouter.route entirely — T3 cloud opt-in becomes structurally unreachable; doubles latency. | |

**User's choice:** Pre-turn branch in runTurn (Recommended)

### Q2 — After T1's response flushes, how does the silent T1→T2 escalation surface to the user?

| Option | Description | Selected |
|--------|-------------|----------|
| Internal retry, same turnId | evaluatePostResponse runs inside runTurn after messageStop. If .escalateToT2, runTurn discards T1 response from model-facing history, swaps to t2Provider, re-streams, emits single .turnEnd with T2 result. ReplayLog records both attempts under one turnId with escalation_attempt marker. | ✓ |
| Separate retry-of turn (AGENT-09 style) | T1 turn ends normally with .turnEnd. Orchestrator immediately spawns fresh turn with retry_of: t1.turnId carrying same image. Cleaner replay shape but visible flicker. | |
| Stream both, pick the winner | Run T1 and T2 in parallel speculatively, deliver T2 result if it wins low-confidence-on-T1 race. Lowest user-visible latency on escalation, highest cost / GPU contention. | |

**User's choice:** Internal retry, same turnId (Recommended)

### Q3 — Where lives the "this turn carries an image and needs vision routing" detection?

| Option | Description | Selected |
|--------|-------------|----------|
| Inside runTurn, gated by TurnInput.images | AgentOrchestrator.runTurn checks input.images.isEmpty == false and calls VisionRouter.route(...) before the existing providerFactory line. Adds ~15 LOC + visionRouter: VisionRouter? optional dep on the orchestrator constructor. | ✓ |
| VisionTurnAdapter wrapping submit() | AppDelegate holds a thin adapter that intercepts TurnInput, detects images, picks provider via VisionRouter, then calls orchestrator.submit with per-turn provider override. Requires new providerOverride param on submit OR per-turn ProviderSelection injection. | |
| VisionRouter as LLMProvider implementation | VisionRouter conforms to LLMProvider; providerFactory returns it for any turn with images. Clean type-system-level resolution. Forces VisionRouter to conform; conflates routing with streaming. | |

**User's choice:** Inside runTurn, gated by TurnInput.images (Recommended)

### Q4 — Ship temporary `t2Provider == t1Provider` wiring, or wait on vllm-mlx sidecar?

| Option | Description | Selected |
|--------|-------------|----------|
| Ship as-is; T2 silently equals T1 | Keep installVision's current `t2Provider: t1` wiring. Escalation path returns .escalateToT2 → runs same provider → same answer. Effectively a no-op escalation, but the dispatch path is exercised end-to-end. Sidecar is its own phase. | ✓ |
| Add `t2Available: false` config flag | Make t2Provider optional. Router's evaluatePostResponse already handles `t2Available: false`. More honest about reality; no wasted retry. Trade-off: when sidecar lands later, wire through both AppDelegate and config. | |
| Block Phase 9 on vllm-mlx sidecar | Spin up sidecar plan first, then Phase 9 wiring. Means Phase 9 grows. Wiring debt is the actual ship blocker; sidecar is additive. | |

**User's choice:** Ship as-is; T2 silently equals T1 (Recommended)

---

## Orchestrator events fan-out

### Q5 — How do we fan out AgentOrchestrator.events to multiple consumers?

| Option | Description | Selected |
|--------|-------------|----------|
| AppDelegate-owned broadcaster shim | AppDelegate constructs an OrchestratorEventBroadcaster that owns the single for await over orch.events and re-emits to N child AsyncStreams. Simple ~50 LOC actor. Keeps AgentOrchestrator unchanged; localizes multi-consumer concern to wiring layer. | ✓ |
| Refactor events into AsyncMulticastStream on the orchestrator | Replace BoundedAsyncChannel with multicast publisher inside AgentOrchestrator. Each consumer calls orchestrator.subscribe(). Cleaner long-term API. Trade-off: changes AgentOrchestrator public surface; requires updating Phase 4 tests + DevSnapshotEmitter; larger blast radius. | |
| Single consumer (memory) + DevOverlay reads from ReplayLog | Memory consumes orch.events directly. DevOverlay reads from ReplayLog instead. Avoids fan-out. Trade-off: DevOverlay loses real-time-ness; deviates from Phase 4 plan. | |

**User's choice:** AppDelegate-owned broadcaster shim (Recommended)

### Q6 — Drop policy when a slow consumer can't keep up?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-consumer bounded queue, drop-oldest | Each child stream has its own bounded buffer (256). When a consumer's buffer is full, broadcaster drops oldest event for THAT consumer only. Memory: tokenDelta drop fine, .turnEnd never dropped (priority filter). Isolates stuck consumer. | ✓ |
| Suspend the broadcaster on any consumer's full buffer | If any consumer can't keep up, broadcaster awaits. Preserves at-least-once delivery. Trade-off: stuck DevOverlay subscriber back-pressures memory extraction — the original problem. | |
| Drop entire batch when any consumer is full | Broadcaster offers each event to all consumers; if any can't accept, event is dropped for everyone. Simpler bookkeeping. Trade-off: slow consumer hurts everyone. | |

**User's choice:** Per-consumer bounded queue, drop-oldest (Recommended)

### Q7 — How do we guarantee MemoryExtractionCoordinator never misses .turnEnd against drop-oldest?

| Option | Description | Selected |
|--------|-------------|----------|
| Priority filter: never drop .turnEnd / .toolCall on memory subscriber | Memory's subscriber configured with high-priority allowlist (.turnEnd, .toolCallStart, .toolCallEnd) that never gets dropped; only .tokenDelta and .thinkingDelta get drop-oldest. Mirrors Phase 4's TokenDeltaDropOldestChannel pattern. | ✓ |
| Memory subscriber is suspend-policy | Memory's child stream uses suspend semantics; CAN back-pressure broadcaster. Argument: memory extraction downstream of turnEnd, where rate is human-conversational, so back-pressure essentially never fires. Simpler. | |
| Memory drains directly from ReplayLog, not events | ReplayLog has every turnEnd recorded. MemoryExtractionCoordinator subscribes to ReplayLog row inserts. Trade-off: adds coupling between memory and replay; conflicts with broadcaster decision. | |

**User's choice:** Priority filter: never drop .turnEnd / .toolCall on memory subscriber (Recommended)

### Q8 — Broadcaster lifecycle?

| Option | Description | Selected |
|--------|-------------|----------|
| Lives for app lifetime, owned by AppDelegate | Broadcaster created in installAgent() and held strongly. Consumers come and go; broadcaster's drain Task ends only on app termination. Mirrors how voiceController and memoryExtractionOrchestrator are held today. | ✓ |
| Lives per AgentOrchestrator instance | Broadcaster constructed alongside orchestrator; if we ever rebuild orch, broadcaster goes too. Subscribers must re-subscribe. Slightly more disciplined; arguably premature. | |
| You decide | I'll lock 'Lives for app lifetime' — matches how other long-lived AppDelegate-owned subsystems work. | |

**User's choice:** Lives for app lifetime, owned by AppDelegate (Recommended)

---

## Null adapter replacement

### Q9 — Where do new production voice adapters live in SPM topology?

| Option | Description | Selected |
|--------|-------------|----------|
| App/Voice/ alongside the Null files | Replace NullVoiceAdapters.swift with VoiceOrchestratorAdapter.swift, VoiceTTSAdapter.swift, VoiceBusEmitterAdapter.swift in App/Voice/. Each imports AgentOrchestrator + Voice + Bus and bridges. Mirrors AppDelegateBannerAdapter / AppDelegateContextBuilderAdapter pattern. | ✓ |
| packages/Voice with a new VoiceAdapters target | Move adapters into new SPM target inside packages/Voice that depends on AgentCore. Pro: testable as pure library. Con: introduces packages/Voice → packages/AgentCore dep; couples Voice's release cadence to AgentCore. | |
| App/Adapters/ as a new top-level group | Create App/Adapters/ to hold ALL App-target adapters. Reorganization for its own sake — already have App/Voice/ and App/MCP/ as adapter homes. | |

**User's choice:** App/Voice/ alongside the Null files (Recommended)

### Q10 — How does .rejected reach the user?

| Option | Description | Selected |
|--------|-------------|----------|
| HUD banner + Bus toast | Voice path: VoiceController already drives HUDBannerCoordinator; new adapter enqueues banner like 'Already thinking — wait or say cancel'. Text path: Bus emits submitRejected{reason} event the chat panel renders as toast. Two surfaces because voice and text have different attention models. | ✓ |
| HUD ring color blip only | Brief red flash on particle ring on rejection. Quietest. Trade-off: easy to miss; loses reason; .providerUnavailable looks same as .turnInFlight. | |
| Log-only | Write structured log line and otherwise drop rejection silently. Smallest blast radius. Trade-off: voice users have no idea why nothing happened; violates 'no silent failures' from CLAUDE.md. | |

**User's choice:** HUD banner + Bus toast (Recommended)

### Q11 — Where does String→TurnInput conversion happen?

| Option | Description | Selected |
|--------|-------------|----------|
| Inside the new VoiceOrchestratorAdapter | Adapter: `func submit(text: String) async { await orchestrator.submit(.voice(text)) }`. Voice's protocol stays text-only; adapter encapsulates the lift. Symmetric pattern for text-input adapter. | ✓ |
| Refactor VoiceController to take TurnInput directly | Make VoiceController emit TurnInput (or source enum). Cleaner long-term. Trade-off: changes VoiceController's public surface; ripples into every Voice test. | |
| TurnInput becomes a Voice-package type | Move TurnInput from AgentCore into shared types package. Probably wrong — TurnInput is fundamentally orchestrator vocabulary. | |

**User's choice:** Inside the new VoiceOrchestratorAdapter (Recommended)

### Q12 — Text-input path topology?

| Option | Description | Selected |
|--------|-------------|----------|
| Direct in Bus handler, no controller | AppDelegate's Bus inbound handler for chatSubmit calls orchestrator.submit(.text(message)) directly. No TextController layer. Adds ~10 LOC to Bus handler. Symmetric with how MCP runtime handles confirmation.response. | ✓ |
| Mirror VoiceController with a TextController + adapter | Build TextController reflecting voice topology one-to-one. Architecturally symmetric. Trade-off: text doesn't have wake-word/VAD/STT pipeline that justifies VoiceController; pure ceremony. | |
| TextInputCoordinator as a thin actor | Tiny actor that owns 'is text input enabled?' / 'is the chat panel focused?' state and forwards to orchestrator. Middle ground. Probably premature. | |

**User's choice:** Direct in Bus handler, no controller (Recommended)

---

## Presence + frame-attach lifecycle

### Q13 — How does latest PresenceEvent get into per-turn system prompt?

| Option | Description | Selected |
|--------|-------------|----------|
| PresenceStateSnapshot actor, read at runTurn | New PresenceStateSnapshot actor stores most-recent (PresenceEvent, timestamp). installPresence writes to it on each event. AgentOrchestrator.runTurn calls await presenceSnapshot?.currentEnrichment() while building system prompt. Read-only from orch's perspective; honors VISION-03. | ✓ |
| ContextBuilder owns the snapshot + a build(prompt:) function | Promote ContextBuilder from static func + struct to actor with state. Orchestrator holds contextBuilder: ContextBuilder? and calls assembleSystemPrompt per turn. More refactor surface. Trade-off: changes ContextBuilder's surface that 07-05 already locked. | |
| Inject snapshot into TurnInput at submit time | Caller reads snapshot and stamps it into TurnInput as context field. Pushes policy into call sites. Trade-off: every turn-source needs to remember to read snapshot — easy to forget. | |

**User's choice:** PresenceStateSnapshot actor, read at runTurn (Recommended)

### Q14 — Prompt-injection format?

| Option | Description | Selected |
|--------|-------------|----------|
| Plain sentence appended to system prompt | Append literally 'User is at the desk.' or 'User has been away for 7 minutes.' to system prompt's tail. Models handle this natively without learning a schema; small token cost. Hides absence below D-11's 5-minute threshold. | ✓ |
| Structured `<presence>` tag block | Inject <presence state="present" lastSeenSeconds="0" /> into prompt. Machine-parseable. Trade-off: models sometimes echo XML tags; adds token cost; we don't currently use structured tags elsewhere. | |
| Suppress until state changes (only on transition turns) | Only add the presence sentence on the first turn after a state transition. Quietest. Trade-off: agent loses ambient awareness of absence-duration; D-10 says agent gets it 'in user-initiated turns', not 'once'. | |

**User's choice:** Plain sentence appended to system prompt (Recommended)

### Q15 — Where is FrameAttachController instantiated, and where does HUD camera-icon Bus message route?

| Option | Description | Selected |
|--------|-------------|----------|
| installVision builds it; AppDelegate Bus handler routes | FrameAttachController constructed in installVision() right after VisionRouter. CaptureSource adapter wraps CameraCapture; ReplaySink adapter wraps ReplayLog. AppDelegate's Bus inbound handler for frameAttachRequested calls frameAttachController.requestAttach(reason: .hudButton). Phrase-detection runs at submit-time. | ✓ |
| Frame attach lives in installAgent, alongside orchestrator | Construct FrameAttachController in installAgent() because orchestrator is its primary consumer. installVision constructs only routing surface. Trade-off: frame-attach captures need CameraCapture, built in installVision — forces ordering or shared dep. | |
| Defer frame-attach to a follow-on plan | Phase 9 closes only INT-07-01..03. INT-07-04 punts to v0.13.x. Smaller blast radius. Trade-off: leaves dead-end visible in production code; one of Phase 9's stated goals is closing INT-07-04. | |

**User's choice:** installVision builds it; AppDelegate Bus handler routes (Recommended)

### Q16 — Where does FrameAttachController.onAssistantTurnComplete() hook live?

| Option | Description | Selected |
|--------|-------------|----------|
| FrameAttachReleaseSubscriber on the broadcaster | Broadcaster gets a third subscriber that watches for OrchestratorEvent.turnEnd. When turnEnd arrives AND turn had image (turn-id-keyed lookup), it calls frameAttachController.onAssistantTurnComplete(). Decouples controller from runTurn internals; uses same observer pattern as memory + dev overlay. | ✓ |
| AgentOrchestrator gets a frameAttachController? dep + calls in runTurn | Orchestrator holds weak ref and calls onAssistantTurnComplete() directly in runTurn's finally block when input.images != nil. Tighter coupling (orch knows about Vision's controller); least moving parts. | |
| FrameAttachController auto-discards on its own timeout | Drop the explicit onAssistantTurnComplete contract and let the existing default-cancel timeout handle release. Trade-off: turn execution can take >2s; would force longer timeout and lose 'discard immediately after response' guarantee from D-15. | |

**User's choice:** FrameAttachReleaseSubscriber on the broadcaster (Recommended)

---

## Claude's Discretion

The following implementation choices were left to the planner / Claude (also captured under `<decisions>` Claude's Discretion in CONTEXT.md):

- Snapshot sentence wording for D-14 — exact phrasing and the present/absent/duration thresholds.
- `OrchestratorEventBroadcaster` internal data structures.
- Per-consumer buffer size for D-06.
- `SubmitRejectionBanner` / `chat.submitRejected` Bus message schema.
- Vision-escalation `escalation_attempt` marker shape in ReplayLog.
- `FrameAttachController` `CaptureSource` + `ReplaySink` adapter naming.
- Whether `installAgent()` is a new install function or folded into existing installers.
- Test surface for the broadcaster (likely a new `OrchestratorEventBroadcasterTests` target).

## Deferred Ideas

Captured in CONTEXT.md `<deferred>` section. Highlights:

- vllm-mlx sidecar landing (D-04 ships `t2Provider == t1Provider`).
- Replay-time vision escalation viewer.
- `NullBusEmitterAdapter` outbound surface beyond rejection.
- AGENT-09 retry semantics around vision escalation.
- `PresenceStateSnapshot` time-machine queries.
- Voice-rejection banner localization.
- `SubmitRejectionMetrics` telemetry.
