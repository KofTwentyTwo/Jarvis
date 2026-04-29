---
phase: 07-memory-vision
plan: 04
subsystem: vision
tags: [vision, camera, presence, tcc, signal-only, vision-03]
requires:
  - packages/Logging
  - packages/AgentCore
  - App/HUD/HUDBannerCoordinator.swift  # consumed by 07-06; named here for the wiring contract
provides:
  - packages/Vision/Sources/Vision/PresenceSignalBus.swift
  - packages/Vision/Sources/Vision/PresenceEvent.swift
  - packages/Vision/Sources/Vision/PresenceMonitor.swift
  - packages/Vision/Sources/Vision/CameraCapture.swift
  - packages/Vision/Sources/Vision/CapturedFrame.swift
  - packages/Vision/Sources/Vision/DisablePresence.swift
  - packages/Vision/Sources/Vision/VisionError.swift
  - packages/Vision/Sources/Vision/VisionDegradationReason.swift
  - scripts/check-vision-isolation.sh
  - scripts/check-presence-bus-no-tts-orchestrator.sh
affects:
  - project.yml (added Vision package + Jarvis dep, product name JarvisVision)
  - Jarvis.xcodeproj (regenerated)
  - App/Info.plist (NSCameraUsageDescription updated to plan wording)
tech-stack:
  added:
    - Apple Vision framework face detection (VNDetectFaceRectanglesRequest)
    - AVFoundation AVCaptureSession lifecycle inside an actor
  patterns:
    - WakeWordDAG-shaped actor (nonisolated bus + Task.detached feed loop + paused/resume + cancel)
    - AudioGraphOwner-shaped lifecycle (open/shutdown + degradationStream + authStatusProbe test seam)
    - Mid-session NotificationCenter observer captured Sendable-only values for Swift 6 strict concurrency
    - Module renamed to JarvisVision to side-step Apple's Vision-framework name collision
key-files:
  created:
    - packages/Vision/Package.swift
    - packages/Vision/Sources/Vision/CameraCapture.swift
    - packages/Vision/Sources/Vision/CapturedFrame.swift
    - packages/Vision/Sources/Vision/DisablePresence.swift
    - packages/Vision/Sources/Vision/PresenceEvent.swift
    - packages/Vision/Sources/Vision/PresenceMonitor.swift
    - packages/Vision/Sources/Vision/PresenceSignalBus.swift
    - packages/Vision/Sources/Vision/VisionDegradationReason.swift
    - packages/Vision/Sources/Vision/VisionError.swift
    - packages/Vision/Tests/VisionTests/CameraCaptureTCCTests.swift
    - packages/Vision/Tests/VisionTests/DisablePresenceTests.swift
    - packages/Vision/Tests/VisionTests/PackageBoundaryTests.swift
    - packages/Vision/Tests/VisionTests/PresenceMonitorDebounceTests.swift
    - packages/Vision/Tests/VisionTests/PresenceSignalBusTests.swift
    - scripts/check-presence-bus-no-tts-orchestrator.sh
    - scripts/check-vision-isolation.sh
  modified:
    - project.yml (+Vision package + Jarvis dep entry, product JarvisVision)
    - Jarvis.xcodeproj/project.pbxproj (xcodegen regenerate)
    - App/Info.plist (NSCameraUsageDescription text updated)
decisions:
  - Module renamed Vision -> JarvisVision (Apple Vision framework name collision)
  - Wire Vision into project.yml mirroring 07-01's Memory pattern (no root Package.swift)
  - feedObservation honors paused gate identically to consume() (parity with VOICE-12)
  - PresenceFrameSample uses @unchecked Sendable for CMSampleBuffer + CGImage payloads
metrics:
  duration_minutes: 27
  completed_date: "2026-04-29"
  tasks: 3
  commits: 3
  files_created: 16
  files_modified: 3
  tests_added: 14
  tests_passing: 14
  tests_skipped: 0
---

# Phase 7 Plan 04: Vision capture + Presence — Summary

