# Jarvis API Design — v0.2 (Synthesis)

**Status:** SYNTHESIS — pending 5 user-decision answers, then v1.0 lock
**Date:** 2026-05-07
**Author:** Orchestrator (swarm phase 4 synthesis), integrating REVIEW-API-CORRECTNESS / REVIEW-MIGRATION-RISK / REVIEW-TEST-CONTRACT
**Relationship to v0.1:** This is a delta document. v0.1 remains the baseline structure (7 surfaces, CQRS framing, lifecycle). v0.2 records every critic finding, takes a position on each (ACCEPT / DEFER / USER-DECISION), and surfaces the 5 sharpest questions that only the user can resolve. v1.0 = v0.1 + accepted v0.2 amendments + user-decision answers, with this delta merged inline.

---

## 1. Verdict synthesis across critics

| Critic | Verdict | Findings | BLOCKING | HIGH | MEDIUM | LOW |
|---|---|---|---|---|---|---|
| 3a — API correctness | major-revisions-needed | 21 | 2 | 5 | 9 | 5 |
| 3b — migration risk | medium-risk; proceed with sequencing | 19 | 1 | 7 | 9 | 2 |
| 3c — test contract feasibility | mostly-testable-with-named-gaps | 16 | 2 | 5 | 6 | 3 |
| **Combined** | **structural shape sound; gates needed before lock** | **56** | **5** | **17** | **24** | **10** |

**Architectural shape (7 surfaces, CQRS, TurnID correlation, typed Results) is endorsed by all three critics.** No critic recommends restructuring the surface set or the framing. The pivot premise holds.

**Five BLOCKING items:**

1. **F-001** — `setTTSTier` duplicated on Voice and Settings with no canonical owner
2. **F-002** — B-05 contract is unfalsifiable for the actual root cause (orchestrator → Voice handoff is invisible at the API)
3. **R-002** — `OutboundBatcher.tokenDelta` coalesces without `turnId`; v0.1 exposes `tokenStreamed(turnId:)` but the substrate hasn't been changed
4. **G-001** — No synthetic audio injection seam; B-04 cannot be reproduced via API alone
5. **G-002** — No clock injection; every timeout-bearing operation is flake-prone or untestable

All five are addressable at the design layer (not deferrals to migration).

---

## 2. Disposition of every finding

### 2.1 BLOCKING (must resolve at v1.0)

| ID | Finding | Disposition | v0.2 amendment |
|---|---|---|---|
| **F-001** | `setTTSTier` and `setWakeWordMuted` duplicated Voice + Settings | **ACCEPT (proposed)** — see UQ-4 for user confirmation | All configuration mutation moves to Settings exclusively. Voice surface keeps only runtime control: `pttDown` / `pttUp` / `cancelTTS` / `bargeIn` (note: bargeIn migrates to Turn surface per F-? alignment). Remove `setTTSTier`, `muteWakeWord`, `unmuteWakeWord`, `startVoice`, `shutdownVoice` from Voice; replace with `Settings.setTTSTier`, `Settings.setWakeWordMuted(Bool)`, `Settings.setVoiceRunning(Bool)`. Voice surface is then strictly: ptt, cancelTTS, sttEvents, voiceState query. |
| **F-002** | B-05 contract unfalsifiable for actual root cause | **USER-DECISION (UQ-3)** — fork between explicit command vs subscription invariant | Two viable shapes; user must pick. Default proposal: explicit command. Add `Voice.synthesizeTurn(turnId: TurnID, text: String) -> Result<Void, TTSError>` which the orchestrator invokes on `turnEnded(.completed)` for voice-source turns. Harness asserts the command was issued. |
| **R-002** | `OutboundBatcher` joins tokens without turnId | **ACCEPT** — substrate refactor is part of M-7 scope | `OutboundBatcher.postToken(turnId: TurnID, text: String)` keys pending buffer by turnId; `flushAndSend` for `turnEnded` flushes only that turn's pending tokens; on `bargeIn`, all superseded-turn pending tokens are dropped. Harness scenario: submit-cancel-submit within 30 ms; assert no token from turn 1 appears under turn 2's `turnId`. |
| **G-001** | No synthetic audio injection seam | **ACCEPT (proposed)** — pending UQ-1 mode | Voice surface gains test-only commands (compile-time or runtime gated per UQ-1): `_injectAudioFrame(pcm:sampleRate:)`, `_injectWakeWord(confidence:)`, `_injectSTT(text:isFinal:)`, `_observeTTSAudio() -> AsyncStream<TTSSynthesisRecord>`. These are first-class API operations behind a harness gate, not `@testable` backdoors. |
| **G-002** | No clock injection | **ACCEPT** | v0.2 adds top-level `APIClock` protocol injected at every surface init. `RealClock` for production, `ManualClock` for harness. Operations with timeouts (frame-attach 5 s, confirmation 30 s, handshake 2 s, hangover 320 ms, batcher 16 ms) read from the injected clock. Tests advance the clock manually for deterministic timeout assertions. |

