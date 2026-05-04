# Vision

Library product `JarvisVision`. Camera capture, presence detection, frame-attach to a turn, and tier routing for vision-capable LLMs.

## Key public types

| Type | Purpose |
|------|---------|
| `CameraCapture` (actor) | `AVCaptureSession` lifecycle. `captureFrame()` for one-shot stills via `AVCapturePhotoOutput`; `frameStream(forPresence:)` for continuous fan-out |
| `FrameAttachController` (actor) | Lifecycle owner of the pending-frame slot. `requestAttach(reason:)` → `confirmSend(userText:)` / `cancel()` / `onAssistantTurnComplete()` |
| `PresenceMonitor` | At-desk detection from frame stream |
| `PresenceEvent` / `PresenceStateSnapshot` | Presence stream types |
| `VisionRouter` | Picks T1 (Ollama) / T2 (vllm-mlx) / T3 (Anthropic cloud-escape) |
| `VisionTier` | T1 / T2 / T3 enum |
| `MissingT2Provider` | Explicit-missing T2 — surfaces unwired sidecar (no silent T1 fallback) |
| `VllmMlxProvider` / `VllmMlxSidecar` | Skeleton for the T2 sidecar (not yet wired) |
| `EscalationPhraseDetector` / `VisionEscalationHeuristic` | Heuristics for tier escalation |
| `ContextBuilder` | Phrase trigger detection (`take a look at this` → `requestAttach`) |
| `CapturedFrame` | JPEG bytes + dimensions |
| `VisionError` | Error union |

## Depends on

`AgentCore`, `MCP` (`JarvisChildSpawn` for sidecar spawning), `Logging`. External: `swift-log`, `OllamaProvider`, `AnthropicProvider` (T1/T3).

## Used by

`App/AppDelegate`, `App/Vision/`, `packages/AgentCore` (orchestrator imports `JarvisVision` for the multimodal-stream overload's image type bridging).

## Key invariants / contracts

- **`captureFrame()` returns ONE still frame on demand.** Continuous video is not exposed outside the package — only `frameStream(forPresence:)`, and `PresenceMonitor` is the only in-tree consumer.
- **`FrameAttachController.discardFrame()` is the SOLE emission site** for clearing the pending-frame slot (D-15). Every release path (cancel, timeout, assistant-turn-complete) routes through that single function. `FrameAttachDiscardSiteGrepTests` enforces structurally.
- **Single ingest path.** `requestAttach(reason:)` is reachable from BOTH (a) `ContextBuilder.matchesFrameAttachPhrase` AND (b) the HUD camera-icon Bus message. Both producers reach the same method (D-13 dual-trigger contract).
- **`MissingT2Provider` is intentional.** Replaces the silent `t2Provider: t1` AppDelegate hardcode (Track C-4); makes the missing wiring debuggable instead of silent.
- **Vision isolation.** `scripts/check-vision-isolation.sh` + `check-presence-vision-isolation.sh` enforce the package boundary (no upward leaks).
- **Presence bus doesn't reach TTS or orchestrator directly.** `scripts/check-presence-bus-no-tts-orchestrator.sh`.

## Tests

72 XCTest. `CameraCaptureRealHardwareTests` is gated by `JARVIS_REAL_CAMERA=1` + `.authorized` TCC — runs interactively only.

## Notable files

- `Sources/Vision/CameraCapture.swift` — actor + `AVCaptureSession` lifecycle
- `Sources/Vision/FrameAttachController.swift` — pending-frame lifecycle
- `Sources/Vision/PresenceMonitor.swift` — at-desk detection
- `Sources/Vision/VisionRouter.swift` — T1/T2/T3 routing
- `Sources/Vision/MissingT2Provider.swift` — explicit-missing T2