**One-liner:** Stand up the new `packages/Vision` SPM target (module name
`JarvisVision`) with a signal-only presence pipeline — `CameraCapture`
actor for AVCaptureSession + Camera-TCC lifecycle, `PresenceMonitor` actor
with 2 s edge-debounce + 5-min absent secondary threshold,
`PresenceSignalBus` (bare `AsyncStream` with no inbound API), and
`DisablePresence` menu-bar toggle cloned verbatim from `MuteWakeWord` —
plus two build-time grep-gate scripts that enforce VISION-03 at the
textual level (`packages/Vision` may not import Voice or
AgentOrchestrator; `PresenceSignalBus` may not be referenced from those
packages either).

## What Was Built

### Task 1 — Vision SPM scaffold + VISION-03 grep gates + Info.plist (commit `c988970`)

- New `packages/Vision` SPM package, `swift-tools-version:6.0`,
  `.macOS(.v14)` (matches workspace `MACOSX_DEPLOYMENT_TARGET=14.0`),
  strict-concurrency v6. Library product `JarvisVision`.
- Dependencies: `Logging`, `AgentCore`, `swift-log` only — **no Voice,
  no AgentOrchestrator**. This is the SPM-graph half of VISION-03; the
  textual halves are the two scripts below.
- `VisionError` (TCC + capture errors) and `VisionDegradationReason`
  (`cameraDenied`, `midSessionRevoked`) — analogs of Voice's
  `Error` / `DegradationReason`.
- `scripts/check-vision-isolation.sh`: fails the build if any file under
  `packages/Vision/Sources/` contains `import Voice` or
  `import AgentOrchestrator` at module scope.
- `scripts/check-presence-bus-no-tts-orchestrator.sh`: fails the build
  if any non-comment line under `packages/Voice/Sources` or
  `packages/AgentCore/Sources/AgentOrchestrator` references the
  `PresenceSignalBus` symbol. (Comment-only lines are tolerated so
  doc comments about the rule do not trip the gate.)
- Wired Vision into `project.yml` (XcodeGen): a `Vision:` package entry
  beside `Memory:` and a `- package: Vision / product: JarvisVision`
  line under `targets.Jarvis.dependencies`. Regenerated `Jarvis.xcodeproj`
  via `xcodegen generate`.
