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

### F-A1-01 🟡 HUD rings not animating at STANDBY

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

## Phase B audit outputs (populated when audit runs)

_Empty — `/gsd-audit-uat`, `/gsd-audit-milestone`, `/gsd-validate-phase 1..9` will fill this section._
