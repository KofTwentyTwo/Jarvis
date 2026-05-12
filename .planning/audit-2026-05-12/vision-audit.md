# Vision Subsystem — Audit (2026-05-12)

**Audit head:** `a5999e2` (develop). **Prior baseline:** `.planning/audit-2026-05-03/vision-audit.md` (Grade F).
**Calibration bug pattern this pass:** silent integration-boundary failures masked by probes returning ok.

## TL;DR — Grade: **B-**

The big "wired but dead" claims from 2026-05-03 are all closed (Track C-1..C-6). End-to-end on real hardware the camera produces multi-KB JPEGs (`>1000 bytes`, valid SOI), `frameStream` fan-out yields real `CMSampleBuffer` samples within 2 s, the HUD `CameraButton` is rendered and posts `frameAttachRequested`, the chat-submit handlers consume the pending frame, and the assistant-turn-complete release subscriber is wired. The remaining defects are subtler:

1. **HIGH — `t2AvailableForThisTurn` lies to the router.** `AgentOrchestrator.runTurn` (line 321) sets `t2AvailableForThisTurn = (decision.tier != .t3Cloud)` — i.e. `true` for every local route. The router then escalates low-confidence T1 responses to T2, where T2 is `MissingT2Provider` and throws `t2ProviderUnavailable`. The whole vision turn dies with a provider error instead of staying on T1. Calibration shape: the comment at line 317-320 explicitly says "evaluatePostResponse correctly stays-on-T1 when t2Available == false" — but production passes `true`. No AgentCore test exercises image+escalation against the production wiring; the Vision-package router tests pass `t2Available: false` explicitly, so the regression is invisible.
2. **MEDIUM — pendingFrame leaks on `.rejected` submit.** `FrameAttachController.confirmSend(...)` returns an `ImageBlock` but does NOT clear `pendingFrame`. Per design, the slot is released by `onAssistantTurnComplete()` driven by the broadcaster's `.turnEnd` watcher. If `AgentOrchestrator.submit(...)` returns `.rejected`, no `.turnEnd` fires, no release runs, and the JPEG bytes sit in actor memory until the next `requestAttach` overwrites the slot. Privacy regression for D-15 byte-release invariant.
3. **MEDIUM — Mid-session TCC revocation not robustly detected.** `CameraCapture.startWatchers()` only observes `AVCaptureSessionRuntimeError`. macOS Sequoia/Tahoe weekly TCC reprompt + Settings-side revocation can surface as a session interruption (`AVCaptureSessionWasInterrupted`) without firing a runtime error. There is no periodic `AVCaptureDevice.authorizationStatus(for: .video)` re-check, no `AVCaptureSessionWasInterrupted` observer, and no `becameAuthorized()` callsite from AppDelegate. The `cameraRevoked` banner watcher is alive but the producing signal may never reach it.

Verified healthy: real-hardware JPEG capture, frameStream fan-out, presence monitor face-detection pipeline, HUD camera button JS wiring, T2-explicit-error provider, VISION-03 isolation boundary, 72/72 SPM tests (incl. real-hardware suite when JARVIS_REAL_CAMERA=1).

---

## Findings (severity-ordered)

### F-V1 — HIGH — Orchestrator passes `t2Available: true` when only `MissingT2Provider` is wired

**Locations:**
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:321` — `t2AvailableForThisTurn = (decision.tier != .t3Cloud)`
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:670-689` — escalation branch in `runTurnLoop`
- `App/AppDelegate.swift:2319` — `t2Provider: MissingT2Provider()`
- `packages/Vision/Sources/Vision/MissingT2Provider.swift:36,50` — `continuation.finish(throwing: VisionError.t2ProviderUnavailable)`

**Shape:** Calibration-bug pattern — probe (the router heuristic + tests) returns ok, but reality (production provider wiring) is broken. Two layers of test coverage *both* miss it because:
- `VisionRouterEscalationTests` passes `t2Available: false` for the unavailable case and `t2Available: true` only against a stub `t2Provider` (`MockProvider`/inline).
- `AgentOrchestrator` has zero tests that combine `input.images.nonEmpty` + a low-confidence T1 response + `MissingT2Provider` wired as t2.

**Repro path:** Camera frame attached → T1 (`OllamaProvider` qwen2.5-coder over the local Ollama) returns "I'm not sure" or any response under 24 chars / containing one of the substrings in `VisionRouterConfig.default.lowConfidenceSubstrings`. The escalation block at line 668-690 runs because `t2AvailableForThisTurn = true`, swaps `currentProvider` to `MissingT2Provider`, the next `outer` iteration calls `currentProvider.stream(...)`, the stream `finish(throwing:)` propagates to the `catch` at line 820, and the user sees an error event for what should have been a T1 answer.