### 2.2 HIGH (resolve at v1.0)

| ID | Finding | Disposition | v0.2 amendment |
|---|---|---|---|
| **F-003** | `Turn.hudStateChanged` placed on wrong surface | **ACCEPT** | Move to **Diagnostics** surface as `Diagnostics.hudStateChanged(state: HudState)` (DevOverlay is already a Diagnostics consumer of HUD state). Add `Diagnostics.getHudState() -> HudState` query for connect-time hydration. Document: HUD state is global, not turn-scoped, no `turnId` correlation. |
| **F-004** | `Turn.bargeIn` lacks error variant | **ACCEPT** | `Command.bargeIn(text:source:) -> Result<BargeInAccepted, BargeInError>` where `BargeInError = providerUnavailable \| configError \| interruptFailed(supersededTurnId:)`. The interruptFailed case fires when cancel succeeded but the new submit didn't start. |
| **F-005** | `cancelTurn` ordering with in-flight events undocumented | **ACCEPT** | Add to §3 "Turn ordering guarantees": "After `cancelTurn(t1)` returns success, no further per-turn events for `t1` will be emitted. Any events already coalesced in the OutboundBatcher are dropped. `turnEnded(t1, .cancelled)` is the LAST event for `t1`." Harness asserts post-cancel event silence. |
| **F-006** | `respondToConfirmation` denied path undocumented | **ACCEPT** | Document: "On `outcome: .denied`, the tool returns a 'denied by user' result to the model; the model continues; `turnEnded` is emitted normally. On `outcome: .timedOut` (60s expiry), same behavior as denied. Tool result text: `\"User denied this operation\"`." |
| **F-007** | `submitTurn(images:)` and `Vision.requestFrameAttach` ordering | **ACCEPT** | Drop `images:` from `submitTurn`. Frame attach is implicit-via-state: client calls `Vision.requestFrameAttach`, gets `FrameAttachArmed { captureId, expiresAt }`, then calls `submitTurn(text:)` — orchestrator consults `FrameAttachController.confirmSend` as today. Define `FrameCaptureID = UUID`. Add `Vision.framePending(captureId:)`, `Vision.frameSent(turnId:captureId:)`, `Vision.frameExpired(captureId:)`. |
| **F-021** | Q-7 (presence) silently half-decided | **ACCEPT** | Resolve: **Self** owns presence enrichment fields (`atDesk: Bool`, `presenceConfidence: Float`) on `selfStateChanged`. **HudStateCoordinator** consumes presence intents internally (already wired). Voice does not receive presence. Q-7 closed. |
| **R-001** | Install-order DAG enforced by grep gate, not behavior | **ACCEPT** as M-0 prerequisite | M-0 adds a behavioral install-order test in the harness that asserts log-line ordering with timing. Source-grep gate stays in addition. |
| **R-003** | `frameAttachRequested` returns `.success` regardless | **ACCEPT** — already covered by F-007 amendment | The new typed surface forces `guard let controller = frameAttachController else { return .failure(.cameraPermissionDenied) }`; nil-controller cannot return success. |
| **R-004** | HudStateCoordinator single-writer gate is grep-only | **ACCEPT** as M-0 prerequisite | M-0 promotes `check-single-writer-hudstate.sh` to behavioral (probe build emits from two paths; harness asserts exactly one event reaches the bus). |
| **R-006** | B-02 fix changes cache eligibility, risks streamTruncated regression | **ACCEPT** as M-4 gate | Harness regression: after B-02 fix lands, "two short turns then a third turn" scenario MUST not produce `streamTruncated` retries. Pin Phase E (2026-05-03 audit) gate behavior. |
| **R-007** | B-04 audio graph fix paper-over risk | **ACCEPT** as M-6 gate | `startVoice() success ⇒ ≥10 audioLevelChanged within 500 ms`. Failure ⇒ surface returns `.audioGraphFailed(reason: "ringBuffer nil after open()")`, not silent log-and-degrade. |
| **R-009** | OrchestratorEvent single-consumer gate vs multi-surface fanout | **ACCEPT** as M-0 prerequisite | Evolve gate: "exactly one *fanout* drainer" (`BusForwarder.drain(events:sink:)` becomes `drain(events:sink:fanout:)`). Document distinction: drainer count = 1; sink count ≥ 1. |
| **R-011** | sqlite-vec dylib bundling and load-order | **ACCEPT** | Add `Self.getSelfState.memoryVectorAvailable: Bool` (already partially implied by INVENTORY). Harness asserts at boot. M-4 commit gates on D-5/D-6 closed. |
| **G-003** | TCC denial unforceable from tests | **ACCEPT (proposed)** — pending UQ-1 mode | Add `Self._forceTCCStatus(permission:granted:)` test-only command (compile-time or runtime gated per UQ-1). Re-emits `tccStatusChanged`; downstream subsystems re-probe. Real-device suite remains via env-flag (`JARVIS_TCC_DENIED_MIC=1`). |
| **G-004** | Provider stubbing not at API boundary | **ACCEPT (proposed)** — pending UQ-1 mode | Add `JarvisHost.init(transportConfig:, providerOverrides: ProviderOverrides?)` where `ProviderOverrides` includes `anthropic`, `ollama`, `ollamaEmbedder`, `memoryExtractor`. Production passes nil → real providers; harness passes mocks. The MockLLMProvider URL-protocol path is the default for harness scenarios. |
| **G-005** | 30+ error variants un-triggerable | **ACCEPT (partial)** | Each error variant in v1.0 is annotated `[trigger: real-only \| harness-injectable \| not-yet-triggerable]`. `_forceError(operation:code:)` debug command wired via the harness gate (per UQ-1). At minimum, the contract is honest about coverage. |
| **G-007** | Transport equivalence not specified | **USER-DECISION (UQ-5)** | If accepted: v0.2 adds §3.4 "Transport Equivalence." Every harness scenario runs in two modes — `transport: .inProcessActor` and `transport: .jsonRoundTrip` (real WKWebView). Existing `RealWKWebViewIntegrationTests` becomes the parametric runner substrate. If not accepted: declare JSON transport out of scope; rely on `check-bus-harness-parity.sh` (grep-only — caveat documented). |

