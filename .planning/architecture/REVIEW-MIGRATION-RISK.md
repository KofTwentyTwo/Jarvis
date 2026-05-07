# Review: Migration Risk — v0.1
**Reviewer:** Migration-risk critic (swarm phase 3b, parallel with 3a/3c)
**Target:** `JARVIS-API-DESIGN-v0.1.md`
**Date:** 2026-05-07

---

## Summary

**Verdict: medium-risk; proceed only with the sequencing in §"Recommended cutover sequence" plus three blocking mitigations resolved before the first migration commit.**

The v0.1 design is well-shaped and its inventory coverage is complete. The migration risk is not in the *target* — it is in the *substrate the design quietly assumes*. Today's code has at least nine silent-failure points carefully papered over by boundary gates (`scripts/check-install-order.sh`, `check-orchestrator-events-single-consumer.sh`, `check-single-memory-mutated-emit.sh`, `check-single-writer-hudstate.sh`, `check-bus-protocol-version.sh`). The v0.1 surface re-shapes events without re-shaping the substrate that produces them. If a migration commit moves an event to the new surface and the old emit site stays in place, the boundary gates may go green while production is in a worse state than at HEAD (because we now have two emit paths racing into one client).

**Top 3 risks the team should know before committing:**

1. **The install-order DAG (`vision → memory → mcp → agent → voice → selfKnowledge`) lives inside `applicationWillFinishLaunching` with named install Tasks awaiting each other (`App/AppDelegate.swift:611-689`). The new API surfaces (Turn / Voice / Memory / Vision) cut across this dependency graph. A naïve "extract Turn surface first" plan moves the orchestrator's bus emission, but `installAgent` runs before `installVoice` and constructs the `outboundBatcher` that voice later reuses. Cutover must respect this graph or the app boots with a half-installed Voice subsystem.**

2. **`OutboundBatcher` coalesces `tokenDelta` events with no `turnId` in the wire shape (`packages/Bus/Sources/Bus/OutboundBatcher.swift:84-87`). v0.1's `Turn.tokenStreamed(turnId:text:)` requires per-turn correlation. Any commit that adds the `turnId` field but leaves the batcher's joined-string drain in place creates a "wrong turn's tokens" silent failure exactly of the B-class. Worse, the harness might still pass because it consumes events through the orchestrator stream, not through the batcher.**

3. **Single-emission-site boundary gates (`check-single-memory-mutated-emit.sh`, `check-single-memory-used-emit.sh`, `check-single-writer-hudstate.sh`) are grep gates, not behavioral gates. They are easy to satisfy by *renaming* the emit and *forgetting to delete the old one*. The migration introduces parallel new event types (`Memory.factMutated`, `Turn.hudStateChanged`) — there is a real chance the old `BusOutbound.hudState` emit and a new `Turn.hudStateChanged` emit both ship live, both go through the same `HudStateCoordinator`, and the gate stays green because the literal string changed.**

---

## Recommended cutover sequence

The dependency rule is: **a surface can migrate only after every surface its events ride on has migrated.** This produces a partial order, not a sequence. The sequence below is the topo-sort that minimizes "live-fire" risk:

### Phase M-0 — Pre-migration gates (no production code changes)

1. **Lock the API contract package.** Create `packages/JarvisAPI/` exposing the v0.1 surface as Swift types. NO conformers, NO call sites yet. Everything compiles green; the existing app does not import it.
2. **Add Bus protocol version bump to `2.4.0-rc`** with a "shadow channel" — both old `BusOutbound` and new `Turn.tokenStreamed`-shape events are wire-encodable; the WKScriptMessage handler accepts either. The handshake mismatch alert (currently in `WebviewBridge.swift:34` + `App/AppDelegate.swift:2058-2060`) MUST recognize `2.3.0` AND `2.4.0-rc` as compatible during the migration window. **Rollback knob #1: revert this commit and the version is back to `2.3.0` strict.**
3. **Add the harness target** that drives commands through direct Swift actor calls (no transport). This is Phase 5 of the swarm but it must land *before* any subsystem migrates — the gate harness runs at every commit thereafter.
4. **Promote the existing boundary gates from grep to behavioral.** Specifically: rewrite `check-single-writer-hudstate.sh` to assert via the harness that there is exactly one writer (call `Turn.hudStateChanged` from two paths in a probe build; assert harness sees one event, not two). Grep gates have already failed once with the v0.12.0 milestone audit being "structurally correct but runtime-false" (handoff note re: `installAgent` deps gate).

### Phase M-1 — Self surface FIRST (lowest blast radius, highest information value)