**Fix:** Either (a) pass the actual provider availability — feature-flag or runtime probe — to `evaluatePostResponse(t2Available:)` so it stays on T1 when `MissingT2Provider` is the t2 wiring, or (b) move the "is T2 a real provider" check into the router itself (`VisionRouter` already holds the providers; `evaluatePostResponse` could ask `t2Provider is MissingT2Provider`). Add a regression test in AgentOrchestratorTests that wires `MissingT2Provider` as t2, feeds a low-confidence T1 mock, and asserts the turn finishes with `.turnEnd(... stopReason: .endTurn)` instead of `.error(...)`.

---

### F-V2 — MEDIUM — `confirmSend` leaves `pendingFrame` populated on rejected submit

**Locations:**
- `packages/Vision/Sources/Vision/FrameAttachController.swift:104-112` — `confirmSend(userText:)` does not call `discardFrame()`
- `App/AppDelegate.swift:1827-1839` — release watcher only fires on `.turnEnd` events with `turnHadImage == true`
- `App/AppDelegate.swift:2160-2164` — `consumePendingFrameIfAny` produces the block but doesn't release the slot

**Shape:** D-15 sole-emission-site invariant is intact (every release goes through `discardFrame()`), but there is no release on the `.rejected` outcome path. Sequence:
1. User clicks Camera → `requestAttach(.hudButton)` → `pendingFrame = frame`.
2. User types and presses Send → `confirmSend(userText:)` returns the `ImageBlock` (slot still populated by design).
3. `AgentOrchestrator.submit(...)` returns `.rejected(reason: .providerUnavailable)` (or `.maxToolCalls`, or any non-running outcome).
4. No `.turnEnd` for this turn ever flows through the broadcaster's frame-attach subscriber → `onAssistantTurnComplete()` never called → JPEG bytes persist in `FrameAttachController.pendingFrame` until the next `requestAttach` overwrites the slot or app shutdown.

`FrameAttachControllerTests.testConfirmSendKeepsPendingUntilAssistantTurnComplete` documents the design (line 110-117), but no test exercises the `.rejected` outcome path. Privacy regression: the byte-release window can grow unbounded.

**Fix:** Either (a) add a `discardFrame()` from `AppDelegate.handleChatSubmit` / `handleChatCancelAndSubmit` when `outcome` is `.rejected` (single new line per handler — call `frameAttachController?.onAssistantTurnComplete()` after `handleTextOutcome` if outcome is rejected), or (b) add a `releaseAfterRejectedSubmit()` method to `FrameAttachController` and route through it explicitly. The second keeps the sole-emission-site invariant readable. Add a test that wires a stub `AgentOrchestrator` returning `.rejected`, confirms `hasPendingFrame == false` afterward.

---

### F-V3 — MEDIUM — Mid-session TCC revocation has no observer that fires on TCC revoke alone

**Locations:**
- `packages/Vision/Sources/Vision/CameraCapture.swift:220-240` — only `AVCaptureSessionRuntimeError` observed
- `App/AppDelegate.swift:2226-2235` — `cameraDegradationTask` reads `.cameraRevoked` from degradation stream; alive but trigger may not fire
- `packages/Vision/Sources/Vision/CameraCapture.swift:94-96` — `becameAuthorized()` is declared but never called from production (zero matches outside its own definition)

**Shape:** macOS Sequoia and 26 Tahoe re-prompt for Camera/Microphone TCC on a rolling basis. When the user revokes via System Settings without quitting Jarvis, the AVCaptureSession typically posts `AVCaptureSessionWasInterruptedNotification` (with `AVCaptureSessionInterruptionReasonKey == .videoDeviceNotAvailableInBackground` or `.videoDeviceNotAvailableWithMultipleForegroundApps`). It does NOT reliably post `AVCaptureSessionRuntimeError`. The current observer set therefore misses TCC-revoke as a degradation source. `cameraDegradationTask` will sit waiting for a yield that never comes.

Compounding factor: the install-time camera-status check at `AppDelegate.swift:2244-2256` runs once at boot; `becameAuthorized()` is declared in `CameraCapture` for the post-grant re-open path but has zero non-doc callsites in the tree (`grep -rn 'becameAuthorized' --include='*.swift'` outside its own declaration returns 0). After first-launch denial + later Settings grant, the camera session never reopens.

