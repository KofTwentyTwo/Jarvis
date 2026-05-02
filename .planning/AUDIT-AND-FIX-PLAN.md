---
title: v0.12.0 Audit-and-Fix Plan
status: in-progress
created: 2026-05-02
owner: project
---

# v0.12.0 Audit-and-Fix Plan

## Why this exists

GSD says v0.12.0 is **9/9 phases complete, 43/43 plans complete, 100%**. In
practice, a single working session (2026-05-02) found:

- **HUD stuck on `BOOTING`** because `WKContentWorld` isolation prevented
  the JS bundle's handler from reaching the stub Swift was talking to.
  Phase 2 (Bus) tests bypassed this entirely via the `JSEvaluator` test
  seam.
- **`CameraCapture.captureFrame()` returns a 1×1 black-pixel JPEG**
  (`packages/Vision/Sources/Vision/CameraCapture.swift:106`). Phase 7
  closed with the comment "Replaced by AVCapturePhotoOutput delegate flow
  in 07-05" — never came back.
- **`Show Dev Overlay` menu item was a stub banner** that said "lands in
  Phase 4". Phase 4 closed years ago in milestone-time.
- **`Settings…` menu item disabled** with `// Coming soon` tooltip.
- **`NSMenuItem.target` weakly held a `ClosureTarget`** that deallocated
  immediately, so all closure-driven menu items silently no-op'd.
- **Wizard hotkey recorder invisible + unclickable** (no `draw(_:)`,
  no `mouseDown(_:)` to focus).
