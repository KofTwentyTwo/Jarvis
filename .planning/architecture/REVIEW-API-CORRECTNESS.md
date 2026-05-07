# Review: API Correctness — v0.1
**Reviewer:** Critic agent (swarm phase 3a, parallel with 3b/3c)
**Target:** JARVIS-API-DESIGN-v0.1.md
**Date:** 2026-05-07

## Summary

**Verdict: major-revisions-needed.** The seven-surface decomposition is broadly sensible and the CQRS framing is principled, but v0.1 has real correctness holes that will calcify into v1.0 contract bugs if not pulled before lock. The design contains (a) a duplicated `setTTSTier` command spelled identically on two different surfaces with no mention of which is canonical, (b) an HUD state event placed on the *Turn* surface despite §4 declaring `HudStateCoordinator` as its writer driven by Voice/Confirmation/Agent/Presence inputs, (c) a **B-05 contract that does not actually kill B-05** (the invariant "voice turn → ttsStarted" is asserted nowhere on the Turn side; the orchestrator is what wasn't invoking TTS, but the API only obligates Voice to emit), and (d) several lifecycle gaps that would re-create the exact "wired but dead" bug class the redesign exists to dissolve.

**Top 3 most important findings:**

1. **F-001 (BLOCKING):** `setTTSTier` is defined on both Turn (Voice) and Settings surfaces with identical signature, no canonical owner, and `Settings.settingsChanged` does not fire when the Voice variant is invoked — guaranteed state-divergence bug.
2. **F-002 (BLOCKING):** B-05 contract is unfalsifiable as written. Asserting `ttsStarted` after `turnEnded(.completed) && source == .voice` only catches the case where Voice never receives the trigger; it does not catch the *actual* B-05 root cause where the orchestrator-side hand-off to `VoiceTTSAdapter.synthesize` is missing. Need a contract about *who* calls Voice with the assistant text, not just what Voice emits.
3. **F-003 (HIGH):** `Turn.hudStateChanged` is structurally on the wrong surface. §4 makes `HudStateCoordinator` a precedence-ladder resolver fed by Voice + Confirmation + Agent + Presence intents; placing the event under "Turn" silently encodes that turns own HUD state, contradicting the coordinator's role and creating a hidden cross-surface coupling.

---

## Findings

### F-001: `setTTSTier` is duplicated across two surfaces with no canonical owner

**Severity:** BLOCKING
**Category:** duplicated
**Location in v0.1:** §5.2 (Voice Commands, line 330: `Command.setTTSTier(tier: TTSTier) -> Void`) and §5.5 (Settings Commands, line 517: `Command.setTTSTier(tier: TTSTier) -> Void`)

**Problem:** The same command name with the same signature appears on two surfaces. There is no statement of which is authoritative, whether they share state, or whether invoking one fires `Settings.settingsChanged`. A client calling `Voice.setTTSTier(.tier1)` and then querying `Settings.getSettings.ttsTier` may legitimately get either value. The harness cannot assert which contract holds because the contract is silent.

**Evidence:** Line 330 (`Command.setTTSTier(tier: TTSTier) -> Void   // "tier1" | "tier2"`) and line 517 (`Command.setTTSTier(tier: TTSTier) -> Void                 // "tier1" | "tier2"`). Both Voice and Settings list `ttsTier` in their snapshots (`getVoiceState.ttsTier` line 382 and `getSettings.ttsTier` line 547), but only Settings emits `settingsChanged`.

**Suggested fix:** Pick one. Recommended: Settings owns all *configuration*, Voice exposes only *runtime control* (`cancelTTS`, `pttDown`, etc.). Remove `setTTSTier` from Voice. Apply the same audit to `setWakeWordMuted` (Settings line 528) vs `muteWakeWord` / `unmuteWakeWord` (Voice line 318-319) — these are also redundant with no documented hierarchy.

---

### F-002: B-05 contract is unfalsifiable for the actual root cause

**Severity:** BLOCKING
**Category:** bug-coverage
**Location in v0.1:** §7 "B-05 — TTS silent (text written, no audio)" (lines 970-974)

**Problem:** The B-05 contract states "After a turn where `Turn.turnEnded(terminator: .completed)` is emitted AND `TurnSummary.source == .voice`, the harness asserts that `Voice.ttsStarted(turnId:)` was emitted." But the §7 root cause says "production adapter `VoiceTTSAdapter.swift:25` is not driven when assistant text completes" — i.e. the orchestrator's path *to* TTS is broken. The contract verifies an emit *from* Voice. If the orchestrator never tells Voice anything, no `ttsStarted` fires, true — but this hinges on Voice being a passive consumer, which v0.1 nowhere states. There is no command on the API that represents "orchestrator hands assistant text to TTS." If TTS invocation is internal (Voice subscribes to orchestrator events directly), the API cannot assert the link; if it is external, there should be a command like `Voice.synthesize(turnId:text:)` and the harness should assert it was issued.

**Evidence:** Line 974: "If TTS is not invoked, `ttsStarted` never fires = test assertion fails." This is true but tautological — `ttsStarted` is the only TTS event, so its absence = TTS didn't run. The harness can't distinguish "orchestrator forgot to call" from "Voice received the call and crashed silently before emitting." Both surface as missing-event. INVENTORY.md line 125 confirms this: `VoiceTTSInterface.synthesize` is "invoked, but production adapter is not driven on assistant text" — the gap is *upstream* of Voice.

**Suggested fix:** Either (a) make the synthesize call an explicit API command (`Voice.synthesizeTurn(turnId:text:tier:) -> Result<Void, TTSError>` issued by the orchestrator on `turnEnded(.completed)` for voice-source turns, and have the harness assert this command was issued), or (b) document that Voice subscribes internally to `OrchestratorEvent.turnEnd` and add a *separate* contract for the subscription path (e.g. `voiceTTSSubscriptionActive: Bool` in `getVoiceState`). Without one of these, B-05 can recur post-cutover and look identical to a missing-permission failure.

---

### F-003: `hudStateChanged` placed on Turn surface contradicts §4 ownership

**Severity:** HIGH
**Category:** boundaries
**Location in v0.1:** §5.1 Turn Events (lines 240-244) — `Event.hudStateChanged(state: HudState)`. §4 (line 93): "HUD state … `HudStateCoordinator` (precedence-ladder resolver) … no query needed — always synced at connect."

**Problem:** The HUD state event is on the Turn surface, but §4 declares `HudStateCoordinator` is fed by intents from Voice, Confirmation, Agent, *and* Presence. Three of those four are not Turn concerns. Placing `hudStateChanged` under Turn implies (a) Turn owns HUD state (it doesn't) and (b) HUD state has a `turnId` correlation (it doesn't — its payload has no `turnId`). The schema cohesion test fails: the only HUD-related event is on a surface where every other event carries `turnId` and is scoped to a turn. A reader would reasonably assume `hudStateChanged` only fires during a turn, but `booting` and `idle` states fire outside of any turn.

**Evidence:** Line 242: `Event.hudStateChanged(state: HudState)` with no `turnId`. Line 93: HUD writers are `HudStateCoordinator`. INVENTORY line 322: `HudStateCoordinator.start(agent:voice:confirmation:)` takes three intent feeds. Line 93 also says "Webview client only … no query needed — always synced at connect" — but there's no `getHudState` query and no documentation of how the webview gets the initial state at connect.

**Suggested fix:** Move `hudStateChanged` to a top-level surface (either a new `HUD` surface, or fold into `Diagnostics` since DevOverlay also consumes presentation state, or fold into `Self` since it's a global presentation state). Add `Query.getHudState() -> HudState` so newly-connecting clients can hydrate without waiting for a transition. Document that the event is *not* turn-scoped and has no `turnId`.

---

### F-004: `Turn.bargeIn` lacks an error variant — claimed "always succeeds" is false

**Severity:** HIGH
**Category:** errors
**Location in v0.1:** §5.1 lines 130-139 — `Command.bargeIn(text: String, source: TurnSource) -> BargeInAccepted` (no Result wrapper).

**Problem:** v0.1 claims "Always succeeds" on line 132. But `bargeIn` invokes a new turn, which subjects it to every failure mode `submitTurn` has: `providerUnavailable`, `configError`. The TTS interrupt sequence (INVENTORY line 139, `InterruptSequence` 3-step) can also fail mid-cancel. Returning `BargeInAccepted` unconditionally means the harness cannot distinguish "barge-in worked, new turn started" from "old turn cancelled, but new turn failed to start because Anthropic 401."

**Evidence:** Line 134: `Command.bargeIn(...) -> BargeInAccepted` — no Result. Compare to `submitTurn` line 120 which correctly returns `Result<TurnAccepted, TurnRejected>`. §1 goal #2: "No silent `void` returns. No `Bool` returns that hide the reason for failure" — yet `bargeIn` hides it.

**Suggested fix:** `Command.bargeIn(...) -> Result<BargeInAccepted, BargeInError>` where `BargeInError` includes `providerUnavailable`, `configError`, *and* a new `interruptFailed(supersededTurnId:)` variant for when the cancel succeeded but the new submit didn't (the prior turn is gone, the new one didn't start — client needs to know).

---

### F-005: `cancelTurn` ordering with in-flight events is racy and undocumented

**Severity:** HIGH
**Category:** lifecycle
**Location in v0.1:** §5.1 line 142 — `Command.cancelTurn(turnId:)`; §3 "Turn ordering guarantees" (lines 80-83)

**Problem:** §3 asserts events within a turn are in-order, but says nothing about ordering between a `cancelTurn` command and concurrent in-flight events for the same turn. Concretely: client issues `cancelTurn(t1)` while `tokenStreamed(t1)` is mid-flight. Does the client see (a) `tokenStreamed(t1)` then `turnEnded(t1, .cancelled)`, (b) `turnEnded(t1, .cancelled)` then `tokenStreamed(t1)` (which is now spurious for an ended turn), or (c) `turnIdMismatch` because the orchestrator has already advanced state? The webview chat panel will render different things depending which it gets.

**Evidence:** §3 line 81: "Events for a given turn are delivered in-order." Line 82-83 only addresses events across concurrent turns. The 16ms `OutboundBatcher` window means `cancelTurn` could land while a batch is mid-flush.

**Suggested fix:** Document the contract: "After `cancelTurn(t1)` returns success, no further `tokenStreamed`/`thinkingStreamed`/`toolCall*` events for `t1` will be emitted; any such events already in the OutboundBatcher are dropped. `turnEnded(t1, .cancelled)` is the last event for `t1`." The harness then asserts post-cancel event silence, which catches buffer-flush bugs.

---

### F-006: `respondToConfirmation` does not specify the inverse — what happens to the turn if confirmation is denied

**Severity:** HIGH
**Category:** lifecycle
**Location in v0.1:** §5.1 lines 146-150

**Problem:** Confirmation is denied. What happens to the turn? Three possibilities: (a) tool returns "user denied" to the model, model continues generating, turn proceeds to `turnEnded(.completed)`; (b) turn ends immediately with `turnEnded(.cancelled)`; (c) turn errors with `turnError(.refusal)`. v0.1 documents none of these. The webview cannot decide whether to re-enable input. The harness cannot assert what should happen.

**Evidence:** Line 149-150: `enum ConfirmationError { case noSuchConfirmation; case alreadyResolved; case timedOut }`. Nothing about what the *turn* does next.

**Suggested fix:** Document: "On `outcome: .denied`, the tool returns a 'denied by user' result to the model (model continues); `turnEnded` is emitted in the normal way." On `outcome: .approved`, tool runs as normal. On `timedOut` (auto-resolved by ConfirmationBroker after 60s), same as denied. Also: `confirmationResolved.outcome` should match `respondToConfirmation`'s outcome, but v0.1's `ConfirmationOutcome` includes `.timedOut` while `ConfirmationResponse` (line 148) only includes `.approved | .denied` — inconsistent enums for a round-tripped value (see also F-013).

---

### F-007: `submitTurn(images:)` and `Vision.requestFrameAttach` create a hidden ordering contract

**Severity:** HIGH
**Category:** lifecycle
**Location in v0.1:** §5.1 line 119 (`images: [ImageRef]?`) and §5.4 line 462 (`requestFrameAttach`)

**Problem:** §5.1 says `images: nil` means "no vision; non-nil arms FrameAttachController." But §5.4 says `requestFrameAttach` arms a 5-second window, and INVENTORY line 194 says `confirmSend(userText:) -> ImageBlock?` is consumed by the orchestrator on submit. So the order is: client calls `requestFrameAttach`, framePending fires, *then* client calls `submitTurn` with `images: nil`(?) and the orchestrator implicitly attaches the pending frame. Or does the client pass `images: [someRef]`? What is `ImageRef`? It's mentioned (line 119) but never defined in v0.1.

**Evidence:** Line 119: `images: [ImageRef]?      // nil = no vision; non-nil arms FrameAttachController`. The comment is inverted from §5.4: arming happens via `requestFrameAttach`, not via `submitTurn`. Line 807 (coverage map): "FrameAttachController.confirmSend ... called by orchestrator on submitTurn(images:)" — so `images:` is non-nil when there's a pending frame? Or is it always nil and the orchestrator auto-attaches?

**Suggested fix:** Define `ImageRef` (UUID? capture timestamp? ID returned from `framePending`?). Document the protocol: (a) client calls `Vision.requestFrameAttach`, (b) gets `framePending(captureId:)` event with an ID, (c) calls `submitTurn(text:..., images: [.pendingFrame(captureId:)])`. OR: drop `images:` from `submitTurn` entirely; rely on `FrameAttachController` having a pending frame at submit time, attached implicitly. Pick one path, document it. Currently both are half-described.

---

### F-008: `Turn` surface owns `listTurns` query but the row-data lives in MemoryStore

**Severity:** MEDIUM
**Category:** boundaries
**Location in v0.1:** §5.3 line 450 — note "`listTurns` ... lives on the Turn surface but reads from `MemoryStore.recentTurnsForSession`"

**Problem:** This is acknowledged as a deliberate cross-surface read but the rationale ("turn history is a Turn concern, not a Memory concern") is half right. The data lifetime, schema, retention policy, and search semantics all belong to Memory. Placing `listTurns` on Turn means clients have to know about a Turn surface and a Memory surface to do conversation history. More importantly, there's a duplicate listing in §2's overview table: row 3 (Memory) lists `listTurns` as a Memory query *and* row 1 (Turn) lists `listTurns` as a Turn query. Same query name on two surfaces.

**Evidence:** §2 table line 35: Memory queries include `listTurns`. §2 table line 33: Turn queries include `listTurns`. §5.3 line 450 acknowledges the placement on Turn but the §2 overview table puts it on both.

**Suggested fix:** Pick a home. Recommended: keep on Turn (since the API client wants chronological turns, not facts), remove from Memory in §2. Or split: `Turn.listTurns` returns chronological turn metadata; `Memory.searchTurns(query:)` returns facts-and-turns by content match. Don't have the same name on two surfaces.

---

### F-009: `forgetFact` confirmation parameter is a transport-layer leak

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.3 lines 397-400 — `requiresConfirmation: Bool   // always true in production; false in harness`

**Problem:** A client-supplied parameter that the spec says is "always true in production; false in harness" is a backdoor. Either confirmation is a property of the operation (require it always; harness has its own bypass) or it's a property of the caller (require auth context). Letting any client pass `requiresConfirmation: false` defeats the safety model. The harness needs a way around confirmations, but it should be transport-level (e.g. a privileged client identity), not a parameter on a public command.

**Evidence:** Line 399: `requiresConfirmation: Bool   // always true in production; false in harness`.

**Suggested fix:** Remove the parameter. `forgetFact` always requires confirmation (in production = HUD prompt; in harness = auto-approved by `ConfirmationBroker` test seam). Confirmation policy is a Settings/runtime property, not a per-call argument. *(Defer the harness implementation route to Phase 3c.)*

---

### F-010: `framePending` event does not correlate to a `requestFrameAttach` invocation

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.4 lines 482-484

**Problem:** `framePending(capturedAt: Date)` has no ID. `frameSent(turnId: TurnID)` has the consuming turn ID but no back-reference to which `framePending` was consumed. If a user clicks the camera button twice rapidly, two `framePending` fire (or one supersedes the other?), and `frameSent` is ambiguous about which capture was used. INVENTORY line 199 hints at this: `FrameAttachReplaySink.recordImageTurn` operates on a placeholder.

**Evidence:** Lines 482-489. No correlation ID on any of the four events in this surface.

**Suggested fix:** Add `captureId: FrameCaptureID` to `framePending`, `frameSent`, and `frameExpired`. Have `requestFrameAttach` return `FrameAttachArmed { captureId: FrameCaptureID, expiresAt: Date }` so the client can correlate.

---

### F-011: `voiceDegraded` and `Self.tccStatusChanged` overlap on microphone-revoked

**Severity:** MEDIUM
**Category:** duplicated
**Location in v0.1:** §5.2 line 364 (`voiceDegraded(reason: .microphoneRevoked)`) and §5.7 line 644 (`tccStatusChanged(permission: .microphone, granted: false)`)

**Problem:** When the user revokes mic access mid-session, two events fire on two surfaces with overlapping payloads. A naive client subscriber listening only to Voice misses the TCC truth; one listening only to Self misses the user-visible banner copy. The order is unspecified.

**Evidence:** Line 367: `case microphoneRevoked` in `VoiceDegradationReason`. Line 645-650: `TCCPermission.microphone`. Both are valid, both fire for the same root event.

**Suggested fix:** Make `Self.tccStatusChanged` the source-of-truth event for permission state, and have `Voice.voiceDegraded` strictly cover *capability* degradations (AEC unavailable, audio graph lost, codec failure) — i.e. things that aren't TCC. Document: on mic revoke, the contract is `tccStatusChanged(.microphone, false)` *only*; the banner is driven from `Diagnostics.systemBannerEnqueued` which subscribes to TCC events.

---

### F-012: Naming inconsistency: `mute*WakeWord` (verb-prefix) vs `setWakeWordMuted` (set-noun-property)

**Severity:** MEDIUM
**Category:** naming
**Location in v0.1:** §5.2 lines 318-319 (`muteWakeWord`, `unmuteWakeWord`) and §5.5 line 528 (`setWakeWordMuted(muted: Bool)`)

**Problem:** Three commands for one toggle. Voice has imperative pair (`muteWakeWord`/`unmuteWakeWord`), Settings has setter (`setWakeWordMuted`). Same broken pattern as F-001's `setTTSTier`. Apply also to `startVoice`/`shutdownVoice` — symmetric verbs would be `startVoice`/`stopVoice` or `enableVoice`/`disableVoice`. "shutdown" is asymmetric and reads as cleanup-only, but `startVoice` is idempotent per line 308.

**Evidence:** Lines 308 (`startVoice`), 315 (`shutdownVoice`), 318-319 (mute/unmute), 528 (`setWakeWordMuted`).

**Suggested fix:** Pick one convention. Recommended: noun-property setters for state (`setVoiceRunning(_:)`, `setWakeWordMuted(_:)`, `setTTSTier(_:)`) on Settings; imperative for one-shot operations (`pttDown`, `pttUp`, `cancelTTS`, `bargeIn`) on the relevant surface. Drop the imperative state-toggles.

---

### F-013: `ConfirmationResponse` and `ConfirmationOutcome` are different enums for the same logical value

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.1 lines 148 (`ConfirmationResponse  // "approved" | "denied"`) and 206-207 (`ConfirmationOutcome   // "approved" | "denied" | "timedOut"`)

**Problem:** Client sends `ConfirmationResponse` (2 cases). Server emits `ConfirmationOutcome` (3 cases). The third (`timedOut`) is server-internal — fine. But two enums named almost identically for nearly the same value space invites confusion. INVENTORY line 238 has `ConfirmationOutcome.{approved, denied, timedOut}` as the canonical type.

**Evidence:** Lines 148 and 206-207.

**Suggested fix:** One enum, `ConfirmationOutcome`, with all three cases. The command takes `ConfirmationOutcome` but rejects `timedOut` at the boundary with `ConfirmationError.invalidOutcome`. Or use a sub-enum for input. Either is better than two near-twins.

---

### F-014: `TurnSource.eval` and `TurnSource.replay` suppress HUD/TTS via internal flags — undocumented at the API

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.1 line 116 (`source: TurnSource`); §6 line 915 (`TurnSource.dispatchesToHUD / speaks` flags marked "Internal suppression flags")

**Problem:** When the harness submits with `source: .eval`, the server suppresses HUD and TTS events. This is documented in INVENTORY (line 362) and §6 line 915 but not at the Turn surface §5.1. A reader of v0.1 alone would not know that `submitTurn(source: .eval, ...)` produces a different event stream than `source: .text`. This is a hidden behavioral switch. (See also Q-2 — the design's Q-2 punts this; my point is the silence already changes behavior today.)

**Evidence:** §5.1 lines 113-127 do not mention HUD/TTS suppression. §6 line 915 says "Internal suppression flags — harness uses `TurnSource.eval` which suppresses HUD and TTS."

**Suggested fix:** Document at §5.1 explicitly: "When `source` is `.eval` or `.replay`, the server does not emit `Turn.hudStateChanged`, `Voice.ttsStarted`, or `Voice.ttsEnded` for this turn. All other Turn events are emitted normally." This makes the contract testable.

---

### F-015: `Self` surface is partially a misnomer — hardware enumeration is not "self"

**Severity:** LOW
**Category:** boundaries
**Location in v0.1:** §5.7 lines 658-680 (`listAudioDevices`, `listCameraDevices`, `getActiveAudioRoute`)

**Problem:** "Self" as a concept (line 39: "System identity, hardware enumeration, boot/TCC state") groups three things that don't strongly cohere: app identity (version, model ID), system hardware (audio devices, cameras), and TCC state. The `getActiveAudioRoute` query is really a Voice concern (returns nil if voice graph isn't running, line 674). A user querying `listCameraDevices` is preparing for vision work, not introspecting the app's identity.

**Evidence:** Line 674: `Query.getActiveAudioRoute() -> AudioRouteInfo?  // nil if audio graph not running` — Voice-state-dependent.

**Suggested fix:** Either (a) rename `Self` → `System` (broader semantic umbrella); (b) move `getActiveAudioRoute` to Voice; (c) move `list*Devices` to a new `Hardware` surface. Lowest-cost: (a) + (b). The Self surface as a coherent concept loses meaning when half its operations are about hardware the app is using, not about the app itself.

---

### F-016: Missing capability — no command to dismiss a system banner

**Severity:** MEDIUM
**Category:** missing
**Location in v0.1:** §5.6 — Diagnostics commands list `toggleDevOverlay`, `copyStateDump`, no banner-dismiss.

**Problem:** `Event.systemBannerEnqueued` and `systemBannerDismissed` exist, but there's no command for the client to *trigger* dismissal. INVENTORY line 320 has `HUDBannerCoordinator.enqueue / dismissCurrent / clear` — `dismissCurrent` is a real capability with no API home. A user clicking the X on a banner has no command to issue.

**Evidence:** §5.6 lines 572-575 (commands) — only two. Banner events exist (lines 597-606) but no dismiss command.

**Suggested fix:** Add `Command.dismissBanner(bannerId: String) -> Result<Void, BannerError>` to Diagnostics. `BannerError.bannerNotInQueue` for dismissing an already-gone banner.

---

### F-017: Missing capability — `LaunchAtLoginController` toggle not in API (acknowledged Q-6)

**Severity:** LOW
**Category:** missing
**Location in v0.1:** Q-6 (line 1013); coverage line 907 marks it OPEN

**Problem:** Q-6 is correctly an open question, not silently punted, so this is partially handled. But the question is framed as "should this be added now?" when the answer is clearly yes — `LaunchAtLoginController.enable / disable` exists (INVENTORY line 334) and the Settings window calls AppKit directly today. Locking v1.0 without the command means the Settings window has to bypass the API, which violates the design's "API represents 100% of behavior" goal (§1).

**Evidence:** INVENTORY line 334; §1 line 14: "Represent 100% of Jarvis behavior at a typed, transport-agnostic boundary."

**Suggested fix:** Resolve Q-6 to "yes." Add `Command.setLaunchAtLogin(enabled: Bool) -> Result<Void, LaunchAtLoginError>` with `LaunchAtLoginError.requiresUserApproval | smAppServiceFailed(detail:)`.

---

### F-018: `tokenStreamed` and `thinkingStreamed` lack a sequence number for ordering verification

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.1 lines 165, 168

**Problem:** §3 guarantees in-order delivery within a turn, but with no sequence number, the harness cannot detect a *missing* token (if the OutboundBatcher drops one, ordering is preserved but completeness is not). `TokenDeltaDropOldestChannel` (INVENTORY line 365) explicitly drops oldest under pressure — that's an "ALIVE" lossy-channel for replay, but unclear whether the bus path is also lossy. The B-06 bug coverage (line 980) notes "this is the weakest link" — adding a seq number directly addresses that.

**Evidence:** Lines 165, 168. INVENTORY line 365: lossy channel exists for replay path. v0.1 doesn't say whether `tokenStreamed` is lossy or lossless.

**Suggested fix:** Add `seq: Int` to both events, monotonically increasing per turn, starting at 0. Harness asserts `seq == prevSeq + 1` to detect drops. Document whether the bus is lossy or lossless. (Defer the test-harness side to Phase 3c.)

---

### F-019: `getActiveTurn` returns `accumulatedText` but doesn't expose tool-call state

**Severity:** MEDIUM
**Category:** types
**Location in v0.1:** §5.1 lines 252-259 — `ActiveTurnSnapshot { turnId, source, phase, pendingConfirmationId, elapsedMs, accumulatedText }`

**Problem:** A reconnecting webview calls `getActiveTurn` to hydrate. It learns there's an in-flight turn, the accumulated text so far, and whether a confirmation is pending. It does *not* learn what tool calls have been started, completed, or are currently running. The webview chat panel renders tool-call cards (INVENTORY line 84, `ToolCardUpdate.Phase`) — without this state at hydration, the UI is stale until the next tool-call event.

**Evidence:** Lines 252-259. No tool-call array.

**Suggested fix:** Add `toolCalls: [ActiveToolCallSnapshot]` with `{callId, toolName, phase, argsPreview, resultPreview?}` for each tool call within the active turn. Also `accumulatedThinking: String` if Anthropic thinking deltas need to be re-rendered.

---

### F-020: No command to subscribe / unsubscribe from event streams (or it is implicit)

**Severity:** LOW
**Category:** lifecycle
**Location in v0.1:** §3 (Connection); throughout — no subscribe/unsubscribe commands

**Problem:** v0.1 says "Client subscribes; server emits" (line 1027) but never says how. Implicit assumption: handshake = subscribe to everything. Fine for the WKWebView (one client, all events). But the harness, CLI, and Voice Log window are also clients per §3 ("transport substitutes a different transport") — does the Voice Log window receive all turn events? All voice events? It's said to be a Diagnostics consumer (line 892), but Diagnostics events alone don't include turn lifecycle. If the Voice Log subscribes to everything, it sees `tokenStreamed` floods it doesn't need.

**Evidence:** §3 line 59: "There is a single logical client at any given time." But §6 line 940: "Eval harness CLI ... Consumes this API directly via Swift actor calls (no transport)" — that's a second concurrent client. §3's "single logical client" claim is contradicted later.

**Suggested fix:** Either explicitly enumerate which clients see which events (today: webview = all; harness = all; future: per-window subscriptions deferred to v2), or add a thin subscribe/unsubscribe layer (e.g. `Subscribe.toTurnEvents() / toVoiceEvents()`). Current ambiguity will produce the same "wired but dead" class — a window that thinks it's subscribed and isn't.

---

### F-021: Open question Q-7 (presence pipeline) silently affects multiple surface contracts

**Severity:** LOW
**Category:** open-questions
**Location in v0.1:** Q-7 line 1015

**Problem:** Q-7 asks where presence state should live. But §4 line 93 already declares `HudStateCoordinator` consumes presence (`attachPresence(_:)` per INVENTORY 322). And §6 line 825 says presence "will surface as `Self.selfStateChanged` presence fields." So v0.1 has already half-decided (in two places) while marking Q-7 as open. The decision is scattered: §4 says HUD consumes presence intents; §6 says Self holds presence state; Q-7 punts.

**Evidence:** §4 line 93; §6 line 825; Q-7 line 1015-1017.

**Suggested fix:** Pick. Recommended: Self holds the presence enrichment fields (`atDesk: Bool`, `presenceConfidence: Float`); HUD coordinator consumes presence intents internally; Voice doesn't see presence directly. Resolve Q-7 to "Self holds state, Hud consumes internally."

---

## Issues NOT found (positive controls)

I checked the following specifically and found them sound:

1. **`TurnID` is consistent across all surfaces** — every event that carries a turn correlation uses `turnId: TurnID` in the same payload position. (Checked: §5.1, §5.2 `sttTranscriptFinal` line 354, `ttsStarted` line 358, `ttsEnded` line 361; §5.3 `factMutated` line 410, `factsRetrieved` line 426; §5.4 `frameSent` line 486.) Naming and type are uniform.
2. **`turnError` enum cases cover the realistic provider failure modes** — `providerError`, `streamTruncated`, `maxTokensExceeded`, `refusal`, `configError`, `internalError` (line 232-238) — these match `LLMEvent.StopReason` (INVENTORY line 99) and the Opus 4.7 footguns documented in CLAUDE.md (`refusal` is correctly first-class). Good error coverage.
3. **B-02 contract is well-formed** — the assertion that orchestrator MUST prepend prior turns from `MemoryStore.recentTurnsForSession` before building the messages array (line 956) is verifiable via `MockLLMProvider` inspecting the messages array. Unlike B-05 (F-002), this contract bites the actual root cause.
4. **`B-08` model-paraphrase contract is honest about its limits** — line 992: "This is a soft-failure boundary (LLM output is probabilistic)." Acknowledges the harness can only reduce, not eliminate. Better than a fake-confident assertion.
5. **The single-writer rule in §4 is genuinely upheld for most state domains** — `AgentOrchestrator` writes active turn, `MemoryStore` writes facts, `VoiceController` writes voice state, `ConfigStore` writes settings. No two-writer pattern in §4 (the F-001 `setTTSTier` duplication is at the *command* layer, not the state-writer layer — the duplication is which command propagates to the writer, not who writes). Architectural foundation is sound.

---

## Open questions you'd add

In addition to v0.1's Q-1..Q-7, the following decisions are silently encoded or punted and the user should resolve them before lock:

- **Q-A: Is the API connection-oriented or stateless?** §3 implies long-lived connection (handshake, state-sync). But §6 line 940 says the eval harness consumes via "direct Swift actor calls (no transport)" — that's stateless RPC against the same surface. Are events delivered to the harness, or does the harness only call commands/queries? If events, how (subscription channel)? This affects every contract that relies on event ordering.
- **Q-B: What happens to in-flight turns on client disconnect?** §3 line 65 says agent continues in-flight turn. But the disconnected client cannot receive `turnEnded`. When the new connection arrives, `getActiveTurn` returns the running turn — but if the turn ended *between* old client disconnect and new client connect, the client sees neither `turnEnded` nor the active turn. Is there a recently-completed-turns query? `listTurns(limit:)` returns history but doesn't distinguish "completed since you last connected."
- **Q-C: Where does the Voice Log live in v1.0?** §6 line 892 defers it to "Plan 10-05 re-scope" but the Voice Log is the harness for B-04/B-05/B-07. If it's a Diagnostics window consuming `voiceStateChanged` + `audioLevelChanged` + `wakeWordDetected` + `sttTranscriptPartial`/`Final`, that's already enough. If it needs more (raw audio frames? buffer health?) the API needs an addition. Decide now before users come back asking.
- **Q-D: How does the harness bypass `requiresConfirmation`?** F-009 requires removing the parameter. The harness still needs an escape. Options: (a) `ConfirmationBroker` test seam auto-approves all when running under harness, (b) command-line flag at app launch, (c) a privileged client identity. Pick before lock; Phase 3c will need it.
- **Q-E: Is there a cancellation contract on long-running queries?** `listTurns` could return 100 rows; `searchFacts` does FTS5 + vec0 hybrid. Are queries cancellable? If the client disconnects mid-query, does the server stop? Punted today, will hurt later.