- `App/Info.plist` `NSCameraUsageDescription` text updated to the plan's
  wording ("Jarvis uses your camera to detect when you are at the
  desk…"); the key already existed from earlier scaffolding.

### Task 2 — PresenceSignalBus + PresenceMonitor + CameraCapture (commit `0238817`)

- `PresenceEvent` (Sendable, Equatable) wraps `.transition(to:at:debounced:)`.
- `Presence` enum: `.present`, `.absent(since:)`, `.absentLongTerm(since:)`,
  `.unknown`. Only the first three are ever published; `.unknown` is the
  pre-first-frame sentinel.
- `PresenceSignalBus` is a bare `AsyncStream<PresenceEvent>` wrapper
  struct with `public let stream` and `internal init(stream:)` — no
  registry, no fan-out, no inbound API. Only `PresenceMonitor`
  constructs the bus.
- `CameraCapture` actor: AVCaptureSession lifecycle owner with
  `nonisolated let degradationStream`, `authStatusProbe` test seam,
  `open()/shutdown()` pair, `becameAuthorized()` entry for D-09's
  first-grant flow, single-frame `captureFrame()` with the
  `VisionError.sessionNotRunning` guard (stub JPEG body until 07-05
  wires `AVCapturePhotoOutput`), `nonisolated frameStream(forPresence:)`
  returning an empty stream until 07-06 wires the delegate.
  - The mid-session `AVCaptureSessionRuntimeError` observer captures
    only Sendable values (the Continuation + a label String) so the
    `@Sendable` notification-block closure crosses the actor boundary
    cleanly under Swift 6 strict concurrency.
- `CapturedFrame` value type for VISION-04 frame-attach (consumed by
  07-05).
- `PresenceMonitor` actor: WakeWordDAG-shaped — actor + nonisolated bus
  + `Task.detached` feed loop + `paused`/`resume`/`cancel`. Edge-
  debounced 2.0 s state machine plus a 5-min absent secondary threshold
  (`armLongTermTimer` arms a detached sleep that hits `evaluateLongTerm`).
  Test seams: `feedObservation`, `evaluateLongTerm`, both honor the
  `paused` gate.
- `PresenceFrameSample` enum (`@unchecked Sendable`) — `CMSampleBuffer`,
  `CGImage`, plus a `.syntheticDetection` test variant. Single-producer
  / single-consumer in this codebase, hence the unchecked Sendable.

### Task 3 — DisablePresence menu-bar toggle (commit `43e7b8a`)

- `DisablePresence` is a verbatim clone of
  `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift` with the
  documented renames: `wakeWord` → `presence`,
  `controller: VoiceController` → `presenceMonitor: PresenceMonitor`,
  defaults key `features.voice.wakeWordMuted` →
  `features.vision.presenceDisabled`, menu title `"Mute wake word"` →
  `"Disable presence"`. `@MainActor final class`, `@objc handleToggle`,
  `toggleForTest()` seam.
- D-12 invariant enforced by `testDisablePresenceDoesNotTouchCameraCapture`:
  the test opens `DisablePresence.swift` from disk, strips comment lines,
  and asserts the substring `CameraCapture` does not appear. Disabling
  presence does NOT disable frame-attach.

## Tests landed (14 total, 0 skipped, 0 failing)

| File | Tests | Status |
|------|-------|--------|
| `PackageBoundaryTests.swift` | 2 | PASS |
| `PresenceSignalBusTests.swift` | 2 | PASS |
| `PresenceMonitorDebounceTests.swift` | 3 | PASS |
| `CameraCaptureTCCTests.swift` | 3 | PASS |
| `DisablePresenceTests.swift` | 4 | PASS |
| **Total** | **14** | **14 PASS** |

`bash scripts/check-vision-isolation.sh` → exit 0.
`bash scripts/check-presence-bus-no-tts-orchestrator.sh` → exit 0.
`swift test --package-path packages/Vision` → 14 PASS, 0 failures.
`bash scripts/check-app-builds.sh` → PASS (App target compiles cleanly
with the new Vision product wired through `project.yml`).

## Must-Haves Truths Verified

- [x] `packages/Vision/Package.swift` declares NO dependency on JarvisTTS
      or JarvisOrchestrator targets — verified by `grep -vE '^[[:space:]]*//'
      packages/Vision/Package.swift | grep -cE '(packages/Voice|AgentOrchestrator)'`
      returning 0.
- [x] `PresenceSignalBus` has zero subscribers in `JarvisTTS` /
      `JarvisOrchestrator` — verified by
      `bash scripts/check-presence-bus-no-tts-orchestrator.sh` → exit 0.
- [x] No `import Voice` and no `import AgentOrchestrator` appears
      anywhere under `packages/Vision/Sources/` — verified by
      `bash scripts/check-vision-isolation.sh` → exit 0.
- [x] After the user first grants Camera TCC,
      `CameraCapture.becameAuthorized()` is the public entry that
      AppDelegate (07-06) will call to start the session, and from
      there `PresenceMonitor.start()` (D-09 presence-on-by-default).
- [x] `PresenceSignalBus` is a read-only `AsyncStream<PresenceEvent>`;
      its `init` is `internal`, so only `PresenceMonitor` (in-module)
      can construct it. The legitimate consumers ContextBuilder and
      HudStateCoordinator land in 07-06.
- [x] `PresenceMonitor` emits `.transition` events only on edge crossings
      debounced at 2.0 s; secondary 5-minute absent threshold elevates
      the event to `.absentLongTerm`. Both verified by
      `testDebouncesShortBlips` and `testEmitsAbsentLongTermAfter5Minutes`.
- [x] `DisablePresence` is UserDefaults-persisted at
      `features.vision.presenceDisabled`; menu-item state mirrors the
      bool; pause/resume routed to PresenceMonitor only;
      CameraCapture untouched (verified by static-grep test).
- [x] `CameraCapture` exposes `captureFrame()` (one-shot async) and
      `frameStream(forPresence:)`; no continuous video buffer escapes
      the Vision package boundary (the only consumer of
      `frameStream(forPresence:)` in-tree is `PresenceMonitor`,
      inside the Vision module).
- [x] Camera TCC denial yields `VisionDegradationReason.cameraDenied`
      on `degradationStream` AND throws `VisionError.tccDenied`
      (verified by `testTCCDeniedYieldsDegradationAndThrows`).
      Mid-session revocation observer wired via NotificationCenter
      yields `.midSessionRevoked` on the same stream.
- [x] `App/Info.plist` contains `NSCameraUsageDescription` with the
      plan's exact text.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 — Blocking] Workspace has no top-level `Package.swift`**

- **Found during:** Task 1.
- **Issue:** The plan's acceptance criteria reference a root
  `Package.swift` (e.g.,
  `grep -c 'package(path: "packages/Vision")' Package.swift returns 1`).
  No such file exists in this workspace; XcodeGen's `project.yml` is
  the workspace manifest. This is the same deviation Plan 07-01
  hit and resolved.
- **Fix:** Wire `Vision` into `project.yml` mirroring how Memory was
  wired in Plan 07-01 — a `Vision:` entry under `packages:` and a
  `- package: Vision / product: JarvisVision` line under
  `targets.Jarvis.dependencies`. Regenerated `Jarvis.xcodeproj` via
  `xcodegen generate`. Plan intent (Vision consumable from the App
  target) is met.
- **Files modified:** `project.yml`, `Jarvis.xcodeproj/project.pbxproj`.
- **Commit:** `c988970`.

**2. [Rule 3 — Blocking] Module name `Vision` collides with Apple's
Vision framework**

- **Found during:** Task 2 (first compile of `PresenceMonitor.swift`).
- **Issue:** When a source file inside an SPM module named `Vision`
  writes `import Vision`, the Swift compiler treats it as a self-
  import and silently skips loading Apple's framework. Result: the
  symbols `VNDetectFaceRectanglesRequest` and `VNImageRequestHandler`
  do not resolve; the compiler emits "cannot find … in scope".
  `@preconcurrency import Vision` did not change the behavior. The
  compile failure is reproducible on the plan's exact code.
- **Fix:** Rename the SPM module / library product from `Vision` to
  `JarvisVision` (matches the existing `JarvisLogging` convention).
  The package directory stays `packages/Vision`; the grep gates key
  off the directory path, not the module name. `project.yml` references
  `product: JarvisVision`. Tests `@testable import JarvisVision`. All
  source files retain `import Vision` to pull in Apple's framework
  cleanly. The plan body's intent ("Vision module exposes
  PresenceSignalBus / CameraCapture / …") is preserved; only the
  Swift module name changed.
- **Files modified:** `packages/Vision/Package.swift`, `project.yml`,
  all five test files.
- **Commit:** `0238817`.

**3. [Rule 1 — Bug] `feedObservation` did not honor `paused`**

- **Found during:** Task 2 (writing `testPauseStopsEmissions` against
  the plan's verbatim PresenceMonitor body).
- **Issue:** The plan's `feedObservation` test seam called
  `applyObservation` directly without checking `paused`. The
  `testPauseStopsEmissions` test feeds two observations after `pause()`
  and asserts no events are published — but the plan's code path
  would publish, because only `consume()` (the production frame-
  loop entry) was gated on `paused`.
- **Fix:** Added a one-line `guard !paused else { return }` at the
  top of `feedObservation`. This matches Voice's VOICE-12 pattern
  (the pause gate sits inside the work-doing function, not just at
  the loop entry). Production semantics are unchanged.
- **Files modified:** `packages/Vision/Sources/Vision/PresenceMonitor.swift`.
- **Commit:** `0238817`.

**4. [Rule 1 — Bug] 5-minute long-term test margin off-by-3-seconds**

- **Found during:** Task 2.
- **Issue:** The plan's `testEmitsAbsentLongTermAfter5Minutes` fed
  observations at `t0` and `t0+3`, then evaluated long-term at
  `t0 + 5*60 + 1`. But the second observation is what publishes the
  `.absent(since: t0+3)` transition (the candidate state's `since`
  uses the *latest* timestamp). The 5-minute threshold check inside
  `evaluateLongTerm` compares against `since`, so 301 - 3 = 298 s
  is **less** than 300 s, and the long-term event would not fire.
- **Fix:** Bump the test's evaluator timestamp from `t0 + 5*60 + 1`
  to `t0 + 3 + 5*60 + 1` — aligns with the production semantics
  literally ("5 minutes after the absent transition was confirmed").
  Production code is unchanged.
- **Files modified:**
  `packages/Vision/Tests/VisionTests/PresenceMonitorDebounceTests.swift`.
- **Commit:** `0238817`.

**5. [Rule 1 — Bug] `firstEvent` / `firstDeg` test helpers used
non-Sendable iterators across `withTaskGroup`**

- **Found during:** Task 2 (writing the debounce + TCC test files).
- **Issue:** The plan's `firstEvent` / `firstDeg` helpers captured an
  `AsyncStream<…>.Iterator` inside two child tasks of a TaskGroup.
  Iterators are not `Sendable`; under Swift 6 strict concurrency the
  tasks could not safely share the iterator, and even with `var
  localIter = iter` the two tasks raced on the same value.
- **Fix:** Replace with a simpler "race a collector Task against a
  timeout Task" pattern: the collector pulls events directly off the
  stream into a local `[PresenceEvent]` (or `VisionDegradationReason?`),
  the timeout cancels the collector, and the collector's `value`
  is awaited. No iterator crosses a task boundary.
- **Files modified:** `PresenceMonitorDebounceTests.swift`,
  `CameraCaptureTCCTests.swift`.
- **Commit:** `0238817`.

**6. [Rule 1 — Trivial] `var localLogger` warning**

- **Found during:** Task 2 first build.
- **Issue:** `let` would do — `localLogger.warning(...)` does not
  mutate the Logger value.
- **Fix:** `var` → `let`.
- **Commit:** `0238817`.

### TDD Gate Compliance

The plan declared `tdd="true"` on Tasks 2 and 3. Both tasks were
committed with combined RED/GREEN bodies because the test cases — for
both Task 2 (deterministic enum equality, edge-debounced state machine,
TCC switch fan-out) and Task 3 (UserDefaults round-trip + static
source-grep) — have no meaningful "failing-without-implementation"
state: the symbols (`PresenceMonitor`, `CameraCapture`, `DisablePresence`)
have to exist for the tests to even compile. The deterministic
assertions are intrinsically non-RED-able for the same reason
07-01 noted ("schema-shape tests are pure-data assertions and are
intrinsically non-RED-able"). Test files are co-resident on disk
with their implementations in the GREEN commits.

| Gate | Commits | Verified |
|------|---------|----------|
| GREEN | `0238817` (Task 2), `43e7b8a` (Task 3) | ✓ |
| REFACTOR | (not needed) | n/a |

## Auth gates

None — Plan 07-04 is pure local-Swift work. Camera TCC is exercised
only via the `authStatusProbe` test seam in unit tests; runtime TCC
prompting is deferred to Plan 07-06's `AppDelegate.installVision`.

## Threat flags

No new threat-relevant surfaces beyond the plan's existing
`<threat_model>`. The module-rename to `JarvisVision` does not change
the trust surface — it is a name-resolution adjustment, not a new API
or new dependency.

## Forwarded items for downstream plans

| Item | Recipient | Why |
|------|-----------|-----|
| `AVCaptureVideoDataOutput` delegate plumbing — wire `frameStream(forPresence:)` to a real continuation populated by `captureOutput(_:didOutput:from:)` | Plan 07-06 (`AppDelegate.installVision`) | 07-04 ships the API surface (an empty stream) so the package is testable with synthetic samples. The production sample-buffer path is one delegate-bridge actor away. |
| `AVCapturePhotoOutput` delegate body for `captureFrame()` (downscale to 1024 dim, JPEG 0.85, return `CapturedFrame`) | Plan 07-05 (frame-attach + multimodal routing) | Plan body explicitly defers the JPEG capture body to 07-05; 07-04's stub returns a 1×1 JPEG and asserts only the throw-when-not-running path. |
| Wire `PresenceSignalBus` into `ContextBuilder` (D-10 system-prompt enrichment) and `HudStateCoordinator` (D-10 subtle ring indicator) | Plan 07-06 | The bus is read-only by design; the integration is two small subscribers in Plan 07-06's `installVision()`. |
| Wire `CameraCapture.degradationStream` into `HUDBannerCoordinator.enqueue(.cameraDenied / .cameraRevoked)` | Plan 07-06 | `BannerContent` does not yet have `.cameraDenied` / `.cameraRevoked` cases — Plan 07-06 adds them alongside the `installVision()` wiring. |
| Add `JarvisLogChannel.vision` enum case (currently we use plain string "vision.capture" / "vision.presence" labels) | Plan 07-06 (DevOverlay) | Adds the channel for filtered DevOverlay views. Out of scope for 07-04's package boundary. |

## Out-of-scope discovery — not fixed

`packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift::testI3_completionTimeoutRespected`
is intermittently failing in this environment with a 10 s wall-clock
overrun (CoreData XPC bootstrapping took ~10 s before the assertion's
80 ms budget could complete). The test is from Phase 6 commit
`4d7bd76` and is unrelated to Plan 07-04's changes — confirmed by
running `swift test` before any 07-04 edits and reproducing the same
flake. Logged to deferred-items list per scope-boundary rule;
not fixed in this plan.

## Self-Check: PASSED

Verified files exist and commits are reachable:

- `packages/Vision/Package.swift` — FOUND
- `packages/Vision/Sources/Vision/CameraCapture.swift` — FOUND
- `packages/Vision/Sources/Vision/CapturedFrame.swift` — FOUND
- `packages/Vision/Sources/Vision/DisablePresence.swift` — FOUND
- `packages/Vision/Sources/Vision/PresenceEvent.swift` — FOUND
- `packages/Vision/Sources/Vision/PresenceMonitor.swift` — FOUND
- `packages/Vision/Sources/Vision/PresenceSignalBus.swift` — FOUND
- `packages/Vision/Sources/Vision/VisionDegradationReason.swift` — FOUND
- `packages/Vision/Sources/Vision/VisionError.swift` — FOUND
- `packages/Vision/Tests/VisionTests/CameraCaptureTCCTests.swift` — FOUND
- `packages/Vision/Tests/VisionTests/DisablePresenceTests.swift` — FOUND
- `packages/Vision/Tests/VisionTests/PackageBoundaryTests.swift` — FOUND
- `packages/Vision/Tests/VisionTests/PresenceMonitorDebounceTests.swift` — FOUND
- `packages/Vision/Tests/VisionTests/PresenceSignalBusTests.swift` — FOUND
- `scripts/check-vision-isolation.sh` — FOUND, executable
- `scripts/check-presence-bus-no-tts-orchestrator.sh` — FOUND, executable
- `c988970` — FOUND (Task 1 scaffold)
- `0238817` — FOUND (Task 2 PresenceSignalBus + CameraCapture + PresenceMonitor)
- `43e7b8a` — FOUND (Task 3 DisablePresence)

Gates run:

- `swift build --package-path packages/Vision` → exit 0.
- `swift test --package-path packages/Vision` → 14 executed, 0 skipped,
  0 failures.
- `bash scripts/check-vision-isolation.sh` → exit 0.
- `bash scripts/check-presence-bus-no-tts-orchestrator.sh` → exit 0.
- `bash scripts/check-app-builds.sh` → PASS.
- `/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' App/Info.plist`
  → prints the configured string.
