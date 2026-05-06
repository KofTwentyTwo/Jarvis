# Phase 10: Self-Awareness & Live Diagnostics — Context

**Gathered:** 2026-05-06
**Mode:** `--auto` (single-pass; recommended option locked for every gray area)
**Status:** Ready for planning

<domain>
## Phase Boundary

Two-track delivery:

1. **Self-knowledge surface** — four read-only MCP tools (`list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices`) + a system-prompt preamble that names Jarvis, lists its capabilities, and instructs the model to call the introspection tools instead of giving generic "open System Settings" answers.
2. **Live diagnostics surface** — four UI/menu artifacts that prove subsystems are moving real bytes: a Voice Log AppKit window streaming voice subsystem events, a fix to make the existing DevOverlay actually populate during turns, an Audio Loopback menu item (mic→speaker, no inference), and a TTS Playback menu item (`AVSpeechSynthesizer` "Jarvis is online").

Closes the runtime-vs-tested gap that produced the 2026-05-05 / 2026-05-06 live-launch failures. Does NOT add new capabilities, modify the Bus schema, refactor `AppDelegate`, bring up Orpheus tier-2, bundle `vec0.dylib`, or pull Ollama models — those each remain separate phases.

</domain>

<spec_lock>
## Requirements (locked via SPEC.md)

**10 requirements are locked.** See `10-SPEC.md` for full requirements, boundaries, and acceptance criteria.

Downstream agents (`gsd-phase-researcher`, `gsd-planner`, `gsd-executor`) MUST read `10-SPEC.md` before planning or implementing. Requirements are not duplicated here.

**In scope (from SPEC.md):**
- Four new MCP tools: `list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices` (schemas + dispatchers + `MCPRuntimeWiring` registration)
- System-prompt preamble update via `ContextBuilder` (small locked string; does not touch presence enrichment or memory hydration)
- Voice Log window: AppKit window + menu item + `VoiceLogPublisher` actor + subscriber wiring across existing voice subsystems
- DevOverlay subscriber fix — read-only investigation first, minimum surgical change to make existing fields populate
- Audio loopback diagnostic menu item (uses existing `AudioGraphOwner` subscription pattern, no new tap)
- TTS playback diagnostic menu item (uses existing `TTSEngineActor` tier-1)
- Live-launch verification step embedded in EVERY plan (SPEC AC-13)

**Out of scope (from SPEC.md):**
- HUD camera button click → frame attached: covered by post-`b92d062` retest as a verification-only step, not a new requirement
- Tier-2 Orpheus TTS bring-up
- `vec0.dylib` bundling / live memory extraction (Track D-5/6/7)
- `AppDelegate.swift` split (2112 LOC P3 refactor)
- Bus schema changes (`BusOutbound` / `BusInbound`)
- Wizard TCC stage modifications

</spec_lock>

<decisions>
## Implementation Decisions

### Plan structure & sequence (serial, single-threaded)

- **D-01:** Phase 10 plans run **serially**, single-threaded. No parallel-agent fan-out anywhere inside Phase 10. *(Rationale: the parallel-agent failure mode is a recorded blocking anti-pattern in `.continue-here.md`.)*
- **D-02:** **5 plans expected** in this order, foundation → UI:
  1. `10-01-PLAN.md` — **MCP self-knowledge tools** (SELF-01..04). Pure read-only CoreAudio + AVCaptureDevice + Bundle/runtime introspection. Lowest risk; zero UI; verifies AC-01..04.
  2. `10-02-PLAN.md` — **System prompt preamble** (SELF-05, SELF-06). Depends on plan 1's tools so the model has something to call. Verifies AC-05/06 by relaunching and asking "what mic are you using?" and "are you a text-only assistant?".
  3. `10-03-PLAN.md` — **DevOverlay subscriber fix** (DIAG-02). Read-only investigation step (`packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift` + `DevOverlayViewModel.swift` + `AppDelegate.swift` wiring) followed by the minimum surgical diff. Verifies AC-08 — needed to actually verify Plans 1+2 anyway.
  4. `10-04-PLAN.md` — **Audio loopback + TTS playback diagnostics** (DIAG-03, DIAG-04). Two small menu items in `MenuBarContextMenu.swift`. Verifies AC-09/10.
  5. `10-05-PLAN.md` — **Voice Log window** (DIAG-01). Largest plan; subscriber wiring across the voice subsystems is the bulk of the work. Selectively salvages scaffolding from `stash@{0}`. Verifies AC-07.
