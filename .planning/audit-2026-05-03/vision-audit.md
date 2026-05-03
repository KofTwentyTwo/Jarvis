# Vision Subsystem — Brutal Audit (2026-05-03)

## TL;DR — Grade: **F**

**Verdict:** The Vision subsystem is a **scaffold simulating a feature**. Camera capture is a hardcoded 1×1 black JPEG. Screen capture does not exist — no `ScreenCaptureKit`, `SCStream`, or `CGDisplayCreateImage` anywhere in tree. The "T2 quality tier" sidecar (`VllmMlxSidecar`) is **never instantiated outside tests** — `VisionRouter` is wired with `t1Provider == t2Provider`, so escalation is a no-op. The HUD has **no camera button** — the bus message `frameAttachRequested` has zero JS-side emitters. `FrameAttachController.confirmSend(...)` has **zero non-test callers** in the entire codebase. Presence detection is the one component that is structurally real (Vision framework face rectangles, debounce machine), but its frame source is an empty `AsyncStream` that calls `cont.finish()` on creation. End-to-end: camera at a cat → nothing happens. This subsystem cannot be demonstrated.

---

## 1. CameraCapture — confirmed stub

**File:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Vision/Sources/Vision/CameraCapture.swift`

### `captureFrame()` — line 102-115
Hardcoded 1×1 black JPEG. Returns `CapturedFrame(jpegData: Self.onePixelJPEG(), width: 1, height: 1, ...)`. The session is built (line 138-159) and `AVCapturePhotoOutput` is added to it (line 153-155), but `photoOutput.capturePhoto(...)` is **never called anywhere in the file**. No `AVCapturePhotoCaptureDelegate` conformance exists. The output is allocated, attached, and abandoned.

### `frameStream(forPresence:)` — line 126-134
Returns a stream that calls `cont.finish()` immediately. Comment line 127-130: *"production path is intentionally a no-op stream. 07-06 wires the AVCaptureVideoDataOutput delegate to a continuation captured here. Until then, return an empty stream that finishes immediately."* That wiring never landed. **PresenceMonitor's input is permanently empty.**

### `onePixelJPEG()` — line 190-212
125-byte hex-encoded inline JPEG. Comment line 187: *"Replaced by AVCapturePhotoOutput delegate output in 07-05."* Plan 07-05 closed; replacement never landed. Confirms `BLOCKER-INT-4` / `C1` from `.planning/v0.12.0-MILESTONE-AUDIT.md`.

**Other methods:** `open()`, `becameAuthorized()`, `shutdown()`, `buildSession()`, `startWatchers()` — these are real (TCC gating, `AVCaptureSession.startRunning()`, runtime-error observer). The plumbing for a real camera exists; the data extraction does not.

---

## 2. AVCapturePhotoOutput delegate flow

**Apple's required pattern** (from `AVFoundation`):
1. `AVCapturePhotoOutput` instance added to session (✅ done — line 153-155).
2. Caller invokes `photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)`.
3. Class conforms to `AVCapturePhotoCaptureDelegate` and implements `photoOutput(_:didFinishProcessingPhoto:error:)`, extracting `photo.fileDataRepresentation()` for JPEG bytes.

**In this codebase:** zero. `grep -rn "capturePhoto\|AVCapturePhotoCaptureDelegate"` returns only the field declaration at `CameraCapture.swift:29`, the instantiation at line 153, and the two stub comments. **No delegate. No `capturePhoto()` invocation. No async-bridge continuation between the delegate callback and the `captureFrame()` async return.** This is not a hard problem (~80 LOC for a continuation-based actor wrapper), but the work was never done.

---

## 3. VisionRouter — dispatch is real, the destinations collapse

**File:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Vision/Sources/Vision/VisionRouter.swift`

The router itself **is real**. `route(...)` (line 50-59) returns T1 or T3 based on `explicitCloudOptIn`. `evaluatePostResponse(...)` (line 63-76) runs the low-confidence heuristic and returns `.escalateToT2` or `.useT1Result`. `providerForTier(...)` (line 80-86) dispatches to the right `LLMProvider`.

**But the wiring at `App/AppDelegate.swift:1314-1324` collapses the tier ladder:**

```
let t1 = OllamaProvider(baseURL: ...11434)
let router = VisionRouter(
    t1Provider: t1,
    t2Provider: t1,                  // sidecar plan pending — T2 reuses T1 provider
    t3Provider: t3,
)
```

T2 **is** T1. `VllmMlxSidecar` is never constructed (`grep -rn "VllmMlxSidecar(" --include="*.swift"` outside `Tests/` returns nothing). `VllmMlxProvider` is never constructed either. So `evaluatePostResponse → .escalateToT2 → providerForTier(.t2LocalQuality) → t1Provider` — a silent no-op re-run on the same model. The tier ladder is decorative.

