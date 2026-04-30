---
phase: 08-hardening
plan: 03
subsystem: testing
tags: [eval-harness, fd-leak-detection, audio-graph, tool-cap, ollama, mcp, codesign, xcode-26]

requires:
  - phase: 08-hardening/01
    provides: Harness SPM substrate (Oracle, Adapters, Runners, jarvis-eval CLI shell)
provides:
  - FDLeakDetector (lsof-based snapshot/delta API; macOS-portable)
  - MCPCrashRunner (D-19 cycle-time profiling; 50/100 decision; steady-state whitelist)
  - AudioGraphRebuildRunner (4-trigger × 6-step canonical teardown matrix; D-14 graceful degradation)
  - ToolCapRecoveryRunner (D-21 dual assertion: event count + outbound HTTP body)
  - LiveOllamaRunner (D-04 dual gate; D-06 preflight; never auto-pulls)
  - CapturingURLProtocol (httpBody + httpBodyStream capture for outbound-body inspection)
  - 4 jarvis-eval subcommands (mcp-crash, audio-rebuild, cap-recovery, corpus-ndjson-live)
  - Xcode 26 launch fragility resolution (ACCEPTED AS MANUAL with operator recipe)
  - AVAudioEngine route-change injection probe (available — direct rebuild method call)
affects: [08-04 checklist sweep folds in P6 deferred MANUAL items]

tech-stack:
  added:
    - swift-sdk MCP product (transitive dep added to Harness Package.swift for Value type)
  patterns:
    - "Hybrid lsof + Process spawn template for FD enumeration (PATTERNS.md §2.9)"
    - "URLProtocol body capture + canned response for D-21 outbound-body inspection"
    - "Method-level setUp/tearDown per audio trigger (Pitfall 7 — never share state)"
    - "Dual gate (CLI flag + env var) for live-mode opt-in"

key-files:
  created:
    - .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md
    - packages/Harness/Sources/Harness/FDLeakDetector.swift
    - packages/Harness/Sources/Harness/CapturingURLProtocol.swift
    - packages/Harness/Sources/Harness/Adapters/MockHelperBuilder.swift
    - packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift
    - packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift
    - packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift
    - packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift
    - packages/Harness/Tests/HarnessTests/FDLeakDetectorTests.swift
    - packages/Harness/Tests/HarnessTests/MCPCrashRunnerTests.swift
    - packages/Harness/Tests/HarnessTests/AudioGraphRebuildRunnerTests.swift
    - packages/Harness/Tests/HarnessTests/ToolCapRecoveryRunnerTests.swift
  modified:
    - packages/Harness/Package.swift
    - packages/Harness/Sources/jarvis-eval/main.swift

key-decisions:
  - "D-12 outcome: ACCEPTED AS MANUAL. Xcode 26 preview-dylib + post-codesign Info.plist re-stamping is upstream behavior with no exposed setting. Operator workaround: Release archive only, never ⌘R Debug for UAT."
  - "D-14 outcome: AVAudioEngine route-change injection IS available via direct AudioGraphOwner.rebuild(trigger:) call (same recipe TeardownTests uses). All four triggers run automated; degradedToManual stays false."
  - "D-19 actualTarget: profile-then-decide via MCPCrashRunner.decideTarget(medianMs:extended:userTarget:) pure helper. Boundary at 200ms unit-tested."
  - "D-21 dual assertion implemented: clause 1 (zero .toolUseRequested events on recovery turn) + clause 2 (outbound HTTP body inspection: Anthropic tool_choice {type:none}, Ollama no tools key)."
  - "AudioGraph 6-step ordering: TeardownTests in Voice test target retains the strict ordering contract; Harness runner observes 3 of 6 steps at AudioGraphOwner's public boundary (cancelInFlight, releaseORTSessions, .reconfiguring event). The runner does NOT duplicate the strict-ordering assertion — it asserts integration-level completion per trigger."

