# Phase 10: Self-Awareness & Live Diagnostics — Specification

**Created:** 2026-05-06
**Ambiguity score:** 0.18 (gate: ≤ 0.20)
**Requirements:** 10 locked

## Goal

Jarvis answers factual questions about its own runtime state and the host hardware via dedicated MCP tools, embeds that self-knowledge in its system prompt so the model never claims it is "text-only," and surfaces four diagnostic UI panels (Voice Log window, populated DevOverlay, audio loopback diagnostic, TTS playback diagnostic) that prove each subsystem is moving real bytes — not just structurally wired.

## Background

Live launch on 2026-05-05 / 2026-05-06 surfaced a class of bugs that every prior audit and test pass missed: structural wiring was correct but production paths were dead. Specific evidence:

- **2026-05-05** — User asked "what mic are you using?" Jarvis answered "I don't have the ability to detect your hardware directly." Live runtime, AVAudioEngine bound to the user's mic, but the agent had no introspection tool and the system prompt did not list available capabilities.
- **2026-05-05** — User asked "what mic and speakers are you using?" Jarvis: "I'm Jarvis, your text-based assistant — I don't actually have a microphone or any audio hardware." This is wildly false; the app was actively running the wake-word DAG against the mic stream at the moment.
- **2026-05-06** — `tccd` log proved the OS mic permission prompt never fired before today's `b92d062` fix because no production code called `AVCaptureDevice.requestAccess(for:)`. The wizard's TCC stage explicitly said "later" but the "later" code was never written. Mic delivered silence; no wake-word ever fired despite the DAG looking healthy in logs.
- **2026-05-05** — DevOverlay window opened but every field showed empty/zero state (`Provider: /`, `Input: 0 tok`, etc.). Subscriber existed but received no events because no turns were completing (separate `streamTruncatedFinal` bug, fixed in `d8983af`).
- **2026-05-06** — User opened Voice Log window (uncommitted partial work from a failed agent dispatch); window rendered but was always empty because no voice subsystem actually surfaced events to it.
- **2026-05-06** — User clicked HUD camera button: nothing happened. Camera TCC was never granted (separate from but related to the mic gap above). Today's `b92d062` adds the camera permission request; this phase verifies the click flow end-to-end after the prompt.

The thread connecting all of these: **production code paths that are observably correct in unit tests but inert at runtime.** The fix is two-track: (1) make Jarvis self-aware so wrong answers like "I don't have a microphone" become impossible by construction, and (2) add live diagnostic surfaces so subsystem failures are visible without speaking the magic words at the right moment.

The runtime bugs that surfaced this list (`stream: true`, mic-regrant phantom rebuild, missing `requestAccess`) were fixed tactically in `d8983af` / `cb7ee6f` / `b92d062`. This phase is the structural follow-up.

## Requirements

1. **SELF-01: Audio device introspection MCP tool**
   - Current: No tool exposes audio hardware. Jarvis tells users to open System Settings.
   - Target: A `list_audio_devices` MCP tool returns inputs + outputs with `name`, `uid`, `isDefault`, `isActive`, `sampleRate`, `channels`. Implementation queries CoreAudio `AudioObjectGetPropertyData` for `kAudioHardwarePropertyDevices`.
   - Acceptance: Tool registered in `MCPRuntimeWiring`; calling it returns at least one input + one output entry on the test machine; the entries match what `system_profiler SPAudioDataType` reports for the same machine.

2. **SELF-02: Active audio route MCP tool**
   - Current: No tool exposes which mic+speaker the running AudioGraph is bound to.
   - Target: A `get_active_audio_route` tool returns the device UID + name for the currently-bound mic input and speaker output, plus the probed sample rate / channel count actually in use.
   - Acceptance: Tool returns a non-nil result while voice loop is active; result matches the values logged at `AudioGraph: probed format sampleRate=X channels=Y`.