`AgentOrchestrator.runTurn` (`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:202-225`) **does** call `router.route(...)` and swap providers when `input.images` is non-empty — that integration is real. But `input.images` arrives from `confirmSend(...)`, which has no caller (see §4).

---

## 4. FrameAttachController — orphaned

**File:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Vision/Sources/Vision/FrameAttachController.swift`

The controller is structurally complete: `requestAttach`, `confirmSend`, `cancel`, `onAssistantTurnComplete`, sole-emission-site invariant, default-cancel timeout. **The state machine is correct.**

**What's broken:** the producers and consumers around it.

- **Phrase trigger**: `App/AppDelegate.swift:1149-1155` calls `requestAttach(reason: .phraseDetected(in: text))` from `tryPhraseAttachIfMatch(text)`, invoked before chat submit. **Real.**
- **HUD button trigger**: `App/AppDelegate.swift:1522-1523` calls `requestAttach(reason: .hudButton)` on receipt of `BusInbound.frameAttachRequested`. **The Swift handler is real.**
- **HUD button emitter**: `grep -rn "frameAttachRequested" webview/packages/hud/src` → zero matches. The bus protocol declares the message (`webview/packages/bus/src/protocol.ts:77`) and the round-trip test exercises a fixture (`tests/round-trip.test.ts:67`), but **no React component dispatches it.** `webview/packages/hud/src/hud/ParticleRing.tsx`'s "camera" references are the R3F 3D scene camera (line 23, 64-77), not a UI button. **There is no clickable camera UI.**
- **`confirmSend(userText:)`**: `grep -rn "confirmSend" --include="*.swift"` outside `Tests/` returns **zero non-test references**. Nothing in `App/` ever asks the controller for the captured frame. `requestAttach` arms the slot, the 2-second default-cancel timeout fires, `discardFrame()` clears it. The pending frame never reaches `AgentOrchestrator.submit(...)` because nothing builds a `TurnInput(images: [imageBlock])`.

**What happens if the user clicks the (nonexistent) HUD camera button?** Nothing — the bus message has no emitter. **What if the user types "can you see this"?** Phrase matches → `requestAttach` fires → `CameraCapture.captureFrame()` returns the 1×1 JPEG → frame sits in `pendingFrame` slot → 2-second timeout → `discardFrame()`. The orchestrator proceeds with text-only. The 1×1 JPEG never reaches a provider in the current wiring **because no path calls `confirmSend`.**

---

## 5. Screen capture — does not exist

```
grep -rn "ScreenCaptureKit\|SCStream\|SCShareableContent\|CGDisplayCreateImage" --include="*.swift"
→ 0 matches outside .build/
```

No `com.apple.security.screen-recording` entitlement in either `App/Jarvis.Release.entitlements` or `App/Jarvis.Debug.entitlements`. No TCC scaffolding for screen recording. **Screen capture is not partially implemented — it is completely absent.** The roadmap referenced it as Phase 7 / Vision; it never got into a plan.

---

## 6. Presence detection — partially real, unreachable

**File:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Vision/Sources/Vision/PresenceMonitor.swift`

The monitor's logic is **real**:
- `runVision(on: CMSampleBuffer, ...)` (line 176-186) and `runVision(onCG: ...)` (line 188-198) construct `VNDetectFaceRectanglesRequest()` and run it against `VNImageRequestHandler`. This is correct on-device Vision-framework face detection.
- `applyObservation(...)` (line 125-164) implements the 2.0s edge debounce + 5-minute long-term threshold from D-11.
- `PresenceStateSnapshot.currentEnrichment(now:)` (`PresenceStateSnapshot.swift:42-65`) renders the system-prompt sentence (`"User is at the desk."` / `"User has been away from the desk for N minutes."`).

**What's broken:** `frameStream` from `CameraCapture.frameStream(forPresence: true)` is the empty `AsyncStream { cont.finish() }` from §1. The `for await sample in stream` loop in `PresenceMonitor.start()` (line 53-58) **exits immediately** on a fresh stream. No frames are ever consumed. The face detector is wired to a dry pipe.

`PresenceStateSnapshot.shared` therefore stays at `latest = nil`, and `currentEnrichment(...)` returns `nil` → no system-prompt enrichment ever fires. The presence pipeline is "wired to fixed values" — specifically, fixed to "no observation."

The **synthetic test path** (`PresenceFrameSample.syntheticDetection`) is real and exercised by `PresenceMonitorDebounceTests`, which is why presence tests pass while production presence is mute.

---

## 7. Tests — REAL / MOCK / DEAD classification