**Fix:** (a) Add an `AVCaptureSessionWasInterrupted` observer in `startWatchers()` and yield `.midSessionRevoked` when the interruption reason indicates device-unavailable or TCC-revoked. (b) Wire a periodic (e.g. on app foreground) `AVCaptureDevice.authorizationStatus(for: .video)` re-check in AppDelegate that triggers `becameAuthorized()` when the status flips `.notDetermined → .authorized`. (c) Add a unit test that injects a synthetic interruption notification and asserts the degradation continuation yields `.midSessionRevoked`.

---

### F-V4 — LOW — Continuation race possible when `frameStream(forPresence:)` is called before `open()`

**Locations:**
- `packages/Vision/Sources/Vision/CameraCapture.swift:153-184` — `frameStream` hops into actor, finds `videoSampleDelegate == nil`, calls `cont.finish()`.

**Shape:** Not a current bug (AppDelegate always calls `open()` before `frameStream(forPresence:)`), but the order is structural: any future re-arrangement that subscribes before opening will silently produce a finished stream and PresenceMonitor will exit its feed loop forever. The `attachFrameContinuation` path that calls `cont.finish()` when the delegate is absent has no signal back to the caller — PresenceMonitor cannot distinguish "stream finished naturally" from "stream finished because session not yet built."

**Fix:** Make this contract enforceable — either (a) hold pending continuations in a separate list inside `CameraCapture` and flush them onto the delegate when `buildSession()` completes, or (b) throw from `frameStream(forPresence:)` when `session == nil` (changes the API from `AsyncStream` to `throws -> AsyncStream`). Minimum: add a structural test that fails if `frameStream(forPresence:)` is called before `open()` and silently returns a finished stream (the existing `testFrameStreamFinishesImmediatelyWhenNotOpen` documents this as desired behavior — flip it to a stricter contract).

---

### F-V5 — LOW — `t2AvailableForThisTurn` comment is now wrong