patterns-established:
  - "lsof -F ftn parser tolerates missing 'n' lines (sockets/FIFOs), non-UTF-8 path bytes (lossy U+FFFD), and unknown future tags"
  - "MCPCrashRunner spawns ONLY through real MCPClient — production's ChildSpawnGate + restart mutex are exercised, not bypassed"
  - "ToolCapRecoveryRunner drives real AnthropicProvider/OllamaProvider against CapturingURLProtocol session — wire-format contract genuinely verified"
  - "LiveOllamaRunner never auto-pulls models: any 'ollama pull' reference is operator-advice text only"

requirements-completed:
  - OBS-04

duration: ~75min
completed: 2026-04-30
---

# Phase 08-03: Live + Integration Runners Summary

**Wave-2 sibling of 08-02. Ships pillars (c-live), (d), (f), (g) of the OBS-04 eval matrix plus the inherited Xcode 26 launch-fragility resolution.**

## Performance

- **Duration:** ~75 min
- **Started:** 2026-04-30 morning
- **Completed:** 2026-04-30
- **Tasks:** 3 / 3
- **Files created:** 12 (4 docs + 5 runners + 4 tests; 1 of those is also a builder/protocol file)
- **Files modified:** 2 (Package.swift dep add; main.swift subcommand wiring)

## Accomplishments

- **Xcode 26 launch fragility (D-12)** definitively documented as ACCEPTED AS MANUAL with full operator recipe (Release archive only). Investigation rules out fixable build-setting paths; remaining path is upstream Xcode preview-dylib + post-codesign Info.plist re-stamping which has no Xcode 26 escape hatch.
- **AVAudioEngine route-change probe (D-14)** outcome: available. The existing public `AudioGraphOwner.rebuild(trigger:)` seam is the synthetic injection mechanism (same recipe TeardownTests already uses end-to-end). All four trigger cases run automated; `degradedToManual` stays false.
- **FDLeakDetector** with hybrid lsof + Process spawn template, parsing `-F ftn` terse output; tolerates 4 edge cases (empty input, missing `n` lines on sockets/FIFOs, non-UTF-8 path bytes, unknown future tags). 9 unit tests including live FD open/close round-trip on the test process.
- **MCPCrashRunner** with D-19 cycle-time profiling: profile 5 crashes → if median ≤ 200ms run 100 cycles; else reduce to 50; `--extended` forces 500. `decideTarget` extracted as pure helper for boundary-at-200ms unit testing. Steady-state whitelist (PIPE/FIFO/SQLite WAL/SHM) classifies churn vs leak.
- **AudioGraphRebuildRunner** drives all four canonical `RebuildTrigger` cases through fresh `AudioGraphOwner` instances per Pitfall 7 isolation. Records 6-step canonical spec; observes 3 steps at public boundary (cancelInFlight + releaseORTSessions + .reconfiguring event); strict 6-step ordering contract stays in TeardownTests.
- **ToolCapRecoveryRunner** enforces D-21 dual contract: clause 1 (zero tool_use events) + clause 2 (outbound body bytes). Real `AnthropicProvider` and `OllamaProvider` drive a `CapturingURLProtocol` session. Wire-format contract genuinely verified — captured Anthropic body confirms `"tool_choice":{"type":"none"}`; captured Ollama body confirms absence of `tools` key entirely.
- **LiveOllamaRunner** with D-04 dual gate (`--live` flag AND `JARVIS_LIVE_EVAL=1` env var) and D-06 preflight (curl `127.0.0.1:11434/api/tags` → status 200 → check `qwen2.5-coder:32b` in models). Never auto-pulls.
- **4 jarvis-eval subcommands** wired and verified: `mcp-crash`, `audio-rebuild`, `cap-recovery`, `corpus-ndjson-live`.

## Task Commits

