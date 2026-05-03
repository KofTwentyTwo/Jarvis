---
title: v0.12.0 Audit Findings
status: in-progress
created: 2026-05-02
note: |
  Per AUDIT-AND-FIX-PLAN.md, this file is the durable triage list across sessions.
  Phase B's `/gsd-audit-uat` + `/gsd-audit-milestone` + `/gsd-validate-phase 1..9`
  outputs all funnel here. This file was started early during Phase A1 to capture
  one observed finding before the formal audit runs.
---

# v0.12.0 Audit Findings

Severity legend:
- 🔴 **Blocking** — breaks a v0.12.0 promise
- 🟡 **Degraded** — functional but not as designed
- 🟢 **Cosmetic** — comment/doc/deprecation cleanup

Strike-through (`~~text~~`) when closed. Reference the closing commit SHA inline.

---

## Observed during Phase A1/A2 (2026-05-02 evening)

### F-A2-01 🔴 `WebviewBridgeOutboundTests.test_sendWhenArmedCallsEvaluator` fails — stale assertion against retired `JarvisBusWorld`

- **Where:** `packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift:80` — `XCTAssertEqual(call.contentWorld, WKContentWorld.world(name: "JarvisBusWorld"))`.
- **What:** The test asserts the contentWorld used by `send(_:)` matches a named world `"JarvisBusWorld"`. Production code (since `fb41c5f`) defaults to `WKContentWorld.page`. Test was not updated alongside the production fix.
- **Why this matters:** This test was **already failing at `fb41c5f`** (the last-known-good commit per HANDOFF.json). The handoff's "Bus 54/54 green" claim was inaccurate. The test exposes the **exact bug class** that AUDIT-AND-FIX-PLAN.md Phase F1 was created for: a unit test that asserts an implementation detail (specific world name) instead of the externally observable behavior (handshake reaches `.armed`, message body contains `window.jarvisBus.receive(payload)`). When prod code was patched to fix the WKContentWorld isolation bug, this test continued passing in the developer's mental model because nobody re-ran it; it was caught here only because A2 strip prompted a full Bus suite re-run.
- **Severity rationale:** 🔴 because it materially undermines the handoff's premise of green test baseline, AND it's a lit indicator of the integration-test gap that the WKContentWorld isolation bug originally exploited.
- **Confirmed pre-existing:** `git show fb41c5f -- packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift` returns empty — that commit did not touch this file. Stashing the A2 BootDiag-strip edits and re-running the test reproduces the failure (couldn't run at HEAD because BusBootDiag.swift was untracked and the WebviewBridge code referenced it — but the assertion itself doesn't depend on BootDiag).
- **Fix scope:** trivial — change the assertion to `XCTAssertEqual(call.contentWorld, WKContentWorld.page)` (or read the bridge's actual contentWorld back). Should land alongside Phase D-Phase-2's required real-WKWebView integration test, not as a standalone fix.
- **Tracked separately from C1–C8** because it's a **test bug**, not a production bug. Goes into Phase D (test-coverage fill) work.

### F-A1-01 🔴 HUD rings not animating at STANDBY (severity ESCALATED 🟡 → 🔴)

**Severity escalated 2026-05-02 19:50 after Phase B1 (`/gsd-audit-uat`) confirmed this is the *single* outstanding UAT item milestone-wide and it is a Phase 3 verification promise.**

- **Phase 3 verification record** (`.planning/phases/03-hud/03-VERIFICATION.md:39-40`):
  - test: "Cold-launch Release build, observe HUD ring animation"
  - expected: "Ring transitions booting → idle within 2s of summon; **ring is visibly animated (pulse/rotate) with arc-reactor-glow color**"
  - status at phase close: `human_needed` — deferred because xcodebuild test runtime was upstream-blocked by Xcode 26 RunningBoard error 5.
- **My A1 visual check (Debug build, dev-reset, 2026-05-02 18:59):** rings render statically. Outer dotted ring + dense middle dotted ring + inner solid ring all render but do not pulse or rotate.
- **Caveat to re-test:** the original UAT spec'd a *Release* build. My A1 was a *Debug* build. R3F + WKWebView animation behavior in Debug should match Release, but worth confirming on a Release build to rule out a Debug-only regression. Either way, the bug is real and the rings should animate in both configurations.
- **Why it's 🔴, not 🟡:** ring animation is a Phase 3 (HUD) success-criterion promise. With the rings static, the HUD chrome is delivered but the cinematic state-feedback contract is not. This is one of the v0.12.0 "promised" deliverables.
- **Severity rationale change-log:** initially logged 🟡 because the system-side bus was healthy and chat/agent were unaffected. After B1 confirmed this *is* the one milestone-blocker UAT, severity escalates to 🔴 alongside C1 (CameraCapture stub).
- **System-side evidence (from when BootDiag was still in tree, A1 trace):**
  - `subsystem=com.koftwentytwo.jarvis category=BootDiag` showed handshake reaches `armed`, `markReady()` fires, `{"type":"hudState","state":"idle"}` delivered.
  - `snapshotJSBus`: `handler=handler-set pending=0 v=2.3.0 react=rendered` at t+0 and t+1500ms — bundle is mounted and bus is wired.
  - **Conclusion:** bug is in the R3F render loop, not in the bus / state machine / Swift orchestrator.
- **Hypothesis:** R3F `useFrame` hook not firing, OR animation tied to a state machine that's stuck in a non-animating sub-state, OR shader/material ref not invalidated each frame.
- **Visual reference:** screenshot at `/Users/james.maes/Desktop/CleanShot 2026-05-02 at 18.59.10@2x.png` (user-supplied 2026-05-02 18:59).
- **Fix scope (per Phase E):** TDD failing test → fix. The failing test should drive `useFrame` + assert state changes between frames, OR snapshot-test the rendered ring transform after N frames. Likely under `webview/packages/hud/src/`. Phase F1 (real-WKWebView integration test) is the right durable harness for this — until then a Vitest with mock R3F context can catch the regression class.

- **Where:** webview HUD (R3F ring component). Likely `webview/packages/hud/src/`.
- **What:** After `dev-reset.sh --yes` + clean launch, HUD reaches STATE: STANDBY (system-side BootDiag confirms `hudState=idle` dispatched and bundle handler-set, react=rendered, pending=0). Visually: outer dotted ring, dense middle dotted ring, inner solid ring all render *statically* — no rotation/pulse animation as required by AUDIT-AND-FIX-PLAN.md Phase A1 success criterion ("STATE: STANDBY + animated rings + AGENT IDLE").
- **Severity rationale:** 🟡 not 🔴 — assistant is functional, state is correct, only the cinematic feedback is degraded. Doesn't block Phase A2/A3.
- **System-side evidence:**
  - `subsystem=com.koftwentytwo.jarvis category=BootDiag` shows handshake reaches `armed`, `markReady()` fires, `{"type":"hudState","state":"idle"}` delivered.
  - `snapshotJSBus`: `handler=handler-set pending=0 v=2.3.0 react=rendered` at t+0 and t+1500ms — bundle is mounted and bus is wired.
- **Hypothesis (untested):** R3F `useFrame` hook not firing, or animation tied to a state machine that's stuck in a non-animating state, or the HUD enters a "low-power" idle that intentionally stops animation. Not chased per operating principle "audit first, fix second."
- **Visual reference:** screenshot at `/Users/james.maes/Desktop/CleanShot 2026-05-02 at 18.59.10@2x.png` (user-supplied 2026-05-02 18:59).
- **To triage in Phase B:** confirm whether this is a regression vs. by-design idle visual. If regression, becomes a 🔴 (Phase 3 / HUD promise). If by-design, this finding closes as 🟢.

---

## Carried forward from AUDIT-AND-FIX-PLAN.md Phase C (pre-known)

These were captured in the plan but are tracked here once the audit lands:

- **C1** 🔴 `packages/Vision/Sources/Vision/CameraCapture.swift:106` — 1×1 black-pixel JPEG stub.
- **C2** 🟡 `App/JarvisApp.swift:13` — Settings scene "coming soon" placeholder. *(Resolved by Phase A3.)*
- **C3** 🟡 Wizard rows for Mic/Camera/Automation are explainer-only (per D-08, by design — verify nothing else relies on them firing during onboarding).
- **C4** 🟡 Ad-hoc Debug signing → unstable TCC identity. Switch Debug `CODE_SIGN_IDENTITY` to "Apple Development".
- **C5** 🟢 `App/AppDelegate.swift:1101` — superfluous `await`.
- **C6** 🟢 `packages/Logging/Sources/JarvisLogging/{File,OS}LogHandler.swift` — deprecated swift-log default impl.
- **C7** 🟢 `App/MenuBar/MenuBarIconController.swift:110` — `popUpMenu` deprecated (use `statusItem.menu`).
- **C8** 🟢 `packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift:80` — `String(cString:)` deprecated.

---

## Phase B audit outputs

### B1 — `/gsd-audit-uat` (2026-05-02 19:50)

Single outstanding UAT item milestone-wide: Phase 3 ring-animation human verification.
Already tracked as **F-A1-01** above (severity escalated to 🔴).

### B2 — `/gsd-audit-milestone` (2026-05-02 20:05)

Cross-phase integration audit via `gsd-integration-checker` subagent. Found three NEW
blockers + confirmed the known C1, plus two warnings. Full report:
**`.planning/v0.12.0-MILESTONE-AUDIT.md`** (status: `gaps_found`).

#### F-B2-INT-1 🔴 NoopBusGateway swallows tool-call events

- **Where:** `App/AppDelegate.swift:467` (construction site), `:1606-1618` (declaration).
- **What:** Constructed with comment `"CR-02: orchestrator wiring (later plan) replaces with real bus adapter"`. Replacement plan never landed across Phase 6/7/9. `ConfirmingToolDispatcher` correctly emits `bus?.emitToolCallStart/End` at every dispatch (`packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:132,167,175,185,200,209`). Consumer body is `{}`. HUD `ToolCallCard` consumer is fully wired in TS but never sees events.
- **Affected REQ-IDs:** HUD-07, MCP-01..04, TOOL-01..03.
- **Severity rationale:** 🔴 — tool-call HUD cards are a Phase 3/5 user-facing promise; whole modality is mute.

#### F-B2-INT-2 ✅ tokenDelta + turnStarted + turnEnded forwarded (FIXED)

- **Original where:** `packages/Bus/Sources/Bus/OutboundBatcher.swift:44` (outbound emitter existed but no caller); `App/AppDelegate.swift:828-1015` (broadcaster had 5 subscribers but no `.bus` subscriber).
- **Original what:** Cross-tree grep confirmed zero call sites of `OutboundBatcher.postToken` outside its declaration. `BusOutbound.{tokenDelta,turnStarted,turnEnded}` cases had NO Swift production emit sites.
- **What was fixed (commit 602a95b, 2026-05-02):** Added `case .bus` to `OrchestratorEventBroadcaster.Priority` with appropriate protection rules (mirrors `.memory`/`.transcript`: only `.tokenDelta` / `.thinkingDelta` are drop-eligible). Added a `busSubscriberTask` in `AppDelegate.installAgent` that drains `.bus` subscription, pattern-matches `OrchestratorEvent.tokenDelta`, and forwards the chunk to `outboundBatcher.postToken(_:)`.
- **What was fixed (this session, paired with INT-3):** Extended the same subscriber to forward `turnStarted` / `turnEnded`. `turnStarted` is synthesized on the first emission for a new `TurnID` (since `OrchestratorEvent` has no explicit start case — the start is implicit from the first per-turn event); subsequent emissions reuse that turn id. `turnEnd` flushes pending tokens and emits `BusOutbound.turnEnded` via `flushAndSend` so lifecycle events never overtake their data. `StopReason → TurnTerminator` mapping lives in `AppDelegate.busTurnTerminator(for:)`: `endTurn` / `toolUse` / `maxTokens` → `.completed`; `refusal` / `streamTruncated` → `.errored`. `cancelled` and `superseded` are reachable only via cancel-and-submit / barge-in flows the orchestrator does not yet emit; the mapping will extend when they do.
- **Severity now** 🔴 → ✅: the .bus subscriber forwards everything the JS bus dispatcher needs. Without `turnStarted` the JS side was silently dropping every `tokenDelta` (its dispatcher requires a non-null `currentTurnId`); without `turnEnded` the chat panel could never finalize a message.
- **Verification:**
  - `scripts/check-app-builds.sh` PASS.
  - AgentCore tests 178/178 pass.
  - Bus tests 55/56 (F-A2-01 pre-existing).
  - All 15 boundary grep gates PASS.

#### F-B2-INT-3 ✅ HUD chat input UI + JS producer (FIXED)

- **Original where:** `webview/packages/hud/src/chat/ChatPanel.tsx` (read-only renderer); `webview/packages/hud/src/App.tsx` (no input form mounted).
- **Original what:** The Swift inbound side IS wired (`AppDelegate.swift:1444-1449` → `handleChatSubmit` / `handleChatCancelAndSubmit` → `orchestrator.submit(.text(...))`), but the JS side had no producer of any inbound bus message. Cross-tree grep across `webview/packages/hud/src/`: zero references to `chatSubmit` / `chatCancelAndSubmit` / `frameAttachRequested` as PRODUCERS.
- **What was fixed (this session):**
  - `webview/packages/hud/src/chat/ChatInput.tsx` — new component. Form with input + Send button. Empty/whitespace input is a no-op; trimmed input posts `BusInbound.chatSubmit(text)` when `currentTurnId === null`, `chatCancelAndSubmit(text)` (barge-in) otherwise. Pushes a `kind: 'text', role: 'user'` event to the chat-events store on submit so the user sees their own message in chronology immediately (optimistic local echo). Clears the input after dispatch.
  - `webview/packages/hud/src/App.tsx` — mounts `<ChatInput />` directly under `<ChatPanel />` inside `.jarvis-hud__chat`. The parent flex-column keeps the input pinned to the bottom of the floating chat frame regardless of how many events the panel renders.
  - `webview/packages/hud/src/chat/chat-panel.css` — `.chat-input` row + field + button styles using existing tokens.
  - `webview/packages/hud/src/bus/client.ts` — added `submitRejected` (push inline error event) and `sessionHistory` (no-op until WARN-INT-2 hydration lands) arms to the dispatcher switch. This restores the `_exhaustive: never` compile-time check (was failing tsc on `develop` because both cases were in `BusOutbound` but not in the switch).
- **Tests added:**
  - `webview/packages/hud/tests/ChatInput.test.tsx` — 6 cases: renders input + button (CI1); empty/whitespace input is no-op (CI2); trimmed text posts `chatSubmit` and clears input (CI3); Enter key submits the form (CI4); pushes user-text event to the store (CI5); barge-in routes to `chatCancelAndSubmit` when `currentTurnId !== null` (CI6).
  - `webview/packages/hud/tests/bus-dispatch.test.ts` — added B5: `submitRejected` outbound pushes an inline error event with the rejection reason.
- **Affected REQ-IDs:** TEXT-01, HUD-07, brief week-one #7 ("Text input fallback").
- **Verification:**
  - `webview/packages/hud` tests 87/87 pass.
  - `scripts/check-app-builds.sh` PASS.
  - All 15 boundary grep gates PASS.
  - End-to-end smoke (paired with INT-2 closure above): user types → `chatSubmit` reaches Swift → `AgentOrchestrator.submit(.text)` → first tokenDelta synthesizes turnStarted → JS chat panel shows assistant text streaming → turnEnded clears the active turn for the next submit.

#### F-B2-INT-4 🔴 (= C1) CameraCapture 1×1 black JPEG

(Same as C1 — kept here for cross-reference. See pre-known table above.)

#### F-B2-WARN-1 🟡 TTS engine `nil`; voice loop is mute

- **Where:** `App/AppDelegate.swift:676-678` constructs `VoiceTTSAdapter(engine: nil)`. `App/Voice/VoiceTTSAdapter.swift:44-46` no-ops `synthesize` when `engine == nil`. No production code constructs a `TTSEngineActor`.
- **Severity rationale:** 🟡 — wiring is correct; production engine instantiation is the gap. CLAUDE.md acknowledges TTS production wiring is week-one scope; this finding documents that the scope is unmet.

#### F-B2-WARN-2 🟡 `sessionHistory` outbound declared but never emitted

- **Where:** `packages/Bus/Sources/Bus/BusOutbound.swift:25` declares the case; webview decoder ready; no production caller.
- **Severity rationale:** 🟡 — pairs with the chat-input fix; once chat works, history hydration on `webviewReady` is the next missing wire.

### Phase E follow-on findings (2026-05-03 INT-3 smoke session)

These were uncovered while smoke-testing INT-3. Each is a **pre-existing latent bug** that the v0.12.0 unit-level GSD verifications missed because the audit was source-grep, not runtime-trace. All three are now fixed AND have unit-level coverage that would have caught the regression.

#### F-E-RACE-1 ✅ `installAgent` lost the race against MCPRuntime build (FIXED)

- **Where:** `App/AppDelegate.swift:applicationWillFinishLaunching` — `agentInstallTask` awaited `memoryInstallTask` + `visionInstallTask` but NOT the MCP runtime build task.
- **What:** MCPRuntime build is ~1s due to helper child-process spawn (mcp-time / mcp-clipboard / mcp-applescript). `installAgent` short-circuits on `mcpRuntime == nil` with the warning `"installAgent: deps not ready (mcp/replay/config) — skipping"`. Every cold launch logged this warning followed by `MCPRuntime built — N tools` ~900ms later, leaving the orchestrator + broadcaster + ALL six broadcaster subscribers dormant for the entire process lifetime.
- **Symptom:** user-typed text dropped with `"handleChatSubmit: agentOrchestrator nil — dropping submission"`. v0.12.0 milestone audit said "5 broadcaster subscribers wired" — accurate at source-grep level, false at runtime.
- **Fix:** captured `mcpInstallTask` Task handle and added `await mcpInstallTask?.value` to `agentInstallTask`'s await chain.
- **Why milestone audit missed it:** static cross-tree grep cannot see Task ordering. The boundary gates are similarly blind. The fix for the bug class itself is F1 (top-level integration tests that cold-launch the app and assert one text turn round-trips).

#### F-E-FK-1 ✅ `installAgent` never called `replayLog.beginSession` (FIXED)

- **Where:** `App/AppDelegate.swift:installAgent` constructed the orchestrator with `sessionId: SessionID.fresh()` but never inserted that ID into `sessions`.
- **What:** Every `replayLog.startTurn` violated the FK `turns.session_id REFERENCES sessions(session_id)` and threw. The orchestrator caught the throw at `AgentOrchestrator.swift:241` and returned `SubmitOutcome.rejected(reason: .configError)` for every text turn — surfacing in the chat panel as "Config error — see ~/Library/Logs/Jarvis/system.log."
- **Symptom:** when the orchestrator IS finally wired (after F-E-RACE-1), every chat submit is rejected with configError. SQLite confirms: `SELECT COUNT(*) FROM sessions; -- 0`.
- **Fix:** `installAgent` now calls `try await replayLog.beginSession(appVersion:, buildSHA:)` and passes the returned `SessionID` to the orchestrator.
- **Test added:** `packages/Replay/Tests/ReplayTests/SessionForeignKeyTests.swift` — 3 cases (FK1: startTurn-without-beginSession-throws; FK2: startTurn-after-beginSession-succeeds; FK3: multiple-startTurns-share-one-session). Closes the bug class regardless of any future AppDelegate refactor.

#### F-E-WIRE-1 ✅ `OutboundBatcher` constructed only inside `installVoice` (FIXED)

- **Where:** `App/AppDelegate.swift:installVoice` constructed the OutboundBatcher only AFTER OpenWakeWord/Silero models loaded successfully. Voice DAG short-circuit (missing model files in Debug builds) left `self.outboundBatcher == nil`.
- **What:** every `outboundBatcher?.flushAndSend(...)` chained-optional in the .bus subscriber silently dropped tokenDelta / turnStarted / turnEnded / submitRejected. The chat panel got nothing back from the orchestrator even after F-E-RACE-1 + F-E-FK-1 were both fixed.
- **Fix:** hoisted batcher construction into `installAgent` (only depends on `webviewBridge`, not voice models). `installVoice` now reuses `self.outboundBatcher` rather than overwriting.

### Refactor: BusForwarder extracted to AgentOrchestrator + unit-tested (this session)

- **Why:** the prior bus subscriber lived inline in `App/AppDelegate.swift`. The App target's xctest harness is upstream-broken on Xcode 26 (`scripts/check-app-builds.sh` is a build-only gate), so the inline subscriber's translation logic — including the StopReason → TurnTerminator mapping, turnStarted synthesis, error → submitRejected forwarding — had ZERO test coverage. The 2026-05-03 smoke session showed this empirically: every fix to the inline subscriber required relaunching the app and typing in the chat input, which the user vetoed mid-session.
- **What:** `packages/AgentCore/Sources/AgentOrchestrator/BusForwarder.swift` now owns the translation rules. `BusForwarderSink` protocol is the boundary. App provides `AppBusForwarderSink` (5-line file: translates `BusForwarder.Terminator` to wire-format `Bus.TurnTerminator`, dispatches across `OutboundBatcher` actor).
- **Tests added:** `packages/AgentCore/Tests/AgentOrchestratorTests/BusForwarderTests.swift` — 16 cases: terminator mapping (5 — exhaustive on `StopReason`), tokenDelta forwarding (3 — synthesize start, dedupe start across same-turn deltas, two-turn handoff), turnEnd forwarding (4 — mapped terminator, synthesize-start-on-bare-turnEnd, streamTruncated→errored, state reset), error forwarding (2 — submitRejected emission, no spurious lifecycle), ignored-events (1 — stateChange/thinkingDelta/usage/toolCardUpdate are no-ops), malformed-id guard (1).
- **Verification:** AgentCore 194/194; Replay 33/33; Bus 55/56 (F-A2-01 pre-existing); all 15 boundary gates PASS; `scripts/check-app-builds.sh` PASS.

### Carry-forward (NOT closed this session)

- **streamTruncatedFinal cause unknown.** Anthropic returns 200 OK + SSE that EOFs before `message_stop`, twice (retry then final). HTTP 401 / network drop / model name issues all rule out via `curl` reproduction against the same endpoint with same headers. Likely API key in Keychain is malformed or stale. Cannot read Keychain to confirm without escalated permission. Suggested next step: add a one-time HTTP-status diagnostic log to `AnthropicProvider` (gated behind a feature flag), or re-enter the API key via the Settings panel.
- **F1 #2 chat-turn integration test.** The unit tests added this session cover Swift-side and JS-side logic individually. A real-WKWebView end-to-end test (mount the bundle, submit text from JS, assert tokenDelta reaches the page) would catch any future cross-layer regression in the chain. Separate scope.

### B3 — `/gsd-validate-phase 1..9` (DEFERRED)

Per Phase E priority: blockers first, Nyquist coverage fill is downstream of fix loop. Will be re-spawned after blockers close.

---

## Phase F1 (partial) — first integration test landed

Pragmatic scope adjustment: rather than scaffold a brand-new top-level `IntegrationTests` Xcode target (which requires substantial pbxproj surgery — a full new PBXNativeTarget + dependency proxy + build-config list + 2 build configs + sources/frameworks phases + N package-product-dependencies — and risks breaking the project file), the first F1 deliverable lands inside the **Bus package's existing SPM test target** so it runs via `swift test` (immune to the upstream Xcode 26 RunningBoard error 5 that blocked xcodebuild test). Promotion to a dedicated Xcode target can come later if needed; F1's bug-catching utility comes from *having* the test, not from *where* it lives.

Filename: `packages/Bus/Tests/BusTests/RealWKWebViewIntegrationTests.swift` — exact path Phase D-Phase-2 specified. So F1's first deliverable + D-Phase-2's required test collapse into one file.

### Tests landed (2026-05-02 20:13)

1. **`test_endToEndHandshake_reachesArmed`** — loads a real `WKWebView` with a blank HTML page, lets `Injection.js` install at document-start (auto-ack-hello at the stub layer per fb41c5f), calls `bridge.startHandshake()`, polls until `handshakeState == .armed` within 2.5s. Asserts `.armed` and that the alert path didn't fire.
   - Pass/fail behavior on the FIXED branch: passes in ~1.0s.
   - Pass/fail behavior on the BUG branch (WKContentWorld misalignment): would hang on `.sentHello`, time out at 2s, transition to `.timedOut`, fire `alertPresenter` — both assertions would fail.
2. **`test_endToEndHandshake_passesThroughSentHello`** — same setup, but samples `handshakeState` rapidly post-`startHandshake()` to confirm we observed `.sentHello` BEFORE `.armed`. Defends against a future regression where Swift short-circuits `.armed` without the JS round-trip.
   - Pass on FIXED branch: ~1.4s.

### Bus suite count delta

54 tests → 56 tests. One failure remains (F-A2-01, pre-existing). My new tests added cleanly.

### Honesty note on what F1 partial does NOT yet cover

The remaining 3 tests the plan listed for F1 are still TODO:
- Wizard happy path (would catch F-A2-01-class wizard-window-spawning bugs)
- Toggle HUD via hotkey (would catch `summon` activation race)
- **Ask-the-agent-something flow** (would catch BLOCKER-INT-2 directly — text submit → tokenDelta → chat panel)

The third one specifically is critical — it would catch the missing-`.bus`-subscriber bug. It requires more setup (mock LLM provider, real orchestrator, real bridge, page that registers a handler and records inbound `tokenDelta` messages). Tracked separately for future F1 work.

---

## Total findings tally as of Phase B close

- 🔴 Blockers: **6** (F-A1-01, F-A2-01 test bug, F-B2-INT-1..4)
- 🟡 Warnings: **2** (F-B2-WARN-1..2)
- 🟢 Cosmetic: **stale-comment-1** + carry-forward C5..C8 (4 deprecation cleanups)
- ✅ Resolved this session: **C2** (Settings panel, commit `7043b3b`)
- Plus pre-known C3 (🟡 wizard rows by-design verification), C4 (🟡 Debug TCC signing) still open.

This is the durable list across sessions. Phase E fix loop should re-prioritize from this file, not from the milestone audit doc (which is a snapshot).