The Self surface has no commands, only queries and the `selfStateChanged` event. It is the cleanest test of the API approach because:
- It depends only on `SelfStateAdapter` (already isolated, `App/AppDelegate.swift:1614-1622`).
- B-08 (model paraphrase) is the smallest carry-forward bug — its fix lives entirely in `getSelfState`'s return shape (canonical `modelId` + `modelDisplayName`).
- A failure here means we discover the API approach is wrong before we touch Voice or Memory.

Migrate `Self.getSelfState`, `Self.listAudioDevices`, `Self.listCameraDevices`, `Self.getActiveAudioRoute`, `Self.tccStatusChanged`. Reuse existing `MCPClient` in-process tools as the Swift-side implementation; just expose them at the new surface.

**Gate:** harness asserts B-08 dissolved (probe `getSelfState`, assert turn that referenced it does not contain "Opus 4.5" in assistant text across N≥10 trials).
**Rollback:** delete `Self` surface routing; in-process tools continue to be reachable via the agent. No data lost, no schema migration.

### Phase M-2 — Settings surface (read-mostly, low blast radius)

`Settings.getSettings` / `Settings.setProvider` / `setTTSTier` / `setSTTBackend` / `setFeatureFlag` / `storeAPIKey` / `setHotkey` / `setWakeWordMuted`. These already exist as `ConfigStore` mutations (`packages/Config/Sources/Config/ConfigStore.swift:6-24`). The only new behavior is `settingsChanged` event. The Wizard / Settings window still drives the underlying `ConfigStore` directly during the migration window (dual-writer is acceptable here because the data is single-source-of-truth in the store; both paths converge).

**Gate:** harness asserts `setProvider(.ollama)` fires `settingsChanged(["provider"])` and `getSettings.provider == .ollama` immediately afterward.
**Rollback:** Settings surface is additive over `ConfigStore`. Revert is removing the surface adapter. No persistence change.

### Phase M-3 — Diagnostics surface

Already adapted via DevOverlay (`packages/DevOverlay/`); just exposes `devSnapshotUpdated` / `getDevSnapshot` / `toggleDevOverlay` / `copyStateDump` / `getStateDump`. Banner queue (`Diagnostics.systemBannerEnqueued` / `systemBannerDismissed`) layers cleanly over `HUDBannerCoordinator` (`App/HUD/HUDBannerCoordinator.swift:14-99`).