**Files:** `packages/Vision/Tests/VisionTests/*.swift` (14 files).

| File | Class | Notes |
|---|---|---|
| `CameraCaptureTCCTests.swift` | **REAL** (TCC paths) | Tests denied/notDetermined/sessionNotRunning. **Does NOT assert real JPEG bytes** — only that `captureFrame()` throws when session not running. The success path is never exercised. |
| `FrameAttachControllerTests.swift` | **MOCK** | `FakeCapture` (line 124-136) returns a hand-crafted 10-byte fixture (`Data([0xFF, 0xD8, ...])`). The test asserts `imageBlock?.data == fixtureFrame.jpegData` (line 90) — it asserts the mock returns the mock. **Does not exercise the production stub or any real capture.** |
| `FrameAttachReplayPlaceholderTests.swift` | **REAL** (pure-fn) | Tests the `placeholder(for:)` byte string. Pure function, no Vision dependency. |
| `FrameAttachDiscardSiteGrepTests.swift` | **REAL** (structural) | greps source for jpeg/png patterns to enforce no-byte-leak invariant. Useful but doesn't exercise behavior. |
| `PresenceMonitorDebounceTests.swift` | **MOCK** | Uses `feedObservation` synchronous test seam + `syntheticDetection` samples. Does not exercise the `runVision(...)` paths or the empty `frameStream`. |
| `PresenceSignalBusTests.swift`, `PresenceStateSnapshotTests.swift`, `DisablePresenceTests.swift` | **REAL** (pure-state) | State machine + sentence rendering. No camera dependency. |
| `EscalationPhraseDetectorTests.swift` | **REAL** | Pure string matcher. |
| `VisionRouterTierLadderTests.swift`, `VisionRouterEscalationTests.swift`, `VisionRouterCloudOptInGrepTests.swift` | **REAL** (router logic) | Exercise `route` / `evaluatePostResponse`. Don't catch the App-side `t2Provider == t1Provider` collapse. |
| `VllmMlxSidecarSpawnTests.swift` | **MOCK** | `FakeProcessHandle` records spawn config. **Never spawns vllm-mlx; never reaches /health; nothing in production calls `VllmMlxSidecar.start()`.** |
| `PackageBoundaryTests.swift` | **REAL** (architecture) | Import-graph checks. |

**Critical gap:** **zero tests exercise `CameraCapture.captureFrame()`'s success path.** No test asserts a "non-trivial JPEG comes back." No test asserts `width > 1 && height > 1`. The 1×1 stub passes every test in this package.

---

## 8. End-to-end — what actually happens

User points camera at a cat, types "what is this":

1. Chat handler calls `tryPhraseAttachIfMatch("what is this")` → `ContextBuilder.matchesFrameAttachPhrase` returns false ("what is this" isn't in the trigger phrase set) → `requestAttach` is **not** called.
2. Even if the user said "can you see this", `requestAttach` would fire → `CameraCapture.captureFrame()` returns the 1×1 black JPEG → frame parks in `pendingFrame` → 2-second timeout fires → `discardFrame()` → text-only turn proceeds.
3. **Nothing in the codebase ever calls `confirmSend`.** No `TurnInput(images: [...])` is ever constructed in production. `AgentOrchestrator`'s vision dispatch branch (line 210) is unreachable.
4. Camera TCC is `tccNotDetermined` → `CameraCapture.open()` throws `tccNotDetermined` → AppDelegate logs `"installVision: CameraCapture.open() failed"` → presence/frame-attach degrade to no-op (which they already were).

**Single-sentence summary:** The agent answers from text alone, with no image context, because the camera is never triggered, the captured bytes would be junk if it were, and the controller that owns the frame has no consumer wired to deliver it to the LLM.

---

## What to fix, in order

1. **Implement the `AVCapturePhotoOutput` delegate flow** in `CameraCapture.captureFrame()`. ~80 LOC, well-understood pattern. Add a test that asserts `frame.width >= 1280 && frame.jpegData.count > 1000`.
2. **Wire `frameStream` to `AVCaptureVideoDataOutput`'s delegate** so PresenceMonitor receives sample buffers.
3. **Build the HUD camera button** — a React component that posts `frameAttachRequested` and renders a confirmation modal that posts a new `frameAttachConfirmed { userText }` (which the bus protocol does not yet declare). Add the inbound message + Swift handler that calls `frameAttachController.confirmSend(...)` then `agentOrchestrator.submit(.text(text), images: [block])`.
4. **Instantiate `VllmMlxSidecar` + `VllmMlxProvider`** in AppDelegate (or rip T2 out entirely and document the router as T1/T3 only).
5. **Decide whether screen capture is in scope.** If yes, plan it. If no, remove references from PROJECT.md.