### 2.3 MEDIUM (apply at v1.0 where cheap; defer where invasive)

| ID | Finding | Disposition |
|---|---|---|
| **F-008** | `listTurns` listed on both Turn and Memory surfaces | **ACCEPT** — keep on Turn; remove from Memory's §2 entry. |
| **F-009** | `forgetFact.requiresConfirmation: Bool` is a transport-layer leak | **ACCEPT** — remove parameter; harness bypass is via `ConfirmationBroker` test seam (UQ-1 governs). |
| **F-010** | `framePending` lacks captureId correlation | **ACCEPT** — covered by F-007 amendment (FrameCaptureID). |
| **F-011** | `voiceDegraded(.microphoneRevoked)` overlaps `tccStatusChanged` | **ACCEPT** — `Self.tccStatusChanged` is source-of-truth for permission state; `voiceDegraded` covers only capability degradation (AEC, audio graph, codec). |
| **F-012** | Naming inconsistency mute/unmute vs setMuted | **ACCEPT** — covered by F-001 amendment (Settings owns setters). |
| **F-013** | ConfirmationResponse vs ConfirmationOutcome twin enums | **ACCEPT** — single `ConfirmationOutcome` enum; command rejects `.timedOut` at boundary with `ConfirmationError.invalidOutcome`. |
| **F-014** | TurnSource.eval suppression undocumented at §5.1 | **ACCEPT** — document at §5.1 Turn surface explicitly. |
| **F-016** | No banner-dismiss command | **ACCEPT** — add `Diagnostics.dismissBanner(bannerId:) -> Result<Void, BannerError>`. |
| **F-018** | `tokenStreamed`/`thinkingStreamed` lack seq number | **ACCEPT** — add `seq: Int` per turn, monotonically increasing from 0. Harness asserts `seq == prevSeq + 1` to detect drops. |
| **F-019** | `getActiveTurn` doesn't expose tool-call state | **ACCEPT** — add `toolCalls: [ActiveToolCallSnapshot]` and `accumulatedThinking: String`. |
| **R-005** | Bus protocol version handshake blocks dual-channel migration | **ACCEPT** as M-0 prerequisite — `WebviewBridge.handleHelloAck` accepts a tuple of compatible versions during migration window. |
| **R-008** | ConfirmationBroker timeout vs config | **ACCEPT** as M-7 prereq — broker reads timeout from `ConfirmationPolicy` injected at construction. |
| **R-010** | `tccStatusChanged` semantics (probe vs toggle) | **ACCEPT** — document as "fires on probe (boot, applicationDidBecomeActive, _forceTCCStatus), not on user toggle." |
| **R-012/R-013** | Hardened Runtime + helper bundle codesign drift | **ACCEPT** as per-migration-step gate — verify-entitlements + verify-codesign-settings run at every migration commit touching them. |
| **R-014** | Harness can't fully test webview DOM (B-06) | **ACCEPT** — out of harness scope; vitest layer for DOM. v0.2 documents this explicitly. |
| **R-015** | `sessionHistory` retirement requires lockstep webview change | **ACCEPT** — atomic merge requirement for M-7. |
| **R-017** | Replay log integrity vs new event taxonomy | **ACCEPT** — replay event emission is a side effect of API event emission (one call → one replay row + one bus event). |
| **R-018** | bargeIn vs in-flight TTS cancellation | **ACCEPT** — `bargeIn` MUST trigger `Voice.cancelTTS` internally as part of the InterruptSequence. Harness asserts: `bargeIn` during `ttsStarted` ⇒ `ttsEnded(reason: .cancelled)` before `turnStarted` of new turn. |
| **G-006** | B-06 not API-testable | **PARTIAL ACCEPT** — add `Turn.turnTextComplete(turnId:fullText:)` event. Webview-side scroll ack stays out of v1.0 scope (vitest territory). |
| **G-008** | replayLog access not in API | **ACCEPT** — add `Diagnostics.streamReplayEvents(filter:)` and `Diagnostics.snapshotReplayEvents(turnId:)`. |
| **G-009** | OutboundBatcher 16ms window leaks nondeterminism | **ACCEPT** — subsumed by G-002 ManualClock. Tests advance clock past 16 ms to force flush. |
| **G-010** | Fact extraction nondeterminism | **ACCEPT** — subsumed by G-004 (`memoryExtractor` override). |
| **G-011** | Confirmation timeout path | **ACCEPT** — subsumed by G-002 + G-005. |
| **G-012** | Hard-block not observable | **ACCEPT** — replace direct `NSAlert.runModal` with `Diagnostics.hardBlockTriggered(reason:)` event followed by termination after 1 s. |