**Location:** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:317-321`

```
// T2 is available iff we routed local — D-04 ships with
// t2Provider == t1Provider, but evaluatePostResponse correctly
// stays-on-T1 when t2Available == false, so passing the actual
// tier here keeps the contract honest.
t2AvailableForThisTurn = (decision.tier != .t3Cloud)
```

The "D-04 ships with t2Provider == t1Provider" premise was the pre-Track-C-4 wiring. After Track-C-4, t2 is `MissingT2Provider`. The comment now misleads any reader into thinking the silent T1-as-T2 fallback is the live behavior, hiding F-V1. Fix as part of F-V1.

---

## Verified healthy

- **CameraCapture real-hardware JPEG** — `JARVIS_REAL_CAMERA=1 swift test --filter CameraCaptureRealHardwareTests` (run during audit, exit 0). Real frames are >1000 B with valid SOI marker (`Data([0xFF, 0xD8])`) at 1280×720; `frameStream(forPresence:)` yields a `.sampleBuffer(...)` within 2 s of session start.
- **`PhotoCaptureProxy` retain cycle** — proxy retains self in init, breaks cycle on first delegate callback (`packages/Vision/Sources/Vision/CameraCapture.swift:270-313`). Verified by structural test `testCaptureFrameSourceDoesNotEmbedHardcodedJPEG` and by real-hardware test exit 0.
- **`VideoSampleDelegate` fan-out** — UUID-keyed continuation map, NSLock-guarded snapshot under `captureOutput(_:didOutput:from:)`, `finishAllStreams()` snapshot-then-clear pattern is race-free. Verified by `CameraCaptureFrameStreamTests` (testFrameStreamYieldsInjectedSamplesAfterOpen + testShutdownFinishesOutstandingStreams) and by `CameraCaptureRealHardwareTests`.
- **PresenceMonitor pipeline** — face-detection request runs against real `CMSampleBuffer` from frameStream; the debounced state machine fires `.transition(to:at:debounced:)` to `PresenceSignalBus`. Verified by `PresenceMonitorDebounceTests` (synthetic) and by code inspection of `runVision(on:now:)` (lines 176-186) — Vision-framework `VNDetectFaceRectanglesRequest` is real, run synchronously, results checked, observation propagated via `applyObservation(...)`.
- **HUD camera button wiring (B-03 carry-forward — not re-flagged)** — `CameraButton.tsx` posts `BusInbound.frameAttachRequested`; `ChatInput.tsx:71` renders it; `AppDelegate.swift:2520-2522` routes the inbound to `frameAttachController.requestAttach(reason: .hudButton)`. Wiring intact. The missing piece is user-visible UI confirm/preview state, which is the M-5 carry-forward.
- **`FrameAttachController.confirmSend` non-test callers** — `AppDelegate.consumePendingFrameIfAny` (line 2160-2164) is the production caller, reached from both `handleChatSubmit` (line 2121) and `handleChatCancelAndSubmit` (line 2146). Verified by `FrameAttachConfirmSendWiringTests` greps.
- **Frame-attach release subscriber** — `AppDelegate.swift:1827-1839` subscribes at `.frameAttach` priority and calls `frameAttachController.onAssistantTurnComplete()` when `agentOrchestrator.turnHadImage(turnId)` returns true. Priority isolation per `OrchestratorEventBroadcaster` protection matrix.
- **`MissingT2Provider` explicit-error path** — `stream(...)` overloads both call `continuation.finish(throwing: VisionError.t2ProviderUnavailable)`. Verified by `MissingT2ProviderTests`. Surfaces as a debuggable error rather than silent T1-rerun. (F-V1 above is about the orchestrator side mis-gating the call — not about this provider's correctness.)
- **TCC denied banner watcher** — `cameraDegradationTask` (AppDelegate.swift:2226-2235) is a long-lived `Task { @MainActor [weak self] in for await reason in degStream { ... } }`. Reads `.cameraDenied` and `.midSessionRevoked`; routes to `bannerCoordinator.enqueue(...)`. Task is created and never explicitly cancelled before `applicationWillTerminate`. Verified by code inspection — the producer-side signal sources (CameraCapture.open() denial path; AVCaptureSessionRuntimeError) are documented above; F-V3 covers the missing trigger paths.
- **VISION-03 isolation invariant** — `bash scripts/check-presence-vision-isolation.sh && bash scripts/check-vision-isolation.sh` — both exit 0 at HEAD. `packages/Vision/Package.swift` does not declare a dep on `Voice` or `AgentOrchestrator`; no Vision source imports them.
- **Vision SPM test suite** — `swift test --package-path packages/Vision` — 72 tests, 0 failures, 2 skipped (real-hardware suite when `JARVIS_REAL_CAMERA` unset). Real-hardware suite passes when env-gate is set.

---

## Open questions

1. **Should `t2AvailableForThisTurn` be derived in the router instead of the orchestrator?** The router holds the providers, knows `t2Provider is MissingT2Provider`, and can fold that into `evaluatePostResponse`. Moving it eliminates the calibration-bug class entirely — no caller can pass the wrong flag because there is no flag. Cost: router gains a tiny bit of awareness about provider identity (currently it's pure dispatch).
2. **What's the user-facing confirmation UX for the HUD camera button?** Today the click silently arms the slot for 2 s; if the user doesn't type+send in that window, the frame is discarded with no UI feedback. The M-5 carry-forward presumably scopes this; flagging here so the audit→backlog handoff has the dead-air symptom recorded alongside the wiring-is-intact verification.
3. **`AVCaptureSessionWasInterrupted` vs runtime error** — empirical confirmation needed of which notification(s) fire when (a) user revokes Camera TCC via Settings while app is foreground, (b) user toggles Camera off then on, (c) USB camera unplug/replug. The fix for F-V3 should be guided by which signals are reliable in macOS 26 Tahoe specifically, not by what Apple's docs promised in macOS 12.
4. **Why is `becameAuthorized()` declared with no production callsite?** Either it's leftover scaffolding for a re-grant flow that was never wired (delete it and document), or the re-grant flow IS desired and the wiring just never landed (add it and reference F-V3). Picking either resolves a small chunk of dead-code.

---

## Summary (top-3, ~150 words)

The "scaffold simulating a feature" verdict from 2026-05-03 is closed: Track C-1..C-6 delivered real AVCapturePhotoOutput delegate capture (real-hardware test passes with >1000-byte SOI-valid JPEGs), real `VideoSampleDelegate` fan-out feeding the presence pipeline, a wired `CameraButton.tsx`, a non-orphaned `confirmSend`, and an explicit `MissingT2Provider` instead of the silent T1-as-T2 fallback. What remains is subtler. **(1) HIGH:** `AgentOrchestrator` passes `t2Available: true` on every local-tier vision turn, so a low-confidence T1 answer escalates straight into `MissingT2Provider` and the turn errors out — a calibration-bug pattern (probe says ok, production wiring breaks). **(2) MED:** `confirmSend` doesn't release `pendingFrame` on `.rejected` submit, leaving JPEG bytes resident past the D-15 release window. **(3) MED:** mid-session TCC revoke isn't observed reliably — only `AVCaptureSessionRuntimeError`, not `AVCaptureSessionWasInterrupted`, and no foreground re-check.