- **Wizard hotkey not persisted** across quit/reopen (in-memory only).
- **Wizard re-asked for already-granted Input Monitoring** (probed flag
  was session-scoped, didn't query actual TCC state via `IOHIDCheckAccess`).
- **Multiple wizard windows** spawned on each `Setup…` click.
- **Camera entitlement missing** from Debug + Release entitlements.
- **`Injection.js protocolVersion` literal stale at 2.0.0** since first
  protocol bump (full bundle skip-replaces stub, so the literal IS what's
  reported).
- **`Injection.js` single-slot `_pendingHello`** clobbered burst messages.

All of these passed GSD verification. The pattern: tests verified the
**code at the unit level**, never **the assembled app at the integration
level**. We need both a real audit and a layer of integration tests.

## Operating principles

1. **Run audit FIRST**, fix second. Don't whack-a-mole more bugs.
2. **Honest finding triage** — 🔴 blocking, 🟡 degraded, 🟢 cosmetic.
3. **Fix only after tests catch it**. Add a failing test → make it pass →
   commit. (TDD where it adds signal; pragmatic when test cost > value.)
4. **Multi-session work**. Don't try to land it all in one shot. Each
   session: pick one finding cluster, complete it, commit, hand off.
5. **GSD verifier is allowed to evolve**. If we keep finding bugs that
   verifier missed, the verifier itself needs upgrading — capture lessons
   in `/gsd-extract-learnings`.

---

## Phase A — Pre-audit cleanup (small, in-flight)

These are mid-edit from session 2026-05-02 and need landing before the
audit so it doesn't show false-positive noise.

```sh
# A1. Confirm HUD is alive on develop. Should show STANDBY/IDLE not BOOTING.
scripts/dev-reset.sh --yes
scripts/check-app-builds.sh && open build/Build/Products/Debug/Jarvis.app
# Visual: HUD chrome shows "STATE: STANDBY" + animated rings + "AGENT IDLE".
```

If HUD shows BOOTING, the Phase-9 bus fix didn't take — stop here, debug,
do not advance.

```sh
# A2. Strip BootDiag instrumentation (single revert commit).
#     Targets: App/Diagnostics/BootDiag.swift,
#              packages/Bus/Sources/Bus/BusBootDiag.swift,
#              call sites in AppDelegate.swift, WebviewBridge.swift,
#              HudStateCoordinator.swift, snapshotJSBus helper.
#     Keep the WebviewBridge content-world fix and Injection.js queue+ack
#     fixes — those are the actual production fixes.

# A3. Finish the real Settings panel (App/Settings/SettingsView.swift exists).
#     Add SettingsWindow.swift + AppDelegate wiring + replace JarvisApp.swift
#     "coming soon" stub. Re-route menu Settings… from wizard to the new panel.

# A4. Build + run /gsd-progress to confirm green starting state.
scripts/check-app-builds.sh
```

Commit after each. Expect 3 commits in Phase A.

---

## Phase B — Real audit

```sh
# B1. Cross-phase audit of all outstanding UAT items.
/gsd-audit-uat

# B2. Milestone audit — original-intent vs reality, every requirement.
/gsd-audit-milestone

# B3. Per-phase Nyquist validation — finds requirements with implementation
#     but no test proving correctness. Run for every phase (1-9).
for n in 1 2 3 4 5 6 7 8 9; do
  /gsd-validate-phase $n
done
```

**Expected outputs:**
- `AUDIT-UAT.md` — list of UAT items not done
- `MILESTONE-AUDIT.md` — divergence per requirement
- `.planning/phases/0N-*/0N-NYQUIST-VALIDATION.md` per phase

**Triage rule:** open the audit reports, classify each finding:
- 🔴 **Blocks a v0.12.0 promise** (e.g. CameraCapture stub blocking
  vision dispatch — already known)
- 🟡 **Degraded but functional** (e.g. deprecation warnings, hotkey
  doesn't bring HUD forward when occluded — already fixed but unverified)
- 🟢 **Cosmetic** (e.g. comment cleanup, doc updates)

Save the triaged list to `.planning/AUDIT-FINDINGS.md` so it survives
across sessions.

---

## Phase C — Pre-known findings to fold in

The session already found these. Keep them in scope when triaging
audit output so they don't fall off:

| ID | Where | Fix scope |
|---|---|---|
| **C1** 🔴 | `packages/Vision/Sources/Vision/CameraCapture.swift:106` — 1×1 JPEG stub | Replace `onePixelJPEG()` with real `AVCapturePhotoOutput` delegate flow. ~50–80 LOC. Add an integration test that captures a real frame in a unit-test environment (use `AVCaptureSession` with no hardware, verify the delegate plumbing fires) plus a hardware-only `XCTSkipIf` test for actual frames. |
| **C2** 🟡 | `App/JarvisApp.swift:13` — SwiftUI Settings scene has `Text("Settings — coming soon.")` | Resolved by Phase A3 (real Settings panel + JarvisApp.swift fix). |
| **C3** 🟡 | Phase 7 wizard rows for Mic/Camera/Automation are explainer-only | Decision: per D-08 this is by design (Phase 1 prompts only what Phase 1 needs). Verify nothing in Phase 6/7/9 accidentally relies on these prompts having fired during onboarding. If yes → either prompt at activation time (preferred) or move to wizard. |
| **C4** 🟡 | Ad-hoc Debug signing → unstable TCC identity | Switch Debug `CODE_SIGN_IDENTITY` to "Apple Development" (Xcode auto-managed) so System Settings reliably lists the bundle. Update `scripts/codesign.sh` accordingly. Test: `tccutil reset All com.koftwentytwo.jarvis && open build/.../Jarvis.app && grep "com.koftwentytwo.jarvis" /Library/Application\ Support/com.apple.TCC/TCC.db`. |
| **C5** 🟢 | `App/AppDelegate.swift:1101` — superfluous `await` | Remove `await` keyword. |
| **C6** 🟢 | `packages/Logging/Sources/JarvisLogging/{File,OS}LogHandler.swift` — deprecated swift-log default impl | Override `log(event:)` directly per swift-log 1.6+ API. |
| **C7** 🟢 | `App/MenuBar/MenuBarIconController.swift:110` — `popUpMenu` deprecated since 10.14 | Use `statusItem.menu = menu` property instead. |
| **C8** 🟢 | `packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift:80` — `String(cString:)` deprecated | Use `String(decoding:as:)` per the warning's own advice. |

---

## Phase D — Per-phase test-coverage fill

After audit identifies specific gaps, run for each phase that needs it:

```sh
/gsd-add-tests <N>
```

**Specifically required regardless of audit output** (already known):

### D-Phase-2 (Bus) — needs an integration test

Current: tests use `JSEvaluator` test seam, never run a real WKWebView.
That's why the WKContentWorld bug got through.

Required test (write this regardless of what the verifier says):

```swift
// packages/Bus/Tests/BusTests/RealWKWebViewIntegrationTests.swift
@MainActor
final class RealWKWebViewIntegrationTests: XCTestCase {
  /// Loads a real WKWebView, attaches a real WebviewBridge, loads a tiny
  /// HTML page that registers a handler via window.jarvisBus.onOutbound,
  /// fires startHandshake, asserts handshakeState reaches .armed within 2s.
  /// THIS is the test that would have caught the WKContentWorld + always-
  /// ack-hello bugs before they hit the user.
  func test_endToEndHandshake_withPageBundle() async throws { ... }

  /// Same but verifies a hudState message dispatched after armed reaches
  /// the bundle handler (window.jarvisBus._handler called).
  func test_postHandshake_hudStateReachesHandler() async throws { ... }
}
```

### D-Phase-7 (Memory + Vision) — frame capture integration

Currently `CameraCapture.captureFrame()` returns a 1×1 stub. The fix
(C1) needs a paired test:

```swift
// packages/Vision/Tests/VisionTests/CameraCaptureFrameTests.swift
final class CameraCaptureFrameTests: XCTestCase {
  /// Mocks AVCaptureSession + AVCapturePhotoOutput, verifies that
  /// captureFrame() routes through the photo-output delegate and returns
  /// a CapturedFrame whose jpegData decodes to a non-1×1 image.
  func test_captureFrame_returnsRealPhotoOutput() async throws { ... }

  /// Hardware-required: skip unless XCTRunsOnRealDevice. On a real Mac
  /// with camera, opens the capture session and grabs an actual frame.
  func test_captureFrame_onRealHardware() async throws { try XCTSkipIf(...) ; ... }
}
```

### D-Phase-9 (Orchestrator wiring) — end-to-end agent loop

Currently each plan tested its own wave in isolation. No test exists
that exercises agent-loop + voice + vision + memory together. Add:

```swift
// packages/AgentCore/Tests/AgentOrchestratorTests/EndToEndTurnTests.swift
final class EndToEndTurnTests: XCTestCase {
  /// Full turn: text input -> orchestrator.submit -> mock LLM provider
  /// returns scripted response -> orchestrator emits tokenDelta + turnEnded
  /// -> memory extractor enqueued -> vision dispatch hook fired -> bus
  /// outbound dispatched. Single test asserting the whole graph runs.
  func test_fullTurn_textInput_drivesAllSubsystems() async throws { ... }
}
```

### D-Phase-1..8 — let `/gsd-validate-phase` decide

For phases 1, 3, 4, 5, 6, 8 the audit's Nyquist report is the source of
truth. Add tests for any UNCOVERED requirement.

---

## Phase E — Per-finding fix loop

For each 🔴 finding, in priority order:

```sh
# 1. Write the failing test.
$EDITOR packages/<pkg>/Tests/.../FixForXXTests.swift

# 2. Run it — confirm it fails for the right reason.
cd packages/<pkg> && swift test --filter FixForXX

# 3. Fix the production code.
$EDITOR packages/<pkg>/Sources/.../File.swift

# 4. Run the test — confirm it now passes.
cd packages/<pkg> && swift test --filter FixForXX

# 5. Run the full package suite — confirm no regressions.
cd packages/<pkg> && swift test

# 6. Run check-app-builds — confirm App target still compiles.
scripts/check-app-builds.sh

# 7. Commit atomically.
gsd-sdk query commit "fix(<pkg>): <one-line summary>

<body explaining root cause + the failing test that now passes>" \
  --files <changed files>
```

Repeat for every 🔴 finding before touching any 🟡 findings.

---

## Phase F — Hardening pass

After 🔴/🟡 findings cleared, harden the verification infrastructure
so v0.13.0 doesn't fall into the same pattern.

### F1. Add an integration test target

Currently each package has its own `<Pkg>Tests` target. Add a
top-level `IntegrationTests` target that links the App + every package
and runs end-to-end smoke tests through the real (or near-real) plumbing.

Tests to start with:
- HUD handshake end-to-end (covers WKContentWorld bug class).
- Wizard happy path (covers the wizard-window-spawning class).
- Toggle HUD via hotkey (covers `summon` activation race).
- Ask-the-agent-something flow (covers tokenDelta + turnEnded routing).

### F2. Add a "stubs leftover" linter

```bash
# scripts/check-no-leftover-stubs.sh — runs in pre-commit
# Greps for: "// Stub:", "// Replaced by .* in 0[0-9]-0[0-9]", "TODO\(Phase",
# "lands in Phase", "coming soon", "no-op stub until".
# Each hit must be accompanied by either a frontmatter `accepted_stub: true`
# in the matching plan, or it fails the build.
```

This catches the "comment promised it'd be replaced and never was" class.

### F3. Update gsd-verifier to look for stubs

The current verifier checks "did the plan deliver". Extend it to also
check for stub patterns inside the delivered files. Findings should
require an explicit `verifier.allow_stub` annotation in the plan
frontmatter.

### F4. Live UAT walk-through

```sh
/gsd-verify-work 9   # end-to-end conversational UAT for the whole stack
```

This is supposed to catch "the menu item exists but does nothing" and
"the wizard advances but the HUD never lights up" classes by walking a
human through each promised behavior.

---

## Phase G — Close the milestone

After all 🔴 + 🟡 findings cleared and Phase F hardening landed:

```sh
# G1. Capture lessons.
for n in 1 2 3 4 5 6 7 8 9; do
  /gsd-extract-learnings $n
done

# G2. Final progress check.
/gsd-progress

# G3. Verify nothing's outstanding.
/gsd-audit-uat   # should report 0 outstanding

# G4. Archive milestone, prepare v0.13.0.
/gsd-complete-milestone

# G5. Roadmap next milestone.
/gsd-new-milestone
```

---

## Time estimate

- **Phase A** (in-flight): ~1 session, 30–60 min
- **Phase B** (audit): ~1 session, mostly running commands and triaging output. 1–2 hours.
- **Phase C** (known findings): rolled into D + E.
- **Phase D** (test-coverage fill): per-phase `gsd-add-tests` runs are 10–30 min each. Phase 7 + 9 will be the biggest. **3–5 sessions** total.
- **Phase E** (fix loop): one finding cluster per session. Probably **3–8 sessions** depending on audit volume.
- **Phase F** (hardening): ~2 sessions.
- **Phase G** (close): ~1 session.

**Total**: ~10–18 sessions across multiple weeks.

---

## State across sessions

- This file is the durable plan. Each session reads it on start.
- Use `/gsd-pause-work` at end of each session to write a context handoff.
- Use `/gsd-resume-work` at start of each session to pick up where you left off.
- Update `.planning/AUDIT-FINDINGS.md` (created in Phase B) with strikethrough
  on each finding as it's closed.

---

## Hand-off notes (current state, 2026-05-02 evening)

- **HUD reaches `STANDBY`** — bus content-world fix landed and works.
- **Wizard end-to-end works** — API key, Input Monitoring grant, hotkey bind, persistence across reopen.
- **In-flight, NOT yet committed**:
  - `App/Settings/SettingsView.swift` exists but no `SettingsWindow.swift`, no AppDelegate wiring, `JarvisApp.swift` still has "coming soon" stub.
  - `App/Diagnostics/BootDiag.swift` + `packages/Bus/Sources/Bus/BusBootDiag.swift` + the call sites are diagnostic-only and need stripping.
  - `WebviewBridge.send` carries the `messageDescription` + `diagnoseJSReceiveState` helpers — also diagnostic-only.
- **Last known-good commit**: `fix(bus): unify WKContentWorld + always-ack hello at stub level`.
- **First task next session**: Phase A2 + A3 + A4 (strip BootDiag, finish Settings panel, smoke-test green).