### 2.4 LOW (apply if cheap; otherwise defer to post-v1.0)

| ID | Finding | Disposition |
|---|---|---|
| F-015 | `Self` surface name vs scope | **DEFER** — naming polish; functional placement is fine. Resolve in v1.1 if it bites. |
| F-017 | LaunchAtLogin missing | **ACCEPT** — add `Settings.setLaunchAtLogin(enabled: Bool) -> Result<Void, LaunchAtLoginError>`. |
| F-020 | Subscribe/unsubscribe semantics | **ACCEPT (clarify)** — document: "Single logical client subscribes to all events on connect. Multi-client subscription deferred to v2." Eval harness CLI is the only second client and uses direct actor calls (no transport), so no parallel subscription. |
| R-016 | `installSelfKnowledgeTools` runs after voice | **ACCEPT** — minor; harness asserts boot-time `getActiveAudioRoute` returns nil ⇔ voice degraded banner present. |
| R-019 | `TurnSource.eval` HUD/TTS suppression implicit | **ACCEPT** — covered by F-014 documentation. |
| G-013 | Confirmation ordering across multiple tools | **ACCEPT** — one-line clarification in §5.1 ("Confirmations within a single turn emit in tool-call dispatch order"). |
| G-014 | Image bytes don't cross API | **ACCEPT** — `Diagnostics.lastLLMCall.imageCount` for harness assertion (no bytes). |
| G-015 | Wake-word hysteresis API affordance | **ACCEPT** — subsumed by G-001 + G-002. |
| G-016 | Replay roundtrip determinism contract | **ACCEPT** — add §3.5 "Replay Determinism" with stated nondeterministic surfaces (timestamps, durations, batch boundaries). |