- **D-03:** **5 plans, not 4 or 6.** SPEC said "4–6 expected"; 5 sits in band, keeps the foundation/UI split clean, and isolates the largest scope (DIAG-01) to its own plan so it doesn't contaminate the smaller diagnostics' verification.
- **D-04:** Each plan ends with a **"Live verification" section in its SUMMARY.md** containing: (a) the exact relaunch command run, (b) the observed log lines (timestamped), (c) whether the human acceptance criterion fired audibly/visibly. This is the operational form of SPEC AC-13. Tests-green is necessary but not sufficient.

### `stash@{0}` salvage policy

- **D-05:** Salvage **selectively per plan**, not wholesale. The stash contains 6 `packages/VoiceLog/` source files + 2 test files + edits to `AppDelegate.swift` / `MenuBarContextMenu.swift` / `project.yml` / `pbxproj`. Plan 10-05 (Voice Log) reviews those files file-by-file as scaffolding inputs. Plan 10-03 (DevOverlay) reviews `DevOverlayBroadcasterIntegrationTests.swift`. The stash entry itself is never `git stash apply`'d as a unit. Discard any salvaged file that doesn't compile clean and align with the SPEC requirements after review.
- **D-06:** Drop the stash only after **Plan 10-05 SUMMARY.md is committed** and any wanted scaffolding has been re-introduced under fresh commits. No stash drop before then.

### Self-knowledge tool implementation (Plan 10-01)

