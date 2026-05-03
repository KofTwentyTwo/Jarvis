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

#### F-B2-INT-2 🔴 tokenDelta / turnStarted / turnEnded never emitted to webview

- **Where:** `packages/Bus/Sources/Bus/OutboundBatcher.swift:44` (the outbound emitter exists but no caller); `App/AppDelegate.swift:828-1015` (broadcaster has 5 subscribers but no `.bus` subscriber).
- **What:** Cross-tree grep confirms zero call sites of `OutboundBatcher.postToken` outside its declaration. `BusOutbound.{tokenDelta,turnStarted,turnEnded}` cases have NO Swift production emit sites — only their own decode round-trips. The orchestrator emits `OrchestratorEvent.tokenDelta` correctly (`AgentOrchestrator.swift:382`); five subscribers consume it (memory, transcript, devOverlay, frameAttach, voice); none forward to the webview.
- **Affected REQ-IDs:** TEXT-01, TEXT-02, AGENT-04, AGENT-10, HUD-04..06.
- **Severity rationale:** 🔴 — tokens never reach the chat panel; even a working LLM turn produces nothing user-visible.

#### F-B2-INT-3 🔴 HUD has no chat input UI; `chatSubmit` has no producer

- **Where:** `webview/packages/hud/src/chat/ChatPanel.tsx` (read-only renderer); `webview/packages/hud/src/App.tsx` (no input form mounted).
- **What:** The Swift inbound side IS wired (`AppDelegate.swift:1404-1407` → `handleChatSubmit` → `orchestrator.submit(.text(...))`), but the JS side has no producer of any inbound bus message. Cross-tree grep across `webview/packages/hud/src/`: zero references to `chatSubmit` / `chatCancelAndSubmit` / `frameAttachRequested` as PRODUCERS.
- **Affected REQ-IDs:** TEXT-01, HUD-07, brief week-one #7 ("Text input fallback").
- **Severity rationale:** 🔴 — without an input UI, the user cannot start a turn from the HUD. Voice input bypasses this but voice out is muted by WARN-INT-1.

#### F-B2-INT-4 🔴 (= C1) CameraCapture 1×1 black JPEG

(Same as C1 — kept here for cross-reference. See pre-known table above.)

#### F-B2-WARN-1 🟡 TTS engine `nil`; voice loop is mute

- **Where:** `App/AppDelegate.swift:676-678` constructs `VoiceTTSAdapter(engine: nil)`. `App/Voice/VoiceTTSAdapter.swift:44-46` no-ops `synthesize` when `engine == nil`. No production code constructs a `TTSEngineActor`.
- **Severity rationale:** 🟡 — wiring is correct; production engine instantiation is the gap. CLAUDE.md acknowledges TTS production wiring is week-one scope; this finding documents that the scope is unmet.

#### F-B2-WARN-2 🟡 `sessionHistory` outbound declared but never emitted

- **Where:** `packages/Bus/Sources/Bus/BusOutbound.swift:25` declares the case; webview decoder ready; no production caller.
- **Severity rationale:** 🟡 — pairs with the chat-input fix; once chat works, history hydration on `webviewReady` is the next missing wire.

### B3 — `/gsd-validate-phase 1..9` (DEFERRED)

Per Phase E priority: blockers first, Nyquist coverage fill is downstream of fix loop. Will be re-spawned after blockers close.

---

## Total findings tally as of Phase B close

- 🔴 Blockers: **6** (F-A1-01, F-A2-01 test bug, F-B2-INT-1..4)
- 🟡 Warnings: **2** (F-B2-WARN-1..2)
- 🟢 Cosmetic: **stale-comment-1** + carry-forward C5..C8 (4 deprecation cleanups)
- ✅ Resolved this session: **C2** (Settings panel, commit `7043b3b`)
- Plus pre-known C3 (🟡 wizard rows by-design verification), C4 (🟡 Debug TCC signing) still open.

This is the durable list across sessions. Phase E fix loop should re-prioritize from this file, not from the milestone audit doc (which is a snapshot).