### 2.5 Open questions added inline (not user-decision; resolved by amendment above)

- **F-Q-A** (connection-oriented vs stateless): Resolved by F-020 amendment — single logical client, long-lived connection.
- **F-Q-B** (in-flight turns on disconnect): Resolved — `getActiveTurn` returns running turn at reconnect; `listTurns(limit:)` returns recently-completed turns. Add `since: Date?` parameter for "completed since you last connected."
- **F-Q-C** (Voice Log home): Resolved — Voice Log is a Diagnostics window subscribing to the existing voice events + `audioLevelChanged` + `wakeWordDetected` + `sttTranscript*`. No additional events needed for v1.0.
- **F-Q-D** (harness confirmation bypass): Subsumed by UQ-1.
- **F-Q-E** (long-running query cancellation): **DEFER to v1.1** — `listTurns` and `searchFacts` are bounded by `limit:`; cancellation on disconnect is a v2 concern.
- **OQ-T2** (fixture format in spec): **DEFER** — fixture corpus shape is harness-internal at v1.0.
- **OQ-T3** (coverage requirement per Command/Event): **ACCEPT** — every Command has at least one harness scenario; every Event has at least one assertion path. Migration plan enumerates as acceptance gates per step.
- **OQ-T4** (state-ownership runtime assertion): **DEFER to v1.1** — grep gates suffice for v1.0; runtime origin tagging is v1.1 polish.
- **OQ-T5** (replay-log API surface): **ACCEPT** — covered by G-008 (Diagnostics.streamReplayEvents).
- **OQ-T6** (JarvisHost typed boot Result): **ACCEPT** — `JarvisHost.boot() async -> Result<JarvisHost, BootError>`. Harness can deterministically test boot failure paths.

---

## 3. Migration plan synthesis (delta to v0.1 §6)

The migration order from REVIEW-MIGRATION-RISK §"Recommended cutover sequence" is **adopted as canonical**:

```
M-0  Pre-migration gates           (no code changes; harness target + behavioral gates)
M-1  Self surface                  (lowest blast radius; B-08 dissolved)
M-2  Settings surface              (read-mostly; surfaces F-001 amendment)
M-3  Diagnostics surface           (HUD state moves here; F-003 amendment)
M-4  Memory surface                (B-02 land; cache-eligibility regression gate)
M-5  Vision surface                (B-03 land; webview lockstep merge)
M-6  Voice surface                 (B-04, B-05 land; substrate work + surface)
M-7  Turn surface                  (keystone; OutboundBatcher refactor; webview lockstep)
```