**Gate:** harness asserts that a banner enqueue produces exactly one event (boundary check that the AppKit banner panel didn't independently emit).
**Rollback:** revert; banners go back to `HUDBannerCoordinator` direct calls.

### Phase M-4 — Memory surface

Single-emit gates apply hard. Migrate `Memory.factMutated` *by replacing* the existing `MemoryStore.applyOp` replay-event emit, not by adding alongside. Same for `factsRetrieved`. `forgetFact` / `listRecentFacts` / `searchFacts` — already exist on `MemoryStore`.

**Gate:** harness asserts `MemoryStore.applyOp(.add, …)` produces exactly ONE `factMutated` event, AND `check-single-memory-mutated-emit.sh` continues to pass (now matching the new emit literal).

**Rollback:** revert in one commit; old replay event still exists for replay-roundtrip oracle. **Risk:** `recentTurnsForSession` is the B-02 fix path — the orchestrator must call it before building messages. If migration ships history-loading but cache-hint gating (`AgentOrchestrator.swift:297`) silently flips to `extended1h`-cache-eligible because the system prompt grew, we trade B-02 for a regression of the `streamTruncated` bug already fixed in Phase E (2026-05-03 audit). The harness MUST assert that B-02 fix does not re-trigger streamTruncated.

### Phase M-5 — Vision surface (B-03 land)

`Vision.requestFrameAttach(reason: .hudButton)` returns `Result<FrameAttachArmed, FrameAttachError>` instead of fire-and-forget `BusReply.success`. The existing handler at `App/AppDelegate.swift:2115-2117` swallows the result; that's exactly B-03's failure mode. Migration:
1. Add `Vision.requestFrameAttach` as a typed command alongside the existing inbound case.
2. Webview chooses the new shape (HUD camera button switches to typed call).
3. Old inbound case can stay as a deprecated alias for one release.

**Gate:** harness asserts `requestFrameAttach(reason: .hudButton)` returns `FrameAttachArmed` within 100 ms. The existing camera button click → bus message round-trip MUST be exercised by a headless webview probe; pure Swift-side tests would have passed today and missed B-03.
**Rollback:** revert the surface; webview falls back to `frameAttachRequested` inbound case.

### Phase M-6 — Voice surface (B-04, B-05 land)

**This is the highest-risk migration.** Voice is the audio-tap-thread real-time-safety domain (Tap-Thread Discipline rule from project-level conventions). The audio graph today bridges:

- `AudioGraphOwner` (CoreAudio tap thread) → `BufferBroadcaster` (subscribers) → `WakeWordDAG` (mel ring) + `ProductionChunkPump` (STT continuation) + `AudioLevelEmitter` (~30 Hz RMS).

The new `Voice.audioLevelChanged` event sits at the leaf of this graph, but `Voice.startVoice() -> Result<Void, VoiceStartError>` covers the *entire installation*. If the migration commit breaks the install-order DAG (or breaks the chain from `audioGraphOwner.ringBuffer` → `wakeWordDAG.start(ring:)` at `App/AppDelegate.swift:898`), B-04 isn't fixed — it is *re-broken differently*.

Two sub-phases:
- **M-6a:** map existing voice events to new surface, no audio-graph change. Assert via harness that `audioLevelChanged` cadence is ~30 Hz when mic is granted.
- **M-6b:** expose B-04 fix at the surface — if the audio graph fails to produce frames within 500 ms of `startVoice()`, surface `voiceDegraded(reason: .microphoneRevoked)` rather than silent dormancy.

**Gate:** harness asserts `startVoice()` returns success ⇒ ≥10 `audioLevelChanged` within 500 ms. Failure = the substrate is dead (B-04 still live) and the surface migration is rolled back.
**Rollback:** voice is the most independent subsystem in terms of state — no DB schema, no other surface depends on Voice. Revert is clean.

### Phase M-7 — Turn surface (the keystone)

Migrate last because every other surface emits events that ride the same outbound channel as Turn events. Specifically:
- `Turn.tokenStreamed(turnId:)` requires changing `OutboundBatcher`'s coalesce shape to be turn-keyed.
- `Turn.turnStarted` / `turnEnded` / `toolCallStarted` / `toolCallEnded` each replace existing `BusOutbound` cases.
- `Turn.hudStateChanged` REPLACES `BusOutbound.hudState` and the `HudStateCoordinator` becomes its single writer (gate-enforced).
- `Turn.confirmationRequested` / `confirmationResolved` / `respondToConfirmation` collapse `ConfirmationBroker` + `ConfirmationPresenter` + the bus into one typed surface.

**Gate:** every harness scenario from §M-1..M-6 still passes, plus B-02 (history threading), B-06 (chat scroll anchors via turnId).
**Rollback:** the worst rollback in the plan because Turn touches every surface. Mitigation: keep the M-0 dual-channel transport active until M-7 is verified across N≥3 days of live use.

---

## Findings

### R-001: Install-order DAG is encoded in source AND a boundary gate
**Severity:** HIGH
**Subsystem:** Cross-cutting (App)
**Phase:** M-1 onward
**Risk:** The install order `vision → memory → mcp → agent → voice → selfKnowledge` (`App/AppDelegate.swift:611-689`) is enforced by `scripts/check-install-order.sh` checking literal source ordering. Any migration that moves install code into a `JarvisAPI` package will fail the gate even if the runtime order is preserved. Conversely, the literal-line-ordering check passing does NOT prove the Tasks `await` each other in the runtime DAG — only that the source is in the right order.
**Likelihood × impact:** med × high — boundary gate failure is an immediate red CI; a runtime DAG break is an "MCPRuntime built ~900 ms after installAgent skipped" silent failure, exactly what the handoff describes as the bug class to be dissolved.
**Mitigation:** before M-1, rewrite `check-install-order.sh` as a behavioral test that boots the harness and asserts log-line ordering with timing assertions. Source-grep on `await self?.…installTask?.value` AND on the install method bodies.
**Rollback:** revert; original gate works by line-grep.

### R-002: `OutboundBatcher.tokenDelta` coalesces without `turnId`
**Severity:** BLOCKING
**Subsystem:** Bus / Turn
**Phase:** M-7
**Risk:** `OutboundBatcher` joins all pending tokens into one `tokenDelta` (`packages/Bus/Sources/Bus/OutboundBatcher.swift:84-87`). The 33 ms coalesce window can span two turns if `bargeIn` arrives mid-window — tokens from the superseded turn would be appended to the new turn's `tokenStreamed`. v0.1's `tokenStreamed(turnId:text:)` makes this explicit but the batcher implementation does not yet partition by turn.
**Likelihood × impact:** med × high — once we expose `turnId`, a wrong-turn token is debuggable; today it is invisible because the wire has no turnId. Migration that adds the turnId field but doesn't fix the batcher creates a post-fix regression.
**Mitigation:** in M-7, change `OutboundBatcher.postToken` to take `turnId: TurnID` and key the pending buffer by turn. `flushAndSend` for `turnEnded` MUST flush only that turn's tokens. Add a harness scenario: submit-cancel-submit within 30 ms; assert no token from turn 1 appears under turn 2's `turnId`.
**Rollback:** revert; batcher resumes joining without turnId.

### R-003: `frameAttachRequested` returns `.success` regardless of state change
**Severity:** HIGH
**Subsystem:** Vision
**Phase:** M-5
**Risk:** Today's handler (`App/AppDelegate.swift:2115-2117`) does `await self.frameAttachController?.requestAttach(reason: .hudButton); return .success` — the optional-chain on a nil controller returns success silently. This is the B-03 mechanism. The migration to `Result<FrameAttachArmed, FrameAttachError>` only kills B-03 if the surface implementation does NOT preserve this pattern. Easy to copy-paste the bug forward.
**Likelihood × impact:** high (drift-by-default) × med
**Mitigation:** the typed surface must `guard let controller = frameAttachController else { return .failure(.cameraPermissionDenied(…)) }` — make nil-controller → typed error mandatory. Harness tests with `frameAttachController = nil` and asserts `Result.failure`.
**Rollback:** revert; webview falls back to old swallowed path (B-03 reappears).

### R-004: `HudStateCoordinator` single-writer gate is grep-only
**Severity:** HIGH
**Subsystem:** Cross-cutting (HUD)
**Phase:** M-3, M-7
**Risk:** `scripts/check-single-writer-hudstate.sh` confirms one literal source location emits HudState. Adding `Turn.hudStateChanged` event under v0.1 can pass the gate by renaming the emit while the old `BusOutbound.hudState` emit slips into another file. Two emits → two HUD state machines → racing UI glitches not caught by unit tests.
**Likelihood × impact:** med × high
**Mitigation:** convert the gate to behavioral. Probe build emits HudState from two paths; harness asserts exactly one event reaches the bus client.
**Rollback:** revert offending commit; gate is grep again.

### R-005: Boundary gate `check-bus-protocol-version.sh` blocks dual-channel migration
**Severity:** MEDIUM
**Subsystem:** Bus
**Phase:** M-0
**Risk:** The handshake at `WebviewBridge.swift:147-288` does strict equality on `BUS_PROTOCOL_VERSION = "2.3.0"`. Any v0.1 wire-shape change requires a version bump. Bumping to `2.4.0` mid-migration breaks the webview's frozen dist bundle. Bumping to `2.4.0-rc` requires `WebviewBridge.handleHelloAck` to accept a tuple of compatible versions; currently it does not.
**Likelihood × impact:** high × med (just hardcoded; easy to fix)
**Mitigation:** in M-0, modify `WebviewBridge` to accept an explicit allowlist of compatible versions during the migration window. Add a runtime warning when a non-current-but-compatible version is used.
**Rollback:** revert to single-version equality.

### R-006: `MemoryStore.recentTurnsForSession` is dead in orchestrator path; B-02 fix changes cache eligibility
**Severity:** HIGH
**Subsystem:** Memory / Agent
**Phase:** M-4 + M-7
**Risk:** B-02's fix prepends `recentTurnsForSession` history before the user message (`AgentOrchestrator.swift:283-286`). The system prompt grows, which flips `CacheHints.eligibleForSystemPrompt(...)` from gated to eligible (`AgentOrchestrator.swift:297`). Phase E (2026-05-03) audit fix exists exactly because passing `extended1h` below the cache breakpoint produced 200-OK-immediate-EOF on every chat submit. If history loading pushes the prompt past the threshold, that's fine; if the per-turn history is small (single short turn), the threshold flips back and forth across turns, causing `streamTruncated` retries on some turns and not others.
**Likelihood × impact:** med × high
**Mitigation:** harness scenario for "two short turns then a third turn" must assert no `streamTruncated` retries. Add a regression test pinning the Phase E gate behavior across the B-02 fix.
**Rollback:** disable history loading in the orchestrator; B-02 returns but `streamTruncated` regression doesn't ship.

### R-007: B-04 audio graph fix predates the migration; its scaffolding is in `AudioGraphOwner` already
**Severity:** MEDIUM
**Subsystem:** Voice
**Phase:** M-6
**Risk:** The handoff says "TCC `requestAccess` was added in `b92d062` but no audio reaches the DAG." The wiring at `App/AppDelegate.swift:894-901` is `if let ring = await graphOwner.ringBuffer { await wakeWordDAG.start(ring: ring) }` — when `ringBuffer` is nil, we get a warning log and silent dormancy. The migration's `startVoice() -> Result<Void, VoiceStartError>` must not let this nil silently degrade — it must return `.audioGraphFailed(reason: "ringBuffer nil after open()")`. If migrations ship the surface but keep the silent log, B-04 is "papered over with a return value."
**Likelihood × impact:** high × med
**Mitigation:** harness assertion: `startVoice()` success ⇒ ≥10 `audioLevelChanged` within 500 ms. Surface error otherwise.
**Rollback:** voice is independent; revert is local.

### R-008: `ConfirmationBroker` 60s timeout vs new `confirmationResolved.timeoutSeconds` config
**Severity:** MEDIUM
**Subsystem:** Turn / MCP
**Phase:** M-7
**Risk:** `ConfirmationBroker` has a hard-coded 60s timeout (`packages/MCP/Sources/MCP/ConfirmationBroker.swift:36,114`). v0.1 reads `Settings.getSettings.confirmationTimeoutSeconds` (launch-only). If the broker doesn't read from `ConfirmationPolicy.timeoutSeconds`, the API exposes a value the substrate ignores.
**Likelihood × impact:** low × med
**Mitigation:** before M-7, refactor broker to take timeout via init from `ConfirmationPolicy`. Harness asserts the configured timeout is respected.
**Rollback:** revert; broker uses 60s constant.

### R-009: `OrchestratorEvent` single-consumer gate vs new multi-surface event fanout
**Severity:** HIGH
**Subsystem:** Agent / Bus
**Phase:** M-7
**Risk:** `scripts/check-orchestrator-events-single-consumer.sh` enforces that `OrchestratorEvent` has exactly one consumer (`BusForwarder.drain`). v0.1 implies multiple consumers: the bus, the harness, the replay log, the memory extraction coordinator (already there via separate channel). Adding `Turn` events with multiple subscribers breaks this gate.
**Likelihood × impact:** high (gate is restrictive) × med
**Mitigation:** in M-0, evolve the gate to "exactly one *fanout* consumer" — i.e., the `BusForwarder` is the single drainer of `events`, but it can emit to multiple sinks (`AppBusForwarderSink`, `HarnessSink`, `ReplaySink`). Document this distinction. The current `BusForwarder.drain(events:sink:)` already takes a single sink — extend to take a sink fanout.
**Rollback:** revert; consumer count goes back to 1.

### R-010: TCC permission state is not surfaceable until the user grants in System Settings
**Severity:** MEDIUM
**Subsystem:** Self / Voice / Vision
**Phase:** M-1, M-5, M-6
**Risk:** v0.1's `Self.tccStatusChanged(permission:granted:)` requires Swift to know when permission flips. macOS does NOT push a notification when the user toggles a TCC switch; we must poll or re-probe at app foreground events. The migration assumes events are pushed; the substrate cannot fully deliver. This is a design-doc-hides-the-mechanism problem.
**Likelihood × impact:** high × low (cosmetic — eventually consistent) but **could mislead the harness**
**Mitigation:** define `tccStatusChanged` semantics as "fires on probe, not on toggle." Harness must re-probe via `applicationDidBecomeActive`. Document the lag.
**Rollback:** drop `tccStatusChanged` from v0.1; clients poll.

### R-011: `sqlite-vec` dylib bundling and load-order
**Severity:** HIGH
**Subsystem:** Memory
**Phase:** M-4
**Risk:** Carry-forward D-5/D-6: `libsqlite3.dylib` + `vec0.dylib` build-and-bundle. `MemoryStore.init` can throw if `vec0.dylib` is missing (handoff "loose ends"). `Memory.searchFacts` query in v0.1 silently degrades today; under v0.1 it must return a typed error (not throw). If the migration commit changes the surface but doesn't gate on the dylib being loadable, harness scenarios that don't rely on vector search go green while the production path is broken.
**Likelihood × impact:** high (carry-forward) × high (subtle)
**Mitigation:** v0.1 should add `Settings.getSettings.memoryVectorAvailable: Bool` (or expose via `getSelfState`) so clients know whether vector search is degraded. Harness asserts this at boot. Block M-4 commit until D-5/D-6 closed.
**Rollback:** revert; no change in production behavior.

### R-012: Hardened Runtime entitlements drift
**Severity:** MEDIUM
**Subsystem:** Cross-cutting (codesign)
**Phase:** Any
**Risk:** Adding new in-process tools to expose `Self.listAudioDevices` etc. could touch CoreAudio APIs that need new entitlements. The migration plan does not enumerate codesigning steps. `JarvisEntitlementsVerified` + `verify-entitlements.sh` is a boot gate (`App/AppDelegate.swift:438,448`); if migration adds an entitlement, every Release build needs `--pre-codesign`/`--post-codesign` re-runs. This is an "implementation-time decision the design hides."
**Likelihood × impact:** low × high (Release-only failure)
**Mitigation:** before M-6, run `bash scripts/verify-entitlements.sh --pre-codesign` against a test archive that uses the new Voice surface. Catch entitlement drift before it ships.
**Rollback:** entitlements revert in lockstep with the migration commit.

### R-013: MCP helper-app per-bundle codesign + `--deep` trap
**Severity:** MEDIUM
**Subsystem:** MCP
**Phase:** Implicit in any change
**Risk:** Each MCP helper is a separately codesigned nested `.app`. `mcp-applescript` carries the `apple-events` entitlement alone. The migration may add a new in-process tool that *replaces* a helper (e.g., a self-knowledge helper that today uses CoreAudio APIs in-process). Removing the helper means removing its bundle from `Contents/Helpers/` — if the build script doesn't drop it, the helper lingers, gets re-signed with `--deep` (which is forbidden), and crashes the next launch with a TCC mismatch.
**Likelihood × impact:** low × high
**Mitigation:** migration plan must explicitly call out helper bundle additions/removals. CI runs `bash scripts/verify-codesign-settings.sh` after every helper change.
**Rollback:** restore helper bundle; recodesign.

### R-014: The harness can't fully test webview DOM behavior (B-06 path)
**Severity:** MEDIUM
**Subsystem:** Webview
**Phase:** M-7
**Risk:** Design doc §7 acknowledges this for B-06 (chat scroll). The migration assumes a "headless webview probe" exists. None exists today (Bus tests use `MockWebView`/Swift-side fakes). Adding a real headless webview to harness is a non-trivial new subsystem.
**Likelihood × impact:** high (no harness today) × med
**Mitigation:** scope the harness to assert event delivery + ordering + payload shape, NOT DOM render. Defer DOM gates to a webview unit-test layer (`webview/packages/hud/` vitest).
**Rollback:** B-06 not fully gated; manual UAT remains required.

### R-015: `BusOutbound.sessionHistory` push gap is "fixed" by query, but client code must change in lockstep
**Severity:** MEDIUM
**Subsystem:** Webview / Turn
**Phase:** M-7
**Risk:** v0.1 retires the `sessionHistory` push and replaces with `Turn.listTurns` query at connect. Today the webview waits for the push and never receives it (DEAD). Fine. But the webview's `useEffect` on connect must change to call the query. If migration ships Swift-side surface without webview changes, the chat panel stays empty.
**Likelihood × impact:** high × low (cosmetic; chat works after first turn)
**Mitigation:** the webview-side change is in the same commit as the Swift surface. Both must merge atomically.
**Rollback:** revert both; current DEAD-but-working behavior persists.

### R-016: `installSelfKnowledgeTools` runs AFTER voice → ordering bug masked by API
**Severity:** LOW
**Subsystem:** Self
**Phase:** M-1
**Risk:** Self-knowledge tools register only after `voiceInstallTask?.value` (`App/AppDelegate.swift:686-689`) so `audioGraphOwner` is non-nil. v0.1's `Self.getActiveAudioRoute` returns `AudioRouteInfo?` (nil if audio graph not running) — but during the install window between voice-install-failure and self-knowledge-install, `getActiveAudioRoute` could be called and return nil-when-it-shouldn't.
**Likelihood × impact:** low × low
**Mitigation:** harness probes `getActiveAudioRoute` immediately at boot; assert nil ⇒ voice degraded banner is also present.
**Rollback:** N/A.

### R-017: Replay log integrity vs new event taxonomy
**Severity:** MEDIUM
**Subsystem:** Replay
**Phase:** M-4 / M-7
**Risk:** `ReplayEvent.memoryMutation(Data)` / `memoryRetrieval(Data)` are gated by single-emission scripts. If the new `Memory.factMutated` surface adds a second emit path (one to bus, one to replay log), the gate breaks. If both emits go through the same internal call, OK — but the design doesn't enforce this.
**Likelihood × impact:** med × med
**Mitigation:** make replay event emission a side effect of the API event (one call → one replay row + one bus event). Harness assertions over the replay file remain valid.
**Rollback:** preserve current single emit + bus translation.

### R-018: Cancellation semantics on bargeIn vs in-flight TTS
**Severity:** MEDIUM
**Subsystem:** Voice / Turn
**Phase:** M-6 + M-7
**Risk:** `bargeIn` should cancel the in-flight turn and (per v0.1 §5.1) the superseded turn emits `turnEnded(terminator: .superseded)`. But TTS for that turn might still be playing — `Voice.cancelTTS()` is a separate command. Are they linked? The design doc implies yes (`InterruptSequence` is internal); the substrate `TTSEngineActor` is DEFERRED (Orpheus) for tier 2. Tier-1 `AVSpeechSynthesizer` has a known stop path. If migration ships `bargeIn` without auto-cancelling TTS, the user hears the old turn while seeing the new one stream.
**Likelihood × impact:** high × med
**Mitigation:** `bargeIn` MUST trigger `Voice.cancelTTS()` internally; document the invariant. Harness asserts: bargeIn during ttsStarted ⇒ ttsEnded(reason: .cancelled) before turnStarted of new turn.
**Rollback:** revert bargeIn surface; webview falls back to chatCancelAndSubmit (current behavior).

### R-019: `dispatchesToHUD / speaks` suppression on `TurnSource.eval` is implicit
**Severity:** LOW
**Subsystem:** Turn / Harness
**Phase:** M-7
**Risk:** Harness scenarios use `TurnSource.eval(scenarioId:)` to suppress HUD + TTS. v0.1 doesn't surface the suppression flags — they live in `TurnSource`'s extension methods (`packages/Replay/Sources/Replay/ReplayEvent.swift:42,51`). A migration that re-implements `TurnSource` at the API surface might omit `dispatchesToHUD/speaks` and start speaking eval-cohort outputs aloud during nightly runs.
**Likelihood × impact:** low × med (annoying, not catastrophic)
**Mitigation:** explicitly carry the suppression contract into the API: `Turn.submitTurn(source:)` documents that `.eval` and `.replay` suppress voice + HUD. Harness assert: 100 eval turns produce zero `ttsStarted` events.
**Rollback:** revert source enum; behavior identical.

---

## Subsystem migration cards

### Self
- **First migration step:** add `Self.getSelfState` query alongside the existing in-process tool result; both return same data.
- **Highest-risk step:** B-08 fix (canonical model ID, anti-paraphrase). Mitigation: `modelDisplayName` is the only field referenced in tool result text.
- **Effort:** 0.5–1 day (mostly types + harness scenario).
- **Rollback:** delete surface; tool path resumes.

### Settings
- **First migration step:** expose `Settings.getSettings` query that wraps `ConfigStore.perTurn()` + `LaunchSnapshot`.
- **Highest-risk step:** `Settings.setHotkey` (Input Monitoring TCC, collision detector, hotkey binder all in play). Mitigation: harness asserts `setHotkey(nil)` releases binding cleanly.
- **Effort:** 1–2 days.
- **Rollback:** revert surface; Settings window drives `ConfigStore` direct.

### Diagnostics
- **First migration step:** `Diagnostics.getDevSnapshot` query.
- **Highest-risk step:** `Diagnostics.copyStateDump` (clipboard write — current behavior conflates command success with banner enqueue). Mitigation: split into command (writes clipboard) + emitted banner event.
- **Effort:** 0.5 day.
- **Rollback:** revert; menu items drive AppDelegate methods direct.

### Memory
- **First migration step:** `Memory.listRecentFacts` query.
- **Highest-risk step:** B-02 history-threading via `recentTurnsForSession` interaction with cache hints. Mitigation: harness regression for streamTruncated.
- **Effort:** 2–3 days (includes B-02).
- **Rollback:** revert; B-02 returns but no other regression.

### Vision
- **First migration step:** `Vision.getFrameAttachState` query.
- **Highest-risk step:** B-03 fix — `requestFrameAttach` returning typed Result through the Bus. Mitigation: webview must update in same commit.
- **Effort:** 1–2 days.
- **Rollback:** revert; B-03 reappears.

### MCP / Confirmations
- **First migration step:** `Turn.confirmationRequested`/`respondToConfirmation` event mapping.
- **Highest-risk step:** ConfirmationBroker timeout config wiring (R-008).
- **Effort:** 1 day.
- **Rollback:** revert; broker uses constant timeout.

### Voice
- **First migration step:** `Voice.getVoiceState` query (read-only).
- **Highest-risk step:** B-04 + B-05 — substrate audio graph + TTS invocation. Mitigation: harness gate on `audioLevelChanged` cadence + `ttsStarted` after voice-sourced turns.
- **Effort:** 3–5 days (substrate work + surface).
- **Rollback:** revert; voice subsystem returns to dormant state.

### AgentOrchestrator (Turn surface)
- **First migration step:** `Turn.tokenStreamed(turnId:)` shape change in `OutboundBatcher`.
- **Highest-risk step:** entire turn lifecycle migration (R-002, R-006, R-009, R-018 all activate at once).
- **Effort:** 5–7 days.
- **Rollback:** worst rollback in plan; M-0 dual-channel transport buys time.

### Webview
- **First migration step:** typed bus client mirroring v0.1 surfaces.
- **Highest-risk step:** atomic merge with Swift-side M-7 (R-015).
- **Effort:** 3–5 days.
- **Rollback:** revert webview to current `dist/` bundle; protocol version match keeps it functional.

---

## Failure modes

1. **Half-cutover acceptance.** A migration commit ships the new surface but leaves the old emit site in place "for safety." The harness passes against the new surface. Production has two emit paths racing into one client. Mitigation: every migration commit has a deletion of the old emit site OR an explicit "keep parallel" comment with a tracking issue and a known sunset date. Reviewer must enforce.

2. **Boundary gate satisfaction without behavioral fidelity.** Grep gates (`check-single-writer-hudstate.sh`, `check-single-memory-mutated-emit.sh`) flip green because the literal string moved. The new code has two writers in different files. Mitigation: M-0 promotes these gates to behavioral. Hard requirement before M-1.

3. **Webview frozen-bundle drift.** Swift-side migrates to v0.1 surfaces but the dist bundle in `webview/dist/` (rebuilt only via `bash scripts/build-webview.sh`) still talks v0.0. Handshake passes if version negotiation is loose; message routing fails silently. Mitigation: M-0 dual-channel transport must verify both protocol versions are accepted; M-7 commit MUST include a fresh webview build.

4. **B-04 substrate not actually fixed.** Migration ships `Voice.startVoice -> Result<...>` returning success based on `AudioGraphOwner.open()` returning, but `ringBuffer` is nil and audio still doesn't flow. Surface looks healthy; user still has dead voice. Mitigation: harness gate on `audioLevelChanged` cadence within 500 ms, not on `startVoice` return value.

5. **In-flight turn lost during M-7 commit deploy.** User submits a turn; commit lands; new build starts; new build has different turn semantics and `ActiveTurnSnapshot` shape. Conversation history goes to schema-migrated table that maps the old turn fields wrong. Mitigation: there's no live deploy here (this is a personal app), but ensure no SQLite schema migration ships in M-7. Schema migrations belong to a quiet phase, not a coordinated cutover.

---

## Open questions you'd add

(Migration-time decisions the design doc punts.)

- **Q-M-1:** Is M-0's dual-channel transport (`2.3.0` + `2.4.0-rc` both accepted) acceptable in `WebviewBridge`? It conflicts with the current strict-equality handshake. User must approve weakening this safety check during the migration window.
- **Q-M-2:** Are boundary gates allowed to be rewritten as harness-driven behavioral tests? They are codified as `.sh` scripts that run in CI; converting them to Swift tests changes the contract.
- **Q-M-3:** Migration order — Self → Settings → Diagnostics → Memory → Vision → Voice → Turn. Is the user OK with B-02 (their most-cited bug) NOT being the first thing fixed? It rides M-4, not M-1.
- **Q-M-4:** Should each migration commit be on a feature branch with a separate PR, or land directly on `develop`? Personal-use repo conventions suggest direct-to-develop, but the rollback plan is harder if commits stack without PRs.
- **Q-M-5:** What's the rollback authority? If M-7 ships and B-06 chat scroll is broken in a way the harness didn't catch, who decides whether to roll back vs forward-fix? In a one-engineer project this is "user," but stating it explicitly avoids midnight stress.
- **Q-M-6:** Do we accept that DEFERRED capabilities (Orpheus, WhisperKit, Vision T2 sidecar, presence pipeline) get their API homes defined now but no migration test? They are inert at HEAD; activating them later may surface a substrate that the migration didn't exercise.
- **Q-M-7:** Carry-forwards D-5/D-6 (sqlite-vec dylib) and D-7 (Ollama models) — must they close BEFORE M-4 (Memory)? Or can M-4 ship with those still open (substrate degraded but surface contract holds)?
- **Q-M-8:** Total estimated migration duration: **15–25 engineer-days** (~3–5 weeks calendar at solo-dev pace). Is the user OK with B-02..B-08 staying open across that window? Or does B-04 (voice dead) need a tactical patch outside the migration?
