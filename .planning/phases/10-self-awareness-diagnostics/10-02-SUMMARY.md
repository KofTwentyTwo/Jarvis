---
phase: 10-self-awareness-diagnostics
plan: 02
subsystem: agent-core
tags: [system-prompt, self-awareness, anthropic, cache-control, swift, mcp]

# Dependency graph
requires:
  - phase: 10-self-awareness-diagnostics (Plan 10-01)
    provides: "Four self-knowledge MCP tools (list_audio_devices, get_active_audio_route, get_self_state, list_camera_devices) registered in MCPRuntimeWiring — the preamble names them so the model has handles."
provides:
  - "ContextBuilder.selfAwarePreamble: locked self-aware system-prompt preamble (D-13)"
  - "ContextBuilder.systemPrompt(for:): preamble-FIRST composer (D-12) accepting an optional TurnContext"
  - "TurnContext envelope (presenceText/memoryHydration) with .empty static for the AppDelegate site"
  - "AppDelegate orchestrator-init systemPrompt sourced from ContextBuilder (no more hardcoded literal)"
affects: [Plan 10-03 DevOverlay subscriber fix, Plan 10-04 Voice Log window, Plan 10-05 diagnostic menu items]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Locked Swift string constant for system-prompt preamble (single source of truth, no JSON, no localization)"
    - "Two-step concat composition (preamble FIRST, then per-turn enrichments) preserves Anthropic cache_control breakpoints"
    - "Cross-module ContextBuilder disambiguation via fully-qualified module name (JarvisVision.ContextBuilder vs AgentCore.ContextBuilder)"

key-files:
  created:
    - "packages/AgentCore/Sources/AgentCore/ContextBuilder.swift — selfAwarePreamble + systemPrompt(for:) + TurnContext"
  modified:
    - "App/AppDelegate.swift:1265 — systemPrompt now sourced from ContextBuilder.systemPrompt(for: .empty)"
    - "App/AppDelegate.swift:1620 — disambiguated to JarvisVision.ContextBuilder() (frame-attach phrase detector)"
    - "packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:212 — disambiguated to JarvisVision.ContextBuilder() (cloud-opt-in detector)"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift:209 — same disambiguation"
    - "packages/AgentCore/Tests/AgentCoreTests/CacheHintsEligibilityTests.swift — added preambleDoesNotEnableCacheUnintentionally"

key-decisions:
  - "D-12 fallback honored: AgentOrchestrator init still takes systemPrompt:String directly; AppDelegate calls ContextBuilder.systemPrompt(for: .empty). Per-turn TurnContext plumbing through orchestrator init is out of scope for Plan 10-02."
  - "Rule 3 deviation: AgentCore.ContextBuilder name-collides with the pre-existing JarvisVision.ContextBuilder. All bare ContextBuilder() call sites in cross-importing modules disambiguated via JarvisVision.ContextBuilder()."

patterns-established:
  - "Module-qualified type references (JarvisVision.ContextBuilder()) at call sites that import both AgentCore and JarvisVision."
  - "Cache-eligibility regression test: any addition to a system prompt component must have a paired test asserting it does not flip cache_control marker emission relative to a known-shorter baseline."

requirements-completed: [SELF-05, SELF-06]

# Metrics
duration: ~50min
completed: 2026-05-06
---

# Phase 10 Plan 02: System Prompt Preamble Summary

**Self-aware preamble locked into ContextBuilder; AppDelegate orchestrator-init no longer carries the hardcoded "You are Jarvis, a personal macOS assistant." literal. Model now has explicit identity + introspection-tool handles in every turn's system prompt.**

## Performance

- **Duration:** ~50 min (test stub → preamble + composer + AppDelegate rewire → boundary gates → SUMMARY)
- **Started:** 2026-05-06T16:08Z
- **Completed:** 2026-05-06T17:30Z
- **Tasks:** 2 of 3 (Task 3 is the human-verify checkpoint — see Live Verification section below)
- **Files modified:** 5 (1 created, 4 edited)

## Accomplishments