Plus **M-0 must complete before M-1**, and M-0 includes:

1. `packages/JarvisAPI/` package created (types only; no conformers, no callers)
2. Behavioral install-order test (R-001)
3. Behavioral single-writer HUD gate (R-004)
4. Fanout drainer pattern for OrchestratorEvent (R-009)
5. Bus protocol dual-version handshake (R-005) — pending UQ-2
6. Harness library scaffolding from G-001/G-002/G-003/G-004 seams
7. `JarvisHost.boot()` typed Result (OQ-T6)

**Estimated total: 15–25 engineer-days (~3–5 weeks calendar at solo pace).** Carry-forward bugs B-02..B-08 stay open across this window unless tactical patches are accepted (UQ-2).

---

## 4. Five user-decision questions (the synthesis ask)

These five decisions cannot be resolved from inputs alone and gate v1.0 lock. After the user answers, this delta merges into v0.1 to produce v1.0.

### UQ-1 — Test-seam mode: compile-time `#if HARNESS` or runtime `JARVIS_HARNESS=1`?

**What:** The injection commands required for testability — `Voice._injectAudioFrame`, `Self._forceTCCStatus`, `_forceError`, `ProviderOverrides`, `ConfirmationBroker` auto-approve — must exist somewhere. Two viable shapes:

- **Compile-time (`#if HARNESS`):** Production binary has zero test seams (no exposed surface, no risk of a malicious or buggy webview hitting them). Harness builds a separate binary (`Jarvis-Harness.app` or a `swift test` target). Two artifacts to ship; harness can never be enabled in a Release.
- **Runtime (`JARVIS_HARNESS=1` env at boot):** Single binary. Harness mode requires the env var at process start; production launches don't set it. Internal surface is gated behind a runtime check that fails closed if the env var is missing. One artifact, but a misconfigured launch could expose the seams.

**Recommendation:** runtime, single binary. Personal-use macOS app — Release builds are user-launched, never accept env-var injection from outside. Easier dev/test loop; one codepath.

**Why this matters:** every test-seam decision in the BLOCKING/HIGH gaps cascades from this answer. Picking shapes the entire harness API.

---

### UQ-2 — Migration sequencing: is B-02 (history threading) acceptable to wait for M-4, ~2-3 weeks in?

**What:** B-02 is the most user-visible carry-forward bug ("yes" / "why 4.5?" lose prior turn context). The recommended migration order has it landing in M-4 (Memory phase), behind Self / Settings / Diagnostics. That's roughly 1–2 weeks calendar at solo pace.

**Three options:**

- **(A) Accept ordering as-is.** B-02 stays open across M-1..M-3. Migration is clean.
- **(B) Tactical patch outside migration.** Ship a one-line fix to `AgentOrchestrator.swift:283-286` calling `MemoryStore.recentTurnsForSession` before building messages. Migration runs alongside; B-02 closes within hours.
- **(C) Reorder migration: B-02 fix is M-1.** Move Memory-history-threading ahead of Self. More risk because Memory pulls in cache-eligibility / streamTruncated regression (R-006), but B-02 dies first.

**Recommendation:** (B) tactical patch. The B-02 fix is small, isolated, and has live evidence the substrate is ready (`MemoryStore.recentTurnsForSession` exists and is tested). The migration plan stays clean, the user-visible bug closes today/tomorrow.

**Plus:** does B-04 (voice dead) also need a tactical patch? It's the next-highest user impact and rides M-6, ~2-3 weeks out. Same B/C choice applies, but the substrate is not ready (audio-graph install-order issues per R-007), so a tactical patch is more risk than for B-02.

---

### UQ-3 — B-05 contract shape: explicit `Voice.synthesizeTurn` command, or document subscription invariant?

**What:** B-05 (TTS silent on assistant text) has two viable contract shapes:

