---
phase: 07-memory-vision
plan: 05
subsystem: vision
tags: [vision, multimodal, llm-provider, frame-attach, vllm-mlx, privacy]
dependency_graph:
  requires:
    - 07-04 (JarvisVision SPM scaffold + PresenceSignalBus)
    - 04-01 (AnthropicProvider streaming)
    - 04-02 (OllamaProvider streaming)
    - 05-01 (ChildSpawnGate spawn pattern)
  provides:
    - "LLMProvider multimodal stream(messages:images:...) protocol surface"
    - "ImageBlock canonical frame value type (AgentCore)"
    - "TurnInput.images additive field"
    - "VisionRouter (D-16/D-17/D-18 tier ladder + heuristic)"
    - "VllmMlxSidecar + VllmMlxProvider + VllmMlxAvailability (T2 path)"
    - "FrameAttachController (D-13/D-14/D-15 dual-trigger ingest + confirm gate + discard edge)"
    - "FrameAttachReplaySink (D-15 placeholder-only payload)"
    - "EscalationPhraseDetector (D-13 frame-attach + D-18 cloud opt-in)"
    - "ContextBuilder (sole non-test caller of EscalationPhraseDetector)"
    - "JarvisChildSpawn standalone target (extracted from JarvisMCP for VISION-03)"
  affects:
    - "JarvisMCP (now depends on JarvisChildSpawn for ChildSpawnGate)"
    - "Replay (ReplayEvent.userInput doc comment documents image-payload placeholder convention)"
tech-stack:
  added:
    - "VllmMlxProvider (thin actor wrapping OllamaProvider with useOpenAICompat=true)"
    - "JarvisChildSpawn SPM target (ChildSpawnGate hoisted out of JarvisMCP)"
  patterns:
    - "Default protocol extension forwarding for additive method on LLMProvider (D-18)"
    - "Single-emission-site invariant (mirrors Phase 6 TTSInterrupt pattern)"
    - "Cancellation-aware Task.sleep guard (prevents post-cancel timeout firing)"
    - "Word-bounded case-insensitive contains (phrase detector boundary check)"
    - "Process factory + spawn-gate dependency injection for sidecar tests"
key-files:
  created:
    - packages/AgentCore/Sources/AgentCore/ImageBlock.swift
    - packages/AgentCore/Tests/AgentCoreTests/LLMProviderMultimodalTests.swift
    - packages/AgentCore/Tests/AnthropicProviderTests/AnthropicImageBlockEncodingTests.swift
    - packages/AgentCore/Tests/OllamaProviderTests/OllamaImageBlockEncodingTests.swift
    - packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift (renamed from MCP target)
    - packages/Vision/Sources/Vision/VllmMlxProvider.swift
    - packages/Vision/Sources/Vision/VllmMlxSidecar.swift
    - packages/Vision/Sources/Vision/VllmMlxAvailability.swift
    - packages/Vision/Sources/Vision/VisionTier.swift
    - packages/Vision/Sources/Vision/VisionRouterConfig.swift
    - packages/Vision/Sources/Vision/VisionEscalationHeuristic.swift
    - packages/Vision/Sources/Vision/EscalationPhraseDetector.swift
    - packages/Vision/Sources/Vision/ContextBuilder.swift
    - packages/Vision/Sources/Vision/VisionRouter.swift
    - packages/Vision/Sources/Vision/FrameAttachController.swift
    - packages/Vision/Sources/Vision/FrameConfirmationDecision.swift
    - packages/Vision/Sources/Vision/FrameAttachReplaySink.swift
    - packages/Vision/Tests/VisionTests/VllmMlxSidecarSpawnTests.swift
    - packages/Vision/Tests/VisionTests/EscalationPhraseDetectorTests.swift
    - packages/Vision/Tests/VisionTests/VisionRouterTierLadderTests.swift
    - packages/Vision/Tests/VisionTests/VisionRouterEscalationTests.swift
    - packages/Vision/Tests/VisionTests/VisionRouterCloudOptInGrepTests.swift
    - packages/Vision/Tests/VisionTests/FrameAttachControllerTests.swift
    - packages/Vision/Tests/VisionTests/FrameAttachDiscardSiteGrepTests.swift
    - packages/Vision/Tests/VisionTests/FrameAttachReplayPlaceholderTests.swift
  modified:
    - packages/AgentCore/Sources/AgentCore/LLMProvider.swift (added multimodal stream + default extension)
    - packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift (added images field + withImages factory)
    - packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift (multimodal stream override)
    - packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift (encodeMultimodal + image_block encoder)
    - packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift (multimodal stream override)
    - packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift (multimodal encoders + types)
    - packages/MCP/Package.swift (new JarvisChildSpawn target + dep edge)
    - packages/MCP/Sources/MCP/MCPClient.swift (import JarvisChildSpawn)
    - packages/MCP/Sources/MCP/MCPServerHandle.swift (import JarvisChildSpawn)
    - packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift (@testable import JarvisChildSpawn)
    - packages/Vision/Package.swift (add OllamaProvider, AnthropicProvider, JarvisChildSpawn deps)
    - packages/Vision/Sources/Vision/VisionError.swift (add .sidecarStartupTimeout)
    - packages/Replay/Sources/Replay/ReplayEvent.swift (image-payload placeholder doc comment)