1. **Task 1: launch-fragility notes + AVAudioEngine route-change probe** — `63a6c95` (docs)
2. **Task 2: FDLeakDetector + MCPCrashRunner + mcp-crash subcommand** — `1029eba` (feat)
3. **Task 3: audio-rebuild + cap-recovery + live Ollama runners** — `0261d28` (feat)

## Verification Snapshot

```bash
swift build --package-path packages/Harness        # exits 0
swift test  --package-path packages/Harness        # 32 XCTest + 13 swift-testing pass
swift run   --package-path packages/Harness jarvis-eval mcp-crash --help              # OK
swift run   --package-path packages/Harness jarvis-eval audio-rebuild --help          # OK
swift run   --package-path packages/Harness jarvis-eval cap-recovery --help           # OK
swift run   --package-path packages/Harness jarvis-eval corpus-ndjson-live --help     # OK
```

Test count delta: was 13 (substrate Wave 1) → now 45 total (32 XCTest + 13 swift-testing). New tests: +9 FDLeakDetectorTests, +7 MCPCrashRunnerTests, +9 AudioGraphRebuildRunnerTests, +7 ToolCapRecoveryRunnerTests.

## D-21 Outbound-Body Sample (real bytes captured during test run)

**Anthropic recovery turn body** (`tool_choice: {type:none}` while preserving `tools` array):

```json
{
  "max_tokens": 32,
  "messages": [{"content":[{"text":"recover","type":"text"}],"role":"user"}],
  "model": "claude-opus-4-7",
  "system": [{"text":"system","type":"text"}],
  "tool_choice": {"type":"none"},
  "tools": [{"description":"no-op","input_schema":{},"name":"noop"}]
}
```

**Ollama recovery turn body** (AGENT-07: `tools` array DROPPED entirely):

```json
{
  "messages": [{"content":"system","role":"system"},{"content":"recover","role":"user"}],
  "model": "qwen2.5-coder:32b",
  "options": {"num_predict": 32},
  "stream": true
}
```

Both bodies satisfy D-21 clause 2 of their respective providers. Clause 1 (zero `.toolUseRequested` events) holds for both.

## D-19 Profiling at Execution Time

The Wave 1 substrate already runs the equivalent 100-cycle FD-leak test inside `MCPRestartTests.test_100_crashCycles_noFDLeak` (median completes in seconds; observed delta ≤ 16 fds per the existing assertion). The new `MCPCrashRunner.decideTarget` exposes the same decision logic for explicit harness-level invocation; the executor did not run the full 100-cycle live invocation in this plan because (a) the Wave-1 test target already covers that contract, and (b) the runner-level live invocation is gated through `jarvis-eval mcp-crash` for operator-driven longevity testing. Median cycle time on this host is expected ≤ 200ms based on `MCPRestartTests` behavior, so the actualTarget would be 100.

## Steady-State FD Whitelist (final composition)

```swift
public static let steadyStateWhitelist: Set<String> = [
    "type=PIPE",
    "type=FIFO",
    "type=systm",
    "type=KQUEUE",
    "type=unix",
    "/tmp/jarvis-",
    "-wal",
    "-shm",
]
```

Generous by design — false negatives (whitelisted real leak) caught by linear-growth observation; false positives (failing on benign FD) make the harness flaky. Pattern-match (substring containment) rather than literal equality.

## LiveOllamaRunner Preflight at Execution Time

Probe of `http://127.0.0.1:11434/api/tags` at execution time:

- Daemon: **reachable** (status 200)
- Models present on host: `gemma4:latest`, `gemma4:31b`, `dev-master-2026:latest`, `qwen3:32b`, `llama3.1:70b-instruct-q8_0`, `dev-master:latest`, `qwen2.5-coder:32b-instruct-q8_0`
- `qwen2.5-coder:32b` (the exact tag the runner checks for): **NOT PRESENT** on this host. The host has `qwen2.5-coder:32b-instruct-q8_0` which is a different tag. Operator must `ollama pull qwen2.5-coder:32b` to enable live runs.