- **(A) Explicit command.** Add `Voice.synthesizeTurn(turnId: TurnID, text: String) -> Result<Void, TTSError>`. Orchestrator MUST issue this on `turnEnded(.completed)` for voice-source turns. Harness asserts the command was invoked. Larger API surface; trivially testable; orchestrator-as-driver.
- **(B) Subscription invariant.** Voice subscribes internally to `OrchestratorEvent.turnEnd` for `.voice`-source turns. v1.0 documents the subscription as a required invariant, exposed via `getVoiceState.tttsSubscriptionActive: Bool`. Harness asserts the subscription is active and that a voice turn produces `ttsStarted`. Smaller surface; subscription is a hidden internal coupling that can break silently again.

**Recommendation:** (A) explicit command. The whole pivot exists because hidden internal couplings produce silent failures. Make the handoff visible at the API.

---

### UQ-4 — Settings as the canonical configuration writer: drop `setTTSTier`, `setWakeWordMuted`, `startVoice`/`shutdownVoice` from Voice surface?

**What:** v0.1 has `setTTSTier` on both Voice and Settings, `muteWakeWord`/`unmuteWakeWord` on Voice and `setWakeWordMuted` on Settings, `startVoice`/`shutdownVoice` on Voice and (implied) on Settings. F-001 (BLOCKING) requires picking one home.

**Recommended split:**

- **Settings owns all configuration mutation:** `setTTSTier(.tier1|.tier2)`, `setWakeWordMuted(Bool)`, `setVoiceRunning(Bool)`, `setProvider(...)`, `setSTTBackend(...)`, etc. Always emits `settingsChanged`.
- **Voice owns runtime-control verbs only:** `pttDown`, `pttUp`, `cancelTTS`. These are stateless one-shot operations against the running voice subsystem.
- **`bargeIn` migrates to Turn surface.** It's a turn-lifecycle operation, not a voice operation.

**Cost:** any caller (the settings window, the menu bar, the harness) routes configuration through Settings. Voice can no longer be told to "start" except through Settings — a clean boundary, but a slightly more verbose API for callers.

**Confirm or counter-propose.**

---

### UQ-5 — Transport equivalence: does v1.0 mandate every harness scenario runs across both `.inProcessActor` and `.jsonRoundTripWebView`?

**What:** Without parametric transport in the harness, B-03-class bugs (webview emit lost en route to AppDelegate) stay invisible. With it, every scenario runs twice (actor-call mode + JSON-round-trip-through-real-WKWebView mode), doubling test runtime but proving the JSON transport is byte-for-byte equivalent to the in-process API.

**Two options:**

- **(A) Yes — mandate parametric runner.** Existing `RealWKWebViewIntegrationTests` infrastructure becomes the JSON-mode substrate. Every harness scenario has an attribute or a parametric driver that runs both modes. Test runtime grows ~2x, but B-03-class bugs become reproducible without a real user click.
- **(B) No — JSON transport out of harness scope.** Rely on `check-bus-harness-parity.sh` (existing grep gate) for byte-shape parity. Caveat documented: B-03-class bugs (webview emit drops) remain a gap; rely on manual UAT for webview-side regressions.

**Recommendation:** (A). The whole pivot premise is "tests catch what unit tests miss," and B-03 is the cleanest demonstration of the substrate gap. A parametric harness runner pays for itself the first time it catches a regression. The existing `RealWKWebViewIntegrationTests` is the proof of feasibility.

**Counter-argument:** ~2x test runtime, more harness complexity, and most scenarios pass identically in both modes. If the user is willing to accept B-03-shape blind spot, (B) is cheaper.

---

## 5. User-decision answers — LOCKED 2026-05-07

**Status:** v1.0 design contract is now `v0.1 + this v0.2 + the UQ-1..UQ-5 answers below`. Phases 5 (test contract) and 6 (migration plan) consume this triplet as canonical.

### UQ-1 — Test-seam mode → **Runtime gate (`JARVIS_HARNESS=1` env at boot)**