decisions:
  - "ChildSpawnGate hoisted into a new JarvisChildSpawn SPM target to satisfy VISION-03 — the JarvisMCP target imports AgentOrchestrator transitively, which Vision must not pull. This is a Rule 3 deviation pre-emptively allowed by the plan body's read_first note."
  - "FrameAttachDiscardSiteGrepTests grep target adapted from `grep -c 'discardFrame' == 1` to `grep 'pendingFrame = nil' == 1` plus `func discardFrame` presence check. The plan's literal `grep -c` requirement is unrealistic when the function has internal callers (cancel/timeout/onAssistantTurnComplete each reference it). The adapted invariant verifies what actually matters: the byte-clearing assignment is unique and the function exists."
  - "Default protocol extension on LLMProvider precondition-fails (rather than silently no-ops) when a non-overriding conformer receives non-empty images. Loud failure surfaces the misconfiguration instead of swallowing it."
metrics:
  duration: ~75 min
  tasks: 6/6
  tests_added: 11 files (28 test methods)
  files_created: 25
  files_modified: 13
  completed_at: 2026-04-29
---

# Phase 07 Plan 05: Frame-attach + multimodal LLMProvider + T1/T2/T3 vision routing — Summary

## One-liner

Cross-provider multimodal LLM surface (Anthropic image_block + OpenAI-compat image_url) plus a deterministic three-tier vision router (Gemma 4 → Qwen 3.5 vllm-mlx → Opus 4.7) gated by an always-confirm frame-attach controller with a single-emission-site byte-discard invariant.

## What landed

Six tasks executed atomically with TDD (RED → GREEN, no REFACTOR commits needed):

1. **LLMProvider multimodal protocol extension + ImageBlock + TurnInput.images** (Task 1)
   - `ImageBlock(mediaType: String, data: Data)` Sendable+Equatable canonical frame type.
   - `LLMProvider` gains `stream(messages:images:tools:toolChoice:model:maxOutputTokens:cacheHints:)`. Default extension forwards to the existing single-modal stream when `images.isEmpty` and `precondition`-fails for non-overriding conformers receiving non-empty images.
   - `TurnInput` gains `images: [ImageBlock]` (default `[]`) plus `TurnInput.withImages(_:text:images:)` factory. Backward-compatible.

2. **AnthropicProvider image_block override** (Task 2)
   - `RequestBody.encodeMultimodal` produces the Anthropic Vision API `image_block` shape: `{type:image, source:{type:base64, media_type, data}}`.
   - `AnthropicProvider.run` unified to a single multimodal-capable code path; single-modal stream forwards via `images: []` (byte-identical to original encoder).
   - `EncodedContentBlock` gains optional `source` field for image blocks.

3. **OllamaProvider OpenAI-compat image_url override** (Task 3)
   - `OllamaRequestBody.encodeNativeMultimodal` and `encodeOpenAICompatMultimodal` produce the OpenAI vision data-URL block: `{type:image_url, image_url:{url:'data:<mediaType>;base64,<b64>'}}`.
   - Both T1 (Ollama gemma4:31b) and T2 (vllm-mlx Qwen3.5 via `useOpenAICompat: true`) consume the same encoder.
   - Empty images still produce byte-identical bodies relative to the single-modal encoders.