3. **SELF-03: Self-state MCP tool**
   - Current: No tool exposes Jarvis's own model, voice config, feature flags, build version.
   - Target: A `get_self_state` tool returns: `app_name`, `app_version`, `build_mode` (Debug/Release), `pid`, `uptime_seconds`, `llm_provider` (anthropic/ollama), `llm_model` (e.g., `claude-opus-4-7`), `tts_tier`, `stt_backend`, `wake_word_muted` flag, `voice_loop_state` (idle/listening/thinking/speaking).
   - Acceptance: Tool returns a populated struct; values cross-check against `Bundle.main.infoDictionary`, the active `LaunchSnapshot` / `PerTurnSnapshot`, and the `VoiceController.state`.

4. **SELF-04: Camera device introspection MCP tool**
   - Current: No tool exposes camera hardware.
   - Target: A `list_camera_devices` tool returns each `AVCaptureDevice` with `localizedName`, `uniqueID`, `isConnected`, `position` (front/back/external).
   - Acceptance: Tool returns at least the built-in FaceTime camera entry on the test machine; entries match `system_profiler SPCameraDataType`.

5. **SELF-05: Self-aware system prompt**
   - Current: System prompt does not tell the model it is Jarvis-on-macOS or list its tool surface. Model defaults to "I'm a text-based assistant."
   - Target: System prompt embeds a stable preamble with: identity ("You are Jarvis, an always-on macOS assistant running as a Swift app on the user's Mac"), capability summary (mic, camera, speakers, MCP tools), and an explicit instruction to USE the introspection tools rather than directing the user to System Settings.
   - Acceptance: After the prompt change, asking "what mic are you using?" produces a tool call to `get_active_audio_route` (visible in DevOverlay's tool calls list) and a factual answer naming the device. Asking "are you a text-only assistant?" produces a denial citing voice + vision.

6. **SELF-06: Tool catalog visibility**
   - Current: The model is given the tool list per the Anthropic API tools array, but the system prompt doesn't reinforce that introspection tools should be preferred over generic answers.
   - Target: Prompt preamble includes a line like "Always prefer calling your introspection tools (list_audio_devices, get_active_audio_route, get_self_state, list_camera_devices) over giving generic instructions."
   - Acceptance: A turn that asks an introspectable question routes to the tool, not generic advice — verified by tool-call appearing in DevOverlay's last-5-tool-calls list.

7. **DIAG-01: Voice Log window**
   - Current: Uncommitted partial work from a failed agent dispatch left a `packages/VoiceLog/` package in stash but the running window is always empty (subscriber never wired).
   - Target: An AppKit window opened from the menu bar that streams every voice subsystem event in chronological order: wake-word fires/pauses/resumes, VAD `.speechStart`/`.speechEnd` decisions, STT partial+final transcripts, TTS synthesize start/complete/cancel, `VoiceState` transitions, audio-level RMS at ≤1 Hz, voice errors. Includes pause/resume, clear, copy-to-clipboard, category filters, autosaved window position. In-memory only — never writes transcript content to OSLog (T-06-05-03).
   - Acceptance: Open the window, say "Hey Jarvis, what time is it?" and observe at minimum: wake-word fired entry; VAD speech-start; ≥1 STT partial; STT final with the words; orchestrator submit; tool call to `get_time`; orchestrator turn-end; TTS synthesize start with the response; TTS complete. All within 10 seconds, all timestamped.

8. **DIAG-02: DevOverlay populates during turns**
   - Current: DevOverlay window opens but all fields stay zero because the subscriber wiring is broken (or because no turns ever completed pre-`d8983af`).
   - Target: During an active turn the DevOverlay updates: `Provider: anthropic`, `Model: claude-opus-4-7`, `Input: N tok`, `Output: N tok`, `Cache creation: N tok`, `Cache read: N tok (X% hit)`, `Latency: ttfb=Nms total=Nms`, last 5 tool calls populated with name + duration. Updates within 100ms of each broadcaster event.
   - Acceptance: Send a turn that calls `get_time`. Within 100ms of `.turnEnded`, all six fields update with non-zero values; the tool call appears in the last-5 list with its actual duration.

9. **DIAG-03: Audio loopback diagnostic**
   - Current: No way to verify mic input → speaker output works end-to-end without depending on wake-word + STT + LLM + TTS.
   - Target: Menu item "Audio Loopback Test" that records 2 seconds from the active mic, plays it back through the active speaker. Pure I/O verification — no inference of any kind.
   - Acceptance: Click menu item, speak audibly during the 2s window, hear yourself within 1s of the recording window ending. If silent, the mic permission isn't actually taking effect even if TCC says granted.

10. **DIAG-04: TTS playback diagnostic**
    - Current: No way to verify the speaker route works without depending on a complete agent turn.
    - Target: Menu item "Speak Test Phrase" that calls `AVSpeechSynthesizer` (tier-1 TTS) with a fixed string ("Jarvis is online") on the active speaker.
    - Acceptance: Click menu item, hear the phrase audibly within 2s. If silent, the TTS engine or speaker route is misconfigured even though no error appears in logs.

## Boundaries

**In scope:**
- Four new MCP tools: `list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices` — including their tool schemas, dispatchers, and registration in `MCPRuntimeWiring`
- System-prompt preamble update (a small, locked string emitted by `ContextBuilder` — does not modify presence enrichment or memory hydration logic)
- Voice Log window (AppKit window + menu item + `VoiceLogPublisher` actor + subscriber wiring across the existing voice subsystems)
- DevOverlay subscriber fix — read-only investigation + the minimum surgical change to make existing fields populate
- Audio loopback diagnostic menu item (uses existing `AudioGraphOwner` subscription pattern, no new tap)
- TTS playback diagnostic menu item (uses existing `TTSEngineActor` tier-1)
- Live-launch verification step embedded in EVERY plan: each plan ends with a documented relaunch + observed-behavior log capture, not just unit tests

**Out of scope:**
- Camera button click → frame attached: covered by post-`b92d062` retest as a verification-only step, not a new requirement (TCC was the upstream cause)
- Tier-2 Orpheus TTS bring-up — depends on ~6GB weight download, separate phase
- vec0.dylib bundling / live memory extraction — Track D-5/6/7 user-environment work, separate from this phase
- AppDelegate.swift split (2112 LOC refactor) — flagged in 2026-05-04 audit as P3, separate phase
- Anything that requires modifying the Bus schema (`BusOutbound`, `BusInbound`) — out of scope; if a new bus event is genuinely required it gets re-scoped to a follow-up
- Replacing the existing wizard TCC stage — already updated to honest copy in `b92d062`; no further wizard work

**Reasons for excluding:**
- Bus schema is a stable contract per `ARCHITECTURE.md`; widening it without a separate phase invites the same multi-agent conflicts that produced today's chaos
- Track D and B-8 require user environment changes; a phase that depends on user actions can't gate "done"
- Camera click being a verification (not a requirement) reflects that today's b92d062 already did the work; this phase confirms

## Constraints

- **Swift 6 strict concurrency** — all new code must compile under Swift 6 mode. NSLock from async contexts is forbidden — use OSAllocatedUnfairLock or actors.
- **T-06-05-03** — voice transcript text NEVER passes to `OSLog` / `Logger` / `os.log`. The Voice Log window may DISPLAY transcripts in-process but must not write them to any persisted log channel.
- **VOICE-14** — the single `cancelAndSubmit` call site discipline must hold. Don't add a second.
- **MCP confirmation policy** — none of the new self-knowledge tools require user confirmation (read-only, no side effects), but they MUST register correctly with the MCP runtime such that the existing `requiresConfirmation: true` audit gate still passes.
- **Boundary gates** — all 18 existing `scripts/check-*.sh` gates must remain green. The `check-no-leftover-stubs.sh` linter from 2026-05-04 must catch any stub-marker rot introduced.
- **No fan-out under voice-tap thread** — the Voice Log publisher cannot run inference, allocate large buffers, or do anything that could block on the Core Audio tap thread. RMS sample updates must be rate-limited (≤1 Hz).
- **Build + test discipline** — every plan ends with `bash scripts/check-app-builds.sh` PASS, all 6 boundary gates PASS, AND a documented relaunch + observed-log capture. This is the new gate that prevents the 2026-05-05/06 class of regressions.
- **No new docs files outside the standard set** — all new documentation lives in code-level docstrings, the existing `ARCHITECTURE.md`, and the per-plan SUMMARY.md files emitted by execute-phase.

## Acceptance Criteria

- [ ] AC-01: `list_audio_devices` MCP tool registered, returns ≥1 input and ≥1 output, entries cross-validated against `system_profiler SPAudioDataType`
- [ ] AC-02: `get_active_audio_route` returns non-nil while voice loop is active and matches the format probe log line
- [ ] AC-03: `get_self_state` returns app_version + pid + uptime + llm_model + voice_loop_state, all populated
- [ ] AC-04: `list_camera_devices` returns the built-in FaceTime camera, cross-validated against `system_profiler SPCameraDataType`
- [ ] AC-05: After prompt update, "what mic are you using?" produces a `get_active_audio_route` tool call (verified in DevOverlay) and an answer naming the device
- [ ] AC-06: After prompt update, "are you a text-only assistant?" produces a denial citing voice + vision capabilities
- [ ] AC-07: Voice Log window opens via menu, populates with a wake-word fire + VAD speech-start + STT final + tool call + TTS synthesize entries within 10s of "Hey Jarvis, what time is it?"
- [ ] AC-08: DevOverlay populates Provider/Model/tokens/cache/latency/tool-calls within 100ms of `.turnEnded`
- [ ] AC-09: Audio Loopback diagnostic menu item records 2s and plays back audibly
- [ ] AC-10: TTS Playback diagnostic menu item speaks "Jarvis is online" audibly within 2s of click
- [ ] AC-11: All 18 boundary gates green at HEAD
- [ ] AC-12: `bash scripts/check-app-builds.sh` PASS at HEAD
- [ ] AC-13: Each plan's SUMMARY.md includes a "Live verification" section with the relaunch evidence
- [ ] AC-14: No new failures in `swift test --package-path packages/Voice`, `packages/Vision`, `packages/Memory`, `packages/AgentCore`, `packages/MCP`

## Ambiguity Report

| Dimension          | Score | Min  | Status | Notes                                                  |
|--------------------|-------|------|--------|--------------------------------------------------------|
| Goal Clarity       | 0.85  | 0.75 | ✓      | Two-track goal (self-knowledge + diagnostics) is precise |
| Boundary Clarity   | 0.80  | 0.70 | ✓      | In/out lists explicit; reasoning attached               |
| Constraint Clarity | 0.75  | 0.65 | ✓      | Project conventions documented; rate-limit specified    |
| Acceptance Criteria| 0.85  | 0.70 | ✓      | 14 pass/fail checkboxes, each verifiable                |
| **Ambiguity**      | 0.18  | ≤0.20| ✓      | Gate passed                                             |

Status: ✓ = met minimum, ⚠ = below minimum (planner treats as assumption)

## Interview Log

| Round | Perspective | Question summary | Decision locked |
|-------|-------------|------------------|-----------------|
| —     | auto-mode   | (skipped — initial scoring passed gate) | All requirements derived from 2026-05-05/06 live-launch evidence + user direction in conversation: "Jarvis should know 100% about itself" / "voice log empty" / "DevOverlay zeros" / "never asks permission" / "never makes sounds." |

Auto-selected decisions:

- **Voice Log window scope:** chose AppKit (not webview) to avoid widening webview's content world / WKContentWorld discipline. Mirrors DevOverlay's pattern.
- **Self-knowledge tools as MCP, not bus:** chose MCP because tools are how the model already calls into Jarvis; bus would require schema changes (out of scope).
- **Diagnostic menu items, not buttons in HUD:** chose menu items to avoid widening the HUD bus surface area; debug-class UI doesn't belong in the always-on hologram.
- **Camera button click as verification, not requirement:** today's `b92d062` already added camera TCC; this phase confirms via live test rather than re-fixing.
- **Live-launch verification baked into every plan:** the lesson from 2026-05-04..06 — agents shipping passing tests for inert production paths. New gate: every plan ends with documented relaunch + observed log capture.

---

*Phase: 10-self-awareness-diagnostics*
*Spec created: 2026-05-06*
*Next step: /gsd-discuss-phase 10 — implementation decisions (how to build what's specified above)*