Single binary. All test seams gated by `if ProcessInfo.processInfo.environment["JARVIS_HARNESS"] == "1"`. Production launches don't set the var; Release uses the same binary as the harness. Follows existing `JARVIS_REAL_MODELS` / `JARVIS_REAL_CAMERA` env-flag convention. Test-seam commands (`Voice._injectAudioFrame`, `Self._forceTCCStatus`, `_forceError`, `ProviderOverrides`, ConfirmationBroker auto-approve) are first-class API operations behind this gate.

### UQ-2 — B-02 (history threading) → **(B) Tactical patch with regression test**

Ship a one-commit fix to `AgentOrchestrator.process(_:)` calling `MemoryStore.recentTurnsForSession(limit: ~10)` and prepending those turns as `messages`. Migration runs in parallel; M-4 reframes the path against the new API contract but the user-visible bug closes within a day. **Mandatory companion regression test** asserting "two short turns then a third turn" produces no `streamTruncated` retries (pins Phase E 2026-05-03 audit gate behavior across the cache-eligibility flip).

**B-04 (voice dead) stays in M-6** — substrate is not ready for a tactical patch (audio-graph install-order risk per R-007). User concurred.

### UQ-3 — B-05 contract shape → **(A) Explicit `Voice.synthesizeTurn` command**

Add `Voice.synthesizeTurn(turnId: TurnID, text: String, tier: TTSTier) -> Result<Void, TTSError>` to the API. Orchestrator MUST issue this on `turnEnded(.completed)` for voice-source turns — encoded as a contract obligation, not a subscription invariant. Harness asserts: for every voice-source turn ending in completed, `Voice.synthesizeTurn` was issued with matching turnId. The orchestrator-as-driver pattern is now explicit at the API.

### UQ-4 — Settings as canonical configuration writer → **Confirmed split**

| Surface | Owns |
|---|---|
| **Settings** | All configuration mutation. Always emits `settingsChanged`. Includes: `setTTSTier`, `setWakeWordMuted`, `setVoiceRunning`, `setProvider`, `setSTTBackend`, `setHotkey`, `storeAPIKey`, `setLaunchAtLogin`. |
| **Voice** | Runtime-control verbs only. Stateless one-shot operations. Includes: `pttDown`, `pttUp`, `cancelTTS`, `synthesizeTurn` (per UQ-3). |
| **Turn** | `bargeIn` migrates here. It's a turn-lifecycle operation. |

**Removed from Voice surface:** `setTTSTier`, `muteWakeWord`, `unmuteWakeWord`, `startVoice`, `shutdownVoice`, `bargeIn`. Settings window, menu bar items, and harness route configuration through Settings exclusively.

### UQ-5 — Transport equivalence → **(A) Parametric runner mandated**

Every harness scenario runs in two modes — `transport: .inProcessActor` and `transport: .jsonRoundTripWebView` (drives a real WKWebView via the existing `RealWKWebViewIntegrationTests` infrastructure). The harness library exposes `TransportMode` and a parametric scenario driver. Test runtime grows ~2x for harness scenarios; B-03-class bugs (webview emit lost en route to AppDelegate) become reproducible without a real user click. `check-bus-harness-parity.sh` grep gate stays in addition.

---

## 6. Next steps (Phase 4 → Phase 5/6)

The orchestrator now:

1. ✅ v0.2 + UQ answers locked (this section).
2. → Dispatch Phase 5 (test contract author) and Phase 6 (migration planner) in parallel. Disjoint write paths:
   - Phase 5 writes `.planning/architecture/JARVIS-API-TEST-CONTRACT.md` and a type-signatures-only skeleton at `Tools/jarvis-diag/`.
   - Phase 6 writes `.planning/architecture/JARVIS-API-MIGRATION-PLAN.md`.
3. → Final commit: all `.planning/architecture/` artifacts + handoff completion update.

**v1.0 single-doc merge** (composing v0.1 + v0.2 + UQ answers into one canonical document) is post-Phase-6 housekeeping; for Phases 5 and 6 the canonical reference is the **(v0.1, v0.2-locked) pair** plus the three review files.

Cross-AI peer review (GPT-5 Pro / Gemini 2.5 Pro / fresh Opus) is deferred to tomorrow per handoff §"After tonight."