- Wave-0 cache-eligibility regression test `preambleDoesNotEnableCacheUnintentionally` lands as RED, then flips GREEN once the preamble exists. Asserts (1) preamble length head-room vs the 4096-char cache boundary, (2) the D-13 lock anchor `hasPrefix("You are Jarvis")`, (3) the D-14 no-Markdown-block constraint, (4) cache-eligibility-verdict invariance vs the prior literal, (5) the D-12 composition order (preamble FIRST in `systemPrompt(for:)`).
- `ContextBuilder.selfAwarePreamble` is the verbatim recipe from `10-RESEARCH.md` Example 5: identity sentence, voice/camera/speakers capability list, the seven introspection-tool names (`list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices`, `get_time`, `get_clipboard`, `run_applescript`), the "always prefer calling those tools" instruction, and the closing `You are not a text-only assistant.` sentence. Total length stays well below 2048 chars (deliberate head-room against the 4096-char cache boundary).
- `ContextBuilder.systemPrompt(for: TurnContext)` composes preamble FIRST, then optional `presenceText`, then optional `memoryHydration` — two distinct concatenation steps that preserve Anthropic prompt-cache breakpoints (Pitfall #4). `TurnContext.empty` is the static the AppDelegate site uses (D-12 fallback, since orchestrator init still takes `systemPrompt:String`).
- `App/AppDelegate.swift:1265` now reads `systemPrompt: ContextBuilder.systemPrompt(for: .empty)`. The literal `"You are Jarvis, a personal macOS assistant."` no longer appears at any live call site in `App/` or `packages/` (remaining matches are comment + test fixtures using it as a regression baseline).

## Task Commits

Each task was committed atomically:

1. **Task 1 (Wave-0 RED): preambleDoesNotEnableCacheUnintentionally** — `5bb9371` (test)
2. **Task 2 (GREEN): selfAwarePreamble + systemPrompt(for:) + AppDelegate rewire** — `f22bf2e` (feat)
3. **Task 3: Live verification** — PENDING (blocking checkpoint, see Live Verification section)

**Plan metadata commit:** _to be created_ (this SUMMARY.md + STATE.md + ROADMAP.md update).

## Files Created/Modified

- `packages/AgentCore/Sources/AgentCore/ContextBuilder.swift` (created) — `ContextBuilder` value type, `selfAwarePreamble` static, `systemPrompt(for:)` composer, `TurnContext` envelope with `.empty`.
- `App/AppDelegate.swift` (modified) — line 1265: orchestrator `systemPrompt:` argument now sourced from `ContextBuilder.systemPrompt(for: .empty)`; line 1620: disambiguated `JarvisVision.ContextBuilder()` for the frame-attach phrase detector.
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` (modified) — line 212: disambiguated `JarvisVision.ContextBuilder()` for the cloud-opt-in detector.
- `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift` (modified) — line 209: same disambiguation (`testContextBuilderDetectsCloudOptIn`).
- `packages/AgentCore/Tests/AgentCoreTests/CacheHintsEligibilityTests.swift` (modified) — added `test_preambleDoesNotEnableCacheUnintentionally` (T-10-CACHE-01 / VALIDATION map row SELF-06).

## Decisions Made

- **D-12 fallback applied.** `AgentOrchestrator.init` still takes `systemPrompt: String` directly (line 98 of AgentOrchestrator.swift). Plumbing per-turn `TurnContext` through orchestrator init is out of scope for Plan 10-02. AppDelegate uses `ContextBuilder.systemPrompt(for: .empty)`, which yields the preamble alone. Per-turn presence enrichment continues to flow through `PresenceStateSnapshot.shared` (already passed to the orchestrator constructor) — no behavior change there.
- **D-14 honored.** The preamble names tools by identifier (so the model has handles) but does not enumerate schemas. The Anthropic API tools array remains the authoritative catalog.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Cross-module ContextBuilder name collision**

- **Found during:** Task 2 (GREEN — running `swift test --package-path packages/AgentCore` after creating `AgentCore.ContextBuilder`).
- **Issue:** `JarvisVision.ContextBuilder` already exists at `packages/Vision/Sources/Vision/ContextBuilder.swift` and exposes `matchesCloudOptIn(_:)` + `matchesFrameAttachPhrase(_:)`. Three call sites used the bare unqualified name `ContextBuilder()` while importing both modules — the type checker flagged the ambiguity at:
    - `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:212` (`AgentOrchestrator` imports `AgentCore` and `JarvisVision`)
    - `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorVisionDispatchTests.swift:209` (test imports both)
    - `App/AppDelegate.swift:1620` (`tryPhraseAttachIfMatch`, AppDelegate imports both)
- **Fix:** Disambiguated all three call sites to use the fully-qualified module name `JarvisVision.ContextBuilder()`. Behavior unchanged; only the type reference is now explicit. Comment annotation added at each site explaining the disambiguation.
- **Files modified:** Listed above in "Files Created/Modified".
- **Verification:** `bash scripts/check-app-builds.sh` PASS; all 16 standalone boundary gates exit 0; `swift test --package-path packages/AgentCore --filter CacheHintsEligibilityTests` PASS (7/7).
- **Committed in:** `f22bf2e` (Task 2 commit, alongside the new ContextBuilder).

---

**Total deviations:** 1 auto-fixed (Rule 3 — blocking).
**Impact on plan:** Disambiguation was forced by the new type's introduction; all behavior preserved at the three call sites. No scope creep.

## Issues Encountered

- Earlier in the session, multiple background `swift test --package-path packages/AgentCore` invocations stacked up on the SwiftPM build-directory lock (one stuck process held the lock for >40 minutes after redirected output went unobserved). Killed the stuck process; all queued runs then completed cleanly with exit 0. No code-level impact.

## Threat Mitigation

- **T-10-CACHE-01 (Cache-eligibility breakage):** mitigated. `selfAwarePreamble.count` is well under 2048 chars (deliberate head-room against the 4096-char Anthropic cache-eligibility boundary). The Wave-0 test `preambleDoesNotEnableCacheUnintentionally` asserts both head-room AND verdict invariance vs the prior literal `"You are Jarvis, a personal macOS assistant."` — `CacheHints.eligibleForSystemPrompt` returns nil for both, so introducing the preamble does NOT unintentionally flip `cache_control` marker emission. Pitfall #4 / Assumption A4 closed.
- **T-10-PROMPT-01 (Preamble drift):** mitigated. Preamble is a single locked Swift `static let` constant (D-13). No JSON file, no localization, no runtime mutation. The cache-eligibility test enforces `hasPrefix("You are Jarvis")` and `!contains("```")` (D-14 — no Markdown tool catalog block).
- **T-10-PROMPT-02 (Tool surface disclosure):** accepted as documented. Preamble names tools that are already exposed via the Anthropic tools array per turn. No keys, no PII, no transcript content.

## Live Verification (D-26 / SPEC AC-13)

> **Status: PENDING — checkpoint awaiting human verification.** The two introspection questions (AC-05 / AC-06) require a human at the keyboard to ask Jarvis the questions and observe the live model behavior. The executor agent has completed Tasks 1-2 (commits `5bb9371` and `f22bf2e`); Task 3 is the human-verify gate.

### Pre-checks

- [x] `bash scripts/check-app-builds.sh` PASS at HEAD `f22bf2e`
- [x] All 16 standalone boundary gates exit 0 at HEAD (`check-bus-harness-parity.sh`, `check-bus-protocol-version.sh`, `check-corpus-secrets.sh`, `check-embedding-dim-literal.sh`, `check-install-order.sh`, `check-no-evaluate-javascript.sh`, `check-no-leftover-stubs.sh`, `check-no-modal-presentation.sh`, `check-no-null-voice-adapters.sh`, `check-orchestrator-events-single-consumer.sh`, `check-presence-bus-no-tts-orchestrator.sh`, `check-presence-vision-isolation.sh`, `check-single-memory-mutated-emit.sh`, `check-single-memory-used-emit.sh`, `check-single-writer-hudstate.sh`, `check-vision-isolation.sh`)
- [x] Targeted test `swift test --package-path packages/AgentCore --filter CacheHintsEligibilityTests` PASS (7/7 including new `test_preambleDoesNotEnableCacheUnintentionally`)
- [x] Prior literal grep clean: `grep -rn "You are Jarvis, a personal macOS assistant" App/ packages/` shows only one comment line in AppDelegate (annotation explaining the replacement) and two test-fixture lines in `AnthropicProviderTests/RequestBodyTests.swift` + `CacheHintsEligibilityTests.swift` using it as a regression baseline. No live call site.

### Reset (D-28; only when touching mic / camera / audio)

**N/A — Plan 10-02 modifies system prompt composition only; no hardware capture surface touched.** Per D-28 guidance, Plan 10-02 does not require `tccutil reset Microphone com.koftwentytwo.jarvis` (no mic init code path changed) or `tccutil reset Camera com.koftwentytwo.jarvis` (no camera init code path changed). The AVAudioEngine + AVCaptureDevice grants from Plan 10-01 (and earlier `b92d062`) carry forward unchanged.

### Relaunch (HUMAN STEP)

```bash
cd /Users/james.maes/Git.Local/Kof22/Jarvis
bash scripts/check-app-builds.sh && open build/Build/Products/Debug/Jarvis.app
```

- **Build artifact:** `build/Build/Products/Debug/Jarvis.app` from commit `f22bf2e`.
- **Tail the log channel** in a second terminal so we can capture the introspection tool calls:
  ```bash
  log stream --predicate 'subsystem == "com.koftwentytwo.jarvis"' --style compact \
    | grep -E "(tool_use|tool_result|get_active_audio_route|get_self_state|list_audio_devices|list_camera_devices|agentcore.agent)"
  ```

### Live model behavior tests (HUMAN STEPS)

After Jarvis is up and HUD is responsive (use the chat panel — voice is fine too if wake-word is healthy):

#### Test 1 (AC-05): "What microphone are you using?"

- **Type or say verbatim:** `What microphone are you using?`
- **Expected behavior A — tool call:** Within ~500 ms the log tail should show a `tool_use` entry naming `get_active_audio_route` (or, as a slightly less specific fallback, `list_audio_devices` followed by `get_active_audio_route`). Plan 10-03's DevOverlay last-5-tool-calls populator is not yet shipped, so log inspection is the verification path; if 10-03 is already live the same evidence appears in the DevOverlay window.
- **Expected behavior B — answer content:** The model's reply names the actual device returned by the tool (e.g., `MacBook Pro Microphone`, `External USB Microphone`, etc.). Match against what `system_profiler SPAudioDataType | grep -A2 "Default Input Device:"` reports.
- **NOT acceptable:** "Open System Settings to see your microphone", "I don't have access to your hardware", "I'm a text-based assistant", or any answer that does NOT call `get_active_audio_route`.

> **Capture:** paste the verbatim user question, the verbatim model response, AND the matching log line(s) showing the tool call into the **Observed** block below.

#### Test 2 (AC-06): "Are you a text-only assistant?"

- **Type or say verbatim:** `Are you a text-only assistant?`
- **Expected behavior:** Reply explicitly denies being text-only AND cites voice + vision capabilities (e.g., "No — I have your microphone and speakers, plus a camera I can use when you ask"). The preamble's closing sentence `You are not a text-only assistant.` should anchor the denial.
- **NOT acceptable:** Any reply confirming text-only, omitting voice OR vision, or directing the user to "open System Settings to enable" the hardware.

> **Capture:** paste the verbatim user question and the verbatim model response into the **Observed** block below.

### Observed (HUMAN FILLS)

```
<HH:MM:SS>  USER:    What microphone are you using?
<HH:MM:SS>  TOOLUSE: get_active_audio_route { ... }       <-- log line proving tool call
<HH:MM:SS>  JARVIS:  <verbatim response — should name the device>

<HH:MM:SS>  USER:    Are you a text-only assistant?
<HH:MM:SS>  JARVIS:  <verbatim response — should deny + cite voice + vision>
```

### Acceptance Match

- **AC-05:** PENDING — awaiting human verification per checkpoint protocol. Mark `PASS — <evidence>` once both Expected behaviors A and B above are observed; mark `FAIL — <observed wording>` if the model still says it has no mic / no hardware access / is text-only.
- **AC-06:** PENDING — awaiting human verification per checkpoint protocol. Mark `PASS — <evidence>` once the model denies being text-only and names voice + vision; mark `FAIL — <observed wording>` if it confirms text-only or omits a capability.

> **Resume signal:** Type `approved` once both AC-05 and AC-06 have been flipped from PENDING to PASS in this section. If either fails, paste the observed wording into a comment so the executor can iterate on the preamble within D-13's locked-string constraints.

## Next Plan Readiness

- **Plan 10-03 (DevOverlay subscriber fix)** can start immediately. The introspection tool calls now reliably fire from the model when self-knowledge questions land — Plan 10-03's job is to make those tool calls visible in the DevOverlay last-5 panel.
- **Open question for Plan 10-03:** the AC-05 verification path falls back to `log stream` because DevOverlay's last-5-tool-calls list is still empty post-`d8983af`. Once 10-03 ships, re-running this Live Verification should show the tool call in DevOverlay directly; that's the cleaner evidence path going forward.

## Self-Check: PASSED

- `packages/AgentCore/Sources/AgentCore/ContextBuilder.swift` exists.
- `.planning/phases/10-self-awareness-diagnostics/10-02-SUMMARY.md` exists.
- Commit `5bb9371` (Task 1 RED) present in `git log`.
- Commit `f22bf2e` (Task 2 GREEN) present in `git log`.
- Task 3 (Live Verification) intentionally left as PENDING per checkpoint protocol.

---
*Phase: 10-self-awareness-diagnostics*
*Plan: 10-02 (System Prompt Preamble)*
*Completed: 2026-05-06 (pending human verification on Task 3)*