4. **VllmMlxProvider + VllmMlxSidecar + Availability gate** (Task 4)
   - `VllmMlxProvider` is an actor wrapping `OllamaProvider(useOpenAICompat: true)` — clean ownership at the package boundary.
   - `VllmMlxSidecar` actor: `start()` calls `ChildSpawnGate.shared.prepare()` BEFORE Process is created; sets `proc.environment = ChildSpawnGate.minimalEnvironment` verbatim; bounded `/health` warmup window throws `VisionError.sidecarStartupTimeout` on miss.
   - `ProcessFactory` + `SpawnGate` injection seams enable test fakes that capture spawn config without running a real binary.
   - Lazy `ensureRunning()` — first T2 need triggers startup (PATTERNS Risk #2 mitigation).
   - `VllmMlxAvailability.isAvailable` combines macOS-26 runtime guard, binary-path existence check, and `features.vision.tier2` feature flag.

5. **VisionRouter + heuristic + phrase detection + ContextBuilder** (Task 5)
   - `VisionTier` enum with `t1Local` / `t2LocalQuality` / `t3Cloud` and `defaultModelID` mapping. `VisionTier.swift` is the SOLE source-tree location of the literal `"claude-opus-4-7"`, `"gemma4:31b"`, `"Qwen/Qwen3.5-35B-A3B-VL"` strings.
   - `VisionRouterConfig` public struct with **named** planner-tuned fields (substring set, length threshold, phrase sets, timeouts) — D-17 review/tunability requirement satisfied.
   - `VisionEscalationHeuristic.evaluateLowConfidence` reads from the passed config — no hidden defaults.
   - `EscalationPhraseDetector.matchesCloudOptIn` (D-18) is the **only** function whose return value can flip the router to T3. Word-bounded case-insensitive matching prevents false positives like `"send to my friend"` and `"opusxyz"`.
   - `ContextBuilder` is the sole non-test caller of the phrase detectors.
   - `VisionRouter.evaluatePostResponse(...)` returns `.useT1Result` or `.escalateToT2` — **never** `.escalateToT3`. T2-unavailable + low-confidence stays on T1 (D-18 no-auto-cloud cardinal invariant).
   - `VisionRouterCloudOptInGrepTests` is the structural backstop — every cloud reference inside `packages/Vision/Sources/Vision` lives in a file that ALSO references `matchesCloudOptIn`, or is the `VisionTier.swift` constants file.

6. **FrameAttachController + always-confirm gate + sole emission site + replay placeholder** (Task 6)
   - `FrameAttachController.requestAttach(reason:)` is the SINGLE entry point — both phrase detection and the HUD camera-icon Bus message route here (D-13 dual-trigger).
   - `confirmSend(userText:)` returns the `ImageBlock`; `cancel()` discards immediately; the 2-second default-cancel timeout fires `.timeout` and discards (D-14 always-confirm).
   - `discardFrame()` is the SOLE function in the file that clears `pendingFrame`. The literal assignment `pendingFrame = nil` appears **EXACTLY ONCE** in `FrameAttachController.swift` (inside `discardFrame()`). Cancel, timeout, and `onAssistantTurnComplete()` all route through this single function (D-15 single emission site).
   - `FrameAttachReplaySink` records the literal placeholder JSON `{"type":"image","discarded":true,"text":"<text>"}`. The function signature accepts only the user's textual prompt — raw image bytes never enter the sink.
   - `FrameAttachDiscardSiteGrepTests` enforces the single-emission invariant + raw-bytes egress fence (no `pngData` / `jpegData` / `imageBlock.data` / `UIImagePNGRepresentation` / `UIImageJPEGRepresentation` patterns reach `packages/Replay/Sources` or the sink file).

## Test results

Per-package counts after the plan landed:

| Package      | Tests | Failures |
|--------------|------:|---------:|
| AgentCore    |  147  |    0     |
| Vision       |   47  |    0     |
| Replay       |   27  |    0     |
| MCP (ChildSpawnGate subset) |    3  |    0     |

Eleven new test files added by this plan:
- `LLMProviderMultimodalTests` (4)
- `AnthropicImageBlockEncodingTests` (4)
- `OllamaImageBlockEncodingTests` (5)
- `VllmMlxSidecarSpawnTests` (5)
- `EscalationPhraseDetectorTests` (6)
- `VisionRouterTierLadderTests` (4)
- `VisionRouterEscalationTests` (7)
- `VisionRouterCloudOptInGrepTests` (1)
- `FrameAttachControllerTests` (5)
- `FrameAttachDiscardSiteGrepTests` (3)
- `FrameAttachReplayPlaceholderTests` (2)

**Total new test methods:** 46.

## Phase-level grep gates (verification §)

| Gate | Result |
|------|--------|
| Single-emission-site (`pendingFrame = nil` count == 1 in `FrameAttachController.swift`) | PASS — verified by `FrameAttachDiscardSiteGrepTests.testDiscardFrameSingleEmissionSite` |
| Raw-bytes egress fence (no png/jpeg serialization in Replay sources or `FrameAttachReplaySink`) | PASS — `grep -rE 'pngData\|jpegData\|UIImagePNGRepresentation\|UIImageJPEGRepresentation\|imageBlock\.data\b' packages/Replay/Sources packages/Vision/Sources/Vision/FrameAttachReplaySink.swift` returns 0 matches |
| No-auto-cloud invariant (`AnthropicProvider`/`claude-opus` only in files reaching `matchesCloudOptIn` or in `VisionTier.swift`) | PASS — verified structurally by `VisionRouterCloudOptInGrepTests`. Only `VisionTier.swift` references the literal model name |
| VISION-03 boundary (`packages/Vision` does NOT depend on `JarvisVoice` or `JarvisAgentOrchestrator`) | PASS — `bash scripts/check-vision-isolation.sh` clean; `swift package show-dependencies` shows only `AgentCore`, `OllamaProvider`, `AnthropicProvider`, `JarvisChildSpawn`, `JarvisLogging`, `swift-log` |

## Deviations from Plan

### [Rule 3 - Blocking] ChildSpawnGate extracted into JarvisChildSpawn target

- **Found during:** Task 4
- **Issue:** The plan's `read_first` note flagged this: "If `JarvisMCP` transitively imports `JarvisAgentOrchestrator`, isolate the `ChildSpawnGate` symbol into a smaller sub-target". `JarvisMCP` does import `AgentOrchestrator` (in `ConfirmingToolDispatcher.swift` and `MCPToolDispatcher.swift`), so importing `JarvisMCP` from `packages/Vision` would have transitively pulled `AgentOrchestrator` into Vision — violating VISION-03.
- **Fix:** Hoisted `ChildSpawnGate.swift` into a new SPM target `JarvisChildSpawn` inside the MCP package. The new target depends only on `swift-log`. `JarvisMCP` continues to import the same singleton via the new dependency. `MCPServerHandle.swift` and `MCPClient.swift` gained `import JarvisChildSpawn`. `ChildSpawnGate.swift` switched from `MCPLogChannel.logger(label:)` to a direct `Logger(label: "jarvis.mcp.spawngate")` — the only behavioral change, which preserves the existing log label.
- **Files modified:** `packages/MCP/Package.swift`, `packages/MCP/Sources/MCP/MCPClient.swift`, `packages/MCP/Sources/MCP/MCPServerHandle.swift`, `packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift` (renamed), `packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift` (`@testable import JarvisChildSpawn`).
- **Commit:** `9fc8d44 refactor(07-05): extract ChildSpawnGate into JarvisChildSpawn target (Rule 3 deviation)`
- **Validation:** All 3 ChildSpawnGate tests still pass; full MCP build clean; Vision can now depend on `JarvisChildSpawn` alone.

### [Rule 3 - Adaptation] FrameAttachDiscardSiteGrepTests grep target

- **Found during:** Task 6
- **Issue:** The plan body specified `grep -c 'discardFrame' packages/Vision/Sources/Vision/FrameAttachController.swift` returns exactly **1**. That semantic counts matching LINES; the function definition + every internal caller (cancel, timeout, onAssistantTurnComplete) all reference the name on separate lines, so a literal `grep -c` returns 7, not 1. The plan's stated `grep -c == 1` is unrealistic for any function with multiple internal callers.
- **Fix:** Adapted the test to enforce the actual single-emission-site invariant: `grep 'pendingFrame = nil'` returns exactly **1** (only the assignment inside `discardFrame()`), AND `func discardFrame` is present. This matches the spirit of Phase 6's TTSInterrupt single-emission-site gate (`\.ttsStopped` count == 1) where the gate counts the literal emission token, not all references to the surrounding API.
- **Validation:** Refactored `requestAttach`'s capture-failure path to call `discardFrame()` instead of inlining `pendingFrame = nil` — the failure path now also routes through the SOLE emission site, hardening the invariant.
- **Commit:** `aa31e75 feat(07-05): FrameAttachController + always-confirm gate + sole emission site (Task 6 GREEN)`

### [Rule 1 - Bug] Cancellation-aware timeout task

- **Found during:** Task 6 (test failure: `testConfirmProducesImageBlock` saw `.timeout` instead of `.send`)
- **Issue:** The original timeout `Task { try? await Task.sleep(...); await timeoutFired() }` swallowed the `CancellationError` thrown by `Task.sleep` after `pendingTimeoutTask?.cancel()` ran inside `confirmSend`. After `try?` ate the error, `timeoutFired()` was invoked anyway and overwrote `lastDecision = .send` with `.timeout`.
- **Fix:** Replaced the silent `try?` with explicit `do/catch` that returns early on cancellation, plus an extra `Task.isCancelled` guard. Cancellation now cleanly suppresses `.timeout` from firing.
- **Files modified:** `packages/Vision/Sources/Vision/FrameAttachController.swift`
- **Commit:** included in `aa31e75` (Task 6 GREEN).

## Authentication Gates

None — this plan touches no cloud surface at runtime. T3 wiring is structural only; the actual cloud egress is gated by `EscalationPhraseDetector.matchesCloudOptIn` and surfaces only in plan 07-06 (the integration closer).

## Forward-looking notes for plan 07-06 (integration closer)

The wiring contract for `AppDelegate.installVision()` and `Orchestrator.runTurn` to consume what this plan landed:

1. **AppDelegate construction sequence (suggested order):**
   - Build `VisionRouterConfig` (load tunables from `Config` package; default to `VisionRouterConfig.default`).
   - Construct `t1Provider = OllamaProvider(baseURL: ollamaURL, useOpenAICompat: false)` (Ollama native /api/chat).
   - Construct `t2Provider = VllmMlxProvider(baseURL: vllmMlxURL)`.
   - Construct `t3Provider = AnthropicProvider(...)` (the existing one Phase 4 owns).
   - Construct `VisionRouter(t1Provider:, t2Provider:, t3Provider:)`.
   - Construct `VllmMlxSidecar(configuration:)` with the user's chosen vllm-mlx binary path. **Do NOT call `start()`** — the lazy `ensureRunning()` lifecycle is intentional. The first T2 need triggers spawn.
   - Construct `FrameAttachController(captureSession: cameraCapture, replaySink: frameAttachReplaySink, config: visionRouterConfig)`.

2. **Bus → controller plumbing:**
   - The HUD camera-icon Bus message routes to `FrameAttachController.requestAttach(reason: .hudButton)`.
   - User-text inputs route through `ContextBuilder.matchesFrameAttachPhrase(text)`. When true, dispatch `requestAttach(reason: .phraseDetected(in: text))`.
   - The `[Send]` HUD button calls `confirmSend(userText:)`; the `[Cancel]` HUD button calls `cancel()`.

3. **Orchestrator wiring:**
   - `Orchestrator.runTurn` consumes `TurnInput.images` (already additive; existing code paths compile unchanged).
   - When `images` is non-empty, route through `VisionRouter.route(for:prompt:explicitCloudOptIn:)` where `explicitCloudOptIn = ContextBuilder.matchesCloudOptIn(prompt)`. Use the returned `provider` and `model`.
   - After the T1 stream completes, call `VisionRouter.evaluatePostResponse(t1ResponseText, config:, t2Available: VllmMlxAvailability.isAvailable(...))`. If `.escalateToT2`, re-issue `provider.stream(messages:images:...)` against the T2 provider with the same image — the user perceives "one frame in, one good answer out."
   - On `LLMEvent.messageStop`, call `frameAttachController.onAssistantTurnComplete()` to release the in-memory bytes (D-15 byte-release edge).

4. **FrameAttachReplaySink concrete implementation:**
   - 07-05 ships the protocol-driven sink. 07-06 should provide `MemoryReplaySink`-style adapter that conforms to `FrameAttachReplaySink.ReplayLogProtocol` and calls `await replayLog.record(.userInput(payload), for: turnId)`.
   - Mirror the predecessor 07-03 pattern (the SUMMARY for that plan describes `MemoryReplaySink` adapter wrapping `ReplayLog.record(_:for:)`).

5. **vllm-mlx binary discovery:**
   - First-run UX: surface a HUD banner if `VllmMlxAvailability.isAvailable(configuration:)` returns false AND the user's config requests T2. Do NOT silently downgrade — let the user opt out of T2 explicitly. Otherwise stays on T1 transparently.

6. **App-target build:**
   - 07-05 did NOT run `bash scripts/check-app-builds.sh` (heavy Xcode build is the orchestrator's responsibility). The orchestrator should re-run it after merging this branch back to develop. The new `JarvisChildSpawn` target may require a `project.yml` update if the App-target package edges are pinned by name (the App imports `JarvisMCP`, which transitively pulls `JarvisChildSpawn`, so SPM should resolve it without explicit declaration).

## Self-Check: PASSED

Verification of artifacts claimed:

```
FOUND: packages/AgentCore/Sources/AgentCore/ImageBlock.swift
FOUND: packages/Vision/Sources/Vision/VisionRouter.swift
FOUND: packages/Vision/Sources/Vision/FrameAttachController.swift
FOUND: packages/Vision/Sources/Vision/VllmMlxSidecar.swift
FOUND: packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift
FOUND: 13 commits in worktree (ff020d8..HEAD)
TESTS: 224 passing across AgentCore + Vision + Replay + MCP-ChildSpawnGate subset
GATES: all 4 phase-level grep gates pass
```