- **D-07:** All four tools follow the **`InProcessMemoryAdapters.swift` pattern from Track D-2 (`commit 707c45b`)** — adapter type per tool, registered via `InProcessToolRegistry` from `installAgent` (or the equivalent install path that owns the live AudioGraph / VoiceController / orchestrator).
- **D-08:** **CoreAudio queries are synchronous.** `AudioObjectGetPropertyData` is fast and the tool is invoked off the agent loop; no actor needed for the device list itself. `AVCaptureDevice.DiscoverySession` likewise. `get_active_audio_route` reads through the live `AudioGraphOwner` actor.
- **D-09:** **No caching of device lists.** Hardware can be unplugged between calls; freshness > performance. The cost is one syscall per `list_*_devices` invocation.
- **D-10:** **`requiresConfirmation: false`** for all four tools — read-only, no side effects. Explicitly set the flag (don't rely on default) to keep `scripts/check-applescript-confirmation.sh` semantics readable. Add coverage of the four tool registrations to the existing MCPRuntimeWiringTests (or a sibling test) so a regression that drops one shows up immediately.
- **D-11:** **`get_self_state` snapshots are point-in-time.** Read `Bundle.main.infoDictionary`, `ProcessInfo.processInfo.processIdentifier`, `ProcessInfo.processInfo.systemUptime` minus the launch instant captured at app start, the active `LLMProvider` identity, the most-recent `PerTurnSnapshot` (best-effort; nullable) and `VoiceController.state` (via `await voiceController.state`). No history; no streaming.

### System prompt preamble (Plan 10-02)

- **D-12:** Emit the preamble from `App/MCP/AppDelegateContextBuilderAdapter.swift` (or its `ContextBuilder` host in `packages/AgentCore`). Compose **before** presence enrichment — preamble is identity-stable, presence is per-turn. Two distinct concatenation steps; do not collapse them.
- **D-13:** Preamble is a **single locked string constant** in code (no JSON file, no localization). Include: identity ("You are Jarvis, an always-on macOS assistant…"), capability bullet list (mic, camera, speakers, MCP tool surface), and an explicit "always prefer your introspection tools over generic instructions" instruction (covers SELF-06).
- **D-14:** **No tool-list duplication in the preamble.** The Anthropic API tools array already provides the catalog; the preamble just nudges the model to call the introspection-class tools first. Keeps the preamble small (matters for cache eligibility — see `CacheHintsEligibilityTests`).

### DevOverlay fix (Plan 10-03)

- **D-15:** **Read-only investigation comes first.** The first commit in plan 10-03 is a written investigation note (in the plan's working directory or a code-comment block) explaining what's actually broken — broadcaster not subscribed, subscription torn down too early, `@Published` not driving the view, etc. The fix commit comes second. Skip the temptation to rewrite the broadcaster.
- **D-16:** **Minimum surgical change.** No DevOverlay refactor; no view-model restructure. Touch the smallest set of lines that makes AC-08 pass. If the investigation reveals the broadcaster is fine and the bug is upstream (e.g., `streamTruncatedFinal` was actually the cause and it's already fixed in `d8983af`), the plan still ships a verification-only commit + SUMMARY documenting the live re-test.

### Diagnostic menu items (Plan 10-04)

- **D-17:** Both menu items live in **`App/MenuBar/MenuBarContextMenu.swift`**, under a "Diagnostics" submenu. Keeps debug UI off the always-on HUD (per SPEC).
- **D-18:** **Audio loopback uses `AudioGraphOwner.subscribe()`** — same path Track B-7 introduced for multi-consumer fan-out — to read 2 s of audio without disturbing the wake-word DAG, then plays back via the existing `AVAudioEngine` output route. No new tap thread, no new ring buffer.
- **D-19:** **TTS playback uses `TTSEngineActor` tier-1 (`AVSpeechSynthesizer`)** with the fixed phrase "Jarvis is online". No tier-2 path. Single non-cancelable synthesis.

### Voice Log window (Plan 10-05)

- **D-20:** `VoiceLogPublisher` is an **actor** (Swift 6 strict concurrency; ARCHITECTURE concurrency cheat sheet). Subscribers are AsyncStream continuations registered via a serial actor method. Publish path is non-blocking (sub-µs append + per-subscriber send).
- **D-21:** **In-memory only**, capped at **2000 events** with FIFO eviction. SPEC says "in-memory only — never writes transcript content to OSLog" — that's the T-06-05-03 line. The earlier ROADMAP wording "persists across launches" is superseded by SPEC.md, which is authoritative.
- **D-22:** Event taxonomy (locked, not extensible inside this phase): `wakeWordFired`, `wakeWordPaused`, `wakeWordResumed`, `vadSpeechStart`, `vadSpeechEnd`, `sttPartial`, `sttFinal`, `ttsSynthesizeStart`, `ttsSynthesizeComplete`, `ttsCancelled`, `voiceStateTransition(from:to:)`, `audioLevelRMS(value:)` (rate-limited ≤1 Hz at the publish site, not the subscriber), `voiceError`. Transcript text is a `String` *value* on `sttPartial`/`sttFinal` — it is held in memory only, never logged.
- **D-23:** **AppKit window**, NOT WKWebView. Mirrors `DevOverlayWindow.swift`. Window position autosaved via standard `NSWindow.frameAutosaveName`. SwiftUI body inside an `NSHostingView` is fine; do not introduce a second webview content world (T-09-XX).
- **D-24:** RMS rate-limiting is **at the publisher side** (compute interval, drop intermediate samples). Subscribers always get monotonic, ≤1 Hz `audioLevelRMS` events. Don't push 16 kHz samples through actor hops.
- **D-25:** Wire-up paths: subscriber adapters live in `App/Voice/VoiceLogAdapters.swift` (the stash file may be partially correct — review before reuse). Each existing voice surface (`WakeWordDAG`, `VADGatedSession*`, `LiveSpeechAnalyzerBridge`, `TTSEngineActor`, `VoiceController`) gets a small `publisher.publish(.event(...))` callsite. No subsystem refactor — these are additive.

### Live-launch verification gate (cross-cutting)

- **D-26:** Each plan's **SUMMARY.md** has a `## Live Verification` section. Format:
  ```
  ### Relaunch
  - Command: `bash scripts/check-app-builds.sh && open build/.../Jarvis.app`
  - Build artifact: <path or commit hash>

  ### Observed
  - <timestamped log line 1>
  - <timestamped log line 2>
  - <human-observed: "I heard the phrase audibly within 1.5s of clicking">

  ### Acceptance match
  - AC-XX: PASS / FAIL — <evidence>
  ```
- **D-27:** **Tests-green is necessary but not sufficient.** A plan that ships passing tests without the Live Verification section fails `/gsd-verify-phase 10`. The verifier reads each `SUMMARY.md` and rejects on missing sections.
- **D-28:** **TCC re-prompt protocol** when verifying any plan that touches mic/camera/audio: run `tccutil reset Microphone com.koftwentytwo.jarvis` and/or `tccutil reset Camera com.koftwentytwo.jarvis` once before the relaunch verification, so the verification proves the explicit-`requestAccess` path actually fires. Document the reset command + observed prompt in the Live Verification section.

### Boundary-gate discipline

- **D-29:** All **18 existing boundary gates** stay green at every plan boundary. New work adds gate coverage rather than weakening existing gates. Specifically: any new MCP tool registration MUST not regress `scripts/check-applescript-confirmation.sh`; any change to `AppDelegate.swift` MUST not regress `scripts/check-no-leftover-stubs.sh` or `scripts/check-install-order.sh`; any change to AudioGraph wiring MUST not regress `scripts/check-no-null-voice-adapters.sh`.
- **D-30:** **No new boundary gate is required** for Phase 10. The `tests-green ≠ production-works` enforcement is procedural (D-26/D-27 SUMMARY format) not gate-based — gating would require executing the app from CI, which is out of scope for this codebase's build infrastructure.

### Naming + test-double conventions

- **D-31:** Test doubles for new code follow CLAUDE.md §"Test naming conventions" (Mock = records-and-scripts; Stub = canned-data; Fake = realistic-stateful). New code added in Phase 10 ships with the right name from day one — do not import the older naming-mismatch corpus.

### Claude's Discretion

- Specific event payload fields on `voiceStateTransition` and `voiceError` (struct shapes are Claude's choice as long as they're `Sendable`, `Equatable`, and easy to render in the Voice Log view).
- Whether `get_self_state` includes a `git_commit` short-sha string (nice-to-have; include if cheap, otherwise skip).
- Whether the audio loopback diagnostic shows a small "Recording…" / "Playing back…" status overlay or stays headless — if a status hint comes for free via the menu item title, fine; if it requires new HUD surface area, skip.
- Filter UI specifics in the Voice Log window (checkbox group vs segmented control). Pick the simplest AppKit idiom.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase locks (must read first, in order)

- `.planning/phases/10-self-awareness-diagnostics/10-SPEC.md` — Locked requirements (10), boundaries, constraints, acceptance criteria (14). Authoritative WHAT.
- `.planning/phases/10-self-awareness-diagnostics/.continue-here.md` — Three blocking anti-patterns + critical anti-patterns table. Acknowledge before any code work.

### Project-wide locks

- `CLAUDE.md` (root) — Architectural decisions, voice/vision/memory stack pins, Opus 4.7 footguns, MCP SDK version, test naming taxonomy, prompt-injection notes.
- `.planning/PROJECT.md` — Active requirements, decision log.
- `.planning/REQUIREMENTS.md` — REQ-IDs (SELF-01..06, DIAG-01..04 entries).
- `.planning/STATE.md` — Milestone-level status, locked decisions table, scaffold-time verifications.
- `.planning/research/RESEARCH-DELTAS.md` — Authoritative on conflicts with base research (Opus 4.7 model id, Qwen3 disabled, Orpheus streaming, Silero v6.2.1, MCP SDK).

### Architecture & subsystem deep-dives

- `ARCHITECTURE.md` — Audio-graph fan-out, agent loop, bus topology, MCP runtime, package boundaries, anti-pattern list.
- `CONTRIBUTING.md` — Boundary-gate discipline, conventional-commit conventions, test-double taxonomy, anti-pattern checklist, "adding an MCP tool" walkthrough.
- `packages/Voice/README.md` — Voice subsystem invariants, T-06-05-03, VOICE-14 single-call-site rule, AudioGraphOwner topology.
- `packages/MCP/README.md` — Tool registration patterns, in-process adapter pattern from Track D-2.
- `packages/DevOverlay/README.md` — Existing subscriber pattern + view-model topology.

### Track D-2 reference implementation (closest analog for new MCP tools)

- `App/MCP/InProcessMemoryAdapters.swift` (commit `707c45b`) — Bridge pattern for adapting actors to MCP tool dispatchers. The four self-knowledge tools follow this shape.
- `App/MCP/MCPRuntimeWiring.swift` — Where the new tools register; current registrants pattern-match here.

### Live-launch evidence (the "why" of this phase)

- `git log --oneline d8983af cb7ee6f b92d062 c8e37ab` — Read each commit body. Documents the live-launch debugging story that produced this phase.
- `.planning/audit-2026-05-04/SYNTHESIS.md` — Six-auditor view of why "structurally sound" wasn't enough.
- `.planning/audit-2026-05-03/SYNTHESIS.md` — Earlier audit; "wired but dead" pattern across modalities.
- `docs/SESSION-STATE.md` — 2026-05-06 commit ledger; observed runtime state.

### Boundary gates (must pass at every plan boundary)

- `scripts/check-app-builds.sh` (App target compiles)
- `scripts/check-applescript-confirmation.sh` (read-only tools must not break the confirmation gate)
- `scripts/check-no-leftover-stubs.sh` (no stub-marker rot)
- `scripts/check-install-order.sh` (install cascade order preserved)
- `scripts/check-no-null-voice-adapters.sh` (no `Null*Adapter` resurrection)
- 13 other gates listed in CLAUDE.md "Boundary gates" section

### Stash for selective salvage

- `stash@{0}` — `partial-work-from-failed-parallel-dispatch-2026-05-06`. Files: `App/AppDelegate.swift`, `App/MenuBar/MenuBarContextMenu.swift`, `App/Voice/VoiceLogAdapters.swift`, `packages/VoiceLog/{Package.swift,Sources/VoiceLog/{VoiceLogBridge,VoiceLogEvent,VoiceLogPublisher,VoiceLogView,VoiceLogViewModel,VoiceLogWindow}.swift,Tests/VoiceLogTests/{VoiceLogPublisherTests,VoiceLogViewModelTests}.swift}`, `Jarvis.xcodeproj/project.pbxproj`, `project.yml`, plus `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` and `packages/Vision/Tests/VisionTests/CameraButtonTCCWiringTests.swift`. Reviewed file-by-file in plans 10-03 and 10-05.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- **`InProcessMemoryAdapters.swift` (Track D-2)** — Closest pattern for the four self-knowledge MCP tools. Adapter wraps an actor or other source-of-truth, exposes the MCP tool dispatcher protocol, registered via `InProcessToolRegistry` in the install path.
- **`AudioGraphOwner.subscribe()` (Track B-7)** — `BufferBroadcaster` fan-out lets the audio loopback diagnostic tap audio without colliding with the wake-word DAG. Same path the chunk pump uses today; reuse, do not introduce a new tap.
- **`TTSEngineActor.tier1` (`AVSpeechSynthesizer`)** — Already constructed in `App/Voice/VoiceOutputWiring.swift`. The TTS playback diagnostic just calls `synthesize("Jarvis is online")` and awaits completion.
- **`DevOverlayBridge` + `DevOverlayViewModel`** — Existing subscriber+view-model topology. The fix is upstream (subscriber wiring or per-event broadcaster), not a redesign.
- **`MenuBarContextMenu.swift`** — Already hosts the menu structure. Diagnostics submenu adds two `NSMenuItem`s; no new infrastructure.
- **`AppDelegateContextBuilderAdapter.swift`** — Where the system-prompt preamble lands. Existing presence enrichment runs after; preamble runs before.

### Established Patterns

- **In-process MCP tool adapter** — actor or other source → adapter type → register in `InProcessToolRegistry`. New tool is roughly 30–80 LOC + tests.
- **Subscriber fan-out via broadcaster** — `BufferBroadcaster` for audio, `OutboundBatcher` for bus events, similar shape for `VoiceLogPublisher` (actor + `AsyncStream` continuations).
- **Cap-recovery `toolChoice: .none` discipline** — Phase 4 invariant; new tools must respect it (irrelevant for read-only queries but the discipline applies).
- **Voice transcript handling** — T-06-05-03 (no PCM, no transcripts to `OSLog`). Voice Log holds transcript content in-process only; tests assert no `Logger.log` / `os.log` calls path through transcript-bearing surfaces.
- **AppKit window pattern (DevOverlay)** — `NSHostingView` for SwiftUI body, `NSWindow.frameAutosaveName` for position persistence. Voice Log mirrors this; no second webview content world.
- **Boundary-gate discipline** — Each plan ends with `bash scripts/check-app-builds.sh` plus the relevant grep gates. Per-plan SUMMARY records gate output.

### Integration Points

- New MCP tools register from the install path that owns the live runtime references (`AudioGraphOwner`, `VoiceController`, `LLMProvider`, `Bundle.main`). Likely `installAgent` (which already constructs the runtime) or a small new `installSelfKnowledge` invoked after `installVoice` and `installAgent` so the AudioGraph reference exists.
- `ContextBuilder` preamble emit point is in `AppDelegateContextBuilderAdapter.systemPrompt(for:)` (or equivalent — confirm in plan 10-02 research). Hooks into Anthropic's `system` array as a separate cache-eligible block to maximize reuse.
- DevOverlay's broadcaster subscriber ties into the existing `agentOrchestratorEvents()` channel (Phase 9). Do not introduce a parallel bus.
- Voice Log subscribers attach at install time inside `installVoice` / `installAgent` after the publisher exists; teardown is via the existing `shutdown()` cascade.
- Diagnostic menu items live in `MenuBarContextMenu.makeMenu(...)`; their action closures hold weak references to `AudioGraphOwner` / `TTSEngineActor` to avoid retain cycles in the menu bar item.

</code_context>

<specifics>
## Specific Ideas

- **Concrete user-quoted failure modes** to make impossible:
  - "I'm Jarvis, your text-based assistant — I don't actually have a microphone." (2026-05-05)
  - "I don't have the ability to detect your hardware directly." (2026-05-05)
  - DevOverlay fields all empty / zero. (2026-05-05)
  - Voice Log window empty even with active wake-word DAG. (2026-05-06)
  - HUD camera button click did nothing (TCC) — verification only, not a Phase 10 requirement.

- **Live-launch evidence format** (D-26) — copy verbatim into each SUMMARY.md so reviewers know what to look for.

- **Stashed scaffolding map** (D-05) — Plan 10-05 inspects `packages/VoiceLog/` files in this order: `VoiceLogEvent.swift` (event taxonomy — must match D-22), `VoiceLogPublisher.swift` (actor pattern — keep if matches D-20), `VoiceLogViewModel.swift` (subscriber + cap policy — keep if matches D-21/D-24), `VoiceLogView.swift` (SwiftUI body — fine to keep), `VoiceLogWindow.swift` (window scaffolding — keep), `VoiceLogBridge.swift` (verify it does not introduce a webview surface — discard if it does). Plan 10-03 inspects `DevOverlayBroadcasterIntegrationTests.swift` for fixture reuse.

</specifics>

<deferred>
## Deferred Ideas

- **Tier-2 Orpheus TTS bring-up** — separate phase; depends on ~6 GB weight download + empirical TTFA measurement.
- **`vec0.dylib` bundling + Ollama model pulls (Track D-5/D-6/D-7)** — user-environment work; carry-forward from v0.12.0.
- **`AppDelegate.swift` split refactor** — flagged as P3 in 2026-05-04 audit; separate phase.
- **Bus schema widening** — explicitly out of scope; if a future requirement needs it, scope a dedicated phase first.
- **Voice Log persistence across launches** — SPEC chose in-memory only; persisting voice events would invite leaking transcript content to disk and conflicts with T-06-05-03. If demand returns, scope as a separate phase with explicit privacy review.
- **HUD-surfaced diagnostics** (audio loopback / TTS playback as buttons in the hologram) — explicitly chose menu items per SPEC; HUD is the always-on cinematic surface, debug controls don't belong there.
- **A "Memory Log" companion to the Voice Log** — interesting symmetry, but not in this phase's scope; Track D environment work has to land first.
- **Self-state historical timeline / event log** — SPEC chose point-in-time snapshots; historical view would be a separate diagnostics phase.
- **Camera Log window** — symmetric with Voice Log but no recorded need; deferred until/unless a vision live-launch failure motivates it.

### Reviewed Todos (not folded)

None — `gsd-sdk query todo.match-phase 10` returned 0 matches.

</deferred>

---

*Phase: 10-self-awareness-diagnostics*
*Context gathered: 2026-05-06*
*Mode: --auto (single-pass; recommended option locked for every gray area)*