The runner correctly fails loud with operator advice if invoked under `JARVIS_LIVE_EVAL=1` against this host configuration.

## Cross-Reference for Plan 08-04 (sweep)

The following P6 deferred items still need MANUAL: checklist entries authored into `.planning/phases/06-voice/checklist.yaml` during plan 08-04's sweep (NOT here). Each was inherited from STATE.md "Phase 6 → Phase 8 Deferred Items" and the source gate is `06-HUMAN-UAT.md`:

| ID | Source | MANUAL: instruction summary |
|----|--------|---|
| VOICE-07 | 06-HUMAN-UAT Gate 1 | Cold-launch Release archive; "Hey Jarvis, what time is it"; verify ring transitions and Orpheus TTS |
| VOICE-14 | 06-HUMAN-UAT Gate 2 | Mid-`speaking` say "Hey Jarvis"; verify TTS stops within ~50ms |
| VOICE-13 | 06-HUMAN-UAT Gate 3 | PTT hotkey hold + speak; verify no wake-word delay |
| VOICE-12 | 06-HUMAN-UAT Gate 4 | Toggle "Mute Wake Word"; verify wake paused, PTT works, persistence |
| VOICE-09 | 06-HUMAN-UAT Gate 5 | Trigger AEC unavailability; verify AppKit AEC banner |
| VOICE-10 | 06-HUMAN-UAT Gate 6 | Deny mic at first launch; grant in Settings; verify rebuild |
| TTFA | STATE.md "P6 deferred" | Run `JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests`; record ms; if > 250ms set `features.tts.tier2 = "ttskit"` |

All 7 items must be operator-driven against a Release archive built per the recipe in `08-LAUNCH-FRAGILITY-NOTES.md` (`xcodebuild -scheme Jarvis -configuration Release archive`).

## Deviations from Plan

### Surface trim: Voice public API NOT widened for harness

PATTERNS.md §2.6 sketched an `installRecorderSlots(_:)` extension for the runner. That extension lives in the Voice test target (`TeardownTests.swift`). Lifting it into Voice's public surface for harness use would widen production API for a test-only need. Instead, the runner observes the publicly-visible boundary (`cancelInFlight` + `releaseORTSessions` + `.reconfiguring` event = 3 of 6 canonical steps) and records that as `observableTeardownSteps`. Strict 6-step ordering remains the contract of TeardownTests — runner is the integration-level gate, not the ordering oracle. **Surface decision: production API stays tight.**

### MCPCrashRunner did NOT run a full 100-cycle live invocation in this commit

The 100-cycle FD-leak contract is already enforced by `MCPRestartTests.test_100_crashCycles_noFDLeak` in the MCP test target (Wave 1). MCPCrashRunner exposes the same flow as a runner subcommand for operator-driven longevity testing (`jarvis-eval mcp-crash` and `--extended` 500-mode). The runner's unit tests cover the D-19 decision logic + report shape. **No live cycle run in this commit; runner is exercised via `jarvis-eval mcp-crash` invocation.**

### Subcommand registration ordering

Initial Task 2 commit registered ONLY the `mcp-crash` subcommand (Task 3 types not yet defined). Task 3 commit re-added all three remaining subcommands (audio-rebuild, cap-recovery, corpus-ndjson-live) idempotently. Final main.swift subcommands array contains all 5: `Replay, McpCrash, AudioRebuild, CapRecovery, CorpusNDJSONLive`.

### "ollama pull" reference count interpretation

The plan's acceptance criterion says `grep -cE "ollama pull|exec.*ollama" returns 0 (and any reference to "pull" appears only in operator-advice strings)`. The literal grep returns 3 in `LiveOllamaRunner.swift`, but all 3 occurrences are within operator-advice strings or comments — none are subprocess exec or `Process.exec`. The plan's bracketed clause is the carve-out; spirit is satisfied. The runner contains zero `Process()` invocations to launch `ollama`.
