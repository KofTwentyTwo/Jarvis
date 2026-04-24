---
phase: 04-agent-core
plan: 05
subsystem: agent
tags: [agent, devoverlay, observability, obs-01, agent-10, text-01, sec-06]
requires: [04-01, 04-02, 04-03, 04-04]
provides:
  - DevOverlay SPM package (NSPanel-based floating dev surface)
  - DevSnapshot value type (atomic state bag for OBS-01)
  - ToolCallRow value type (last-5 tool-call ring entry)
  - DevOverlayViewModel (@Observable @MainActor, single-write-path)
  - DevOverlayView (SwiftUI renderer, read-only)
  - DevOverlayWindow (NSPanel .floating + .nonactivating, hidden by default)
  - DevOverlayBridge (BoundedAsyncChannel<DevSnapshot> → ViewModel pump)
  - DevSnapshotEmitter actor (OrchestratorEvent → DevSnapshot aggregator)
  - OrchestratorEvent.usage(turnId:usage:) additive case
  - TextInputEndToEndTests (TEXT-01 headless proof)
  - ChannelTopologyTests (AGENT-10 four-seam invariant verification)
affects:
  - packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift (added `.usage` case)
  - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (emit .usage on LLMEvent.usage)
  - packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift (capacity + policy made `nonisolated`)
tech-stack:
  added:
    - DevOverlay SPM package (macOS 14 floor, for Observation framework)
    - @Observable @MainActor view-model pattern (SwiftUI Observation framework)
    - NSPanel .floating + .nonactivating wrapper for HUD-style overlays
    - DevSnapshotEmitter actor (TTFB/totalMs tracking via ContinuousClock)
  patterns:
    - Single write path into UI state: DevSnapshot channel subscriber is the
      ONLY writer to DevOverlayViewModel.snapshot (UI is read-only)
    - Observational seam: capacity 32 + .dropOldest at orch→devoverlay
      (AGENT-10 — stale snapshots fine, replay log is authoritative)
    - ToolCallRow ring dedupes on toolUseId (T-04-05-03 DoS mitigation: a
      single tool with 100 phase updates produces at most 1 row, not 100)
    - BoundedAsyncChannel property introspection via `nonisolated let`
      (lets topology tests assert capacity/policy without actor hop)
key-files:
  created:
    - packages/DevOverlay/Package.swift
    - packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift
    - packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift
    - packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift
    - packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift
    - packages/DevOverlay/Tests/DevOverlayTests/DevSnapshotTests.swift
    - packages/DevOverlay/Tests/DevOverlayTests/DevOverlayViewModelTests.swift
    - packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBridgeTests.swift
    - packages/AgentCore/Sources/AgentOrchestrator/DevSnapshot.swift
    - packages/AgentCore/Sources/AgentOrchestrator/ToolCallRow.swift
    - packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/DevSnapshotEmitterTests.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/TextInputEndToEndTests.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/ChannelTopologyTests.swift
  modified:
    - packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift (added .usage case)
    - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (emit .usage alongside replay.record)
    - packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift (nonisolated capacity + policy)
decisions:
  - Decision: DevSnapshot + ToolCallRow live in AgentOrchestrator target, not DevOverlay
    rationale: DevSnapshotEmitter consumes OrchestratorEvent (in AgentOrchestrator)
      AND emits DevSnapshot. Hosting DevSnapshot in DevOverlay would create
      AgentOrchestrator → DevOverlay → AgentOrchestrator. Same Rule 3 dep-cycle
      fix Plan 04-04 used when it split out the AgentOrchestrator target.
  - Decision: DevSnapshotEmitter lives in AgentOrchestrator target, not AgentCore
    rationale: It subscribes to OrchestratorEvent which lives in AgentOrchestrator.
      Hosting the emitter in AgentCore would require AgentCore → AgentOrchestrator
      (backwards from the existing direction). Co-located with its input type.
  - Decision: @Observable + @MainActor with single write path from channel subscriber
    rationale: UI drift is impossible — whatever DevSnapshotEmitter says is the
      current state is what the overlay renders. No optimistic UI updates,
      no local state machines, no "this UI flag says X but the model says Y"
      failure modes. Cheap correctness.
  - Decision: Observational channel policy .dropOldest (capacity 32)
    rationale: DevOverlay is diagnostic; stale snapshots are fine. The replay
      log (OBS-02) is the authoritative record. Any drops here are invisible
      because the next snapshot immediately supersedes the dropped one.
  - Decision: ChannelTopologyTests uses TokenDeltaDropOldestChannel directly
      (not through a wired orch→replay instance)
    rationale: AgentOrchestrator currently calls `replayLog.record(...)`
      synchronously on the actor — there is no instantiated channel at the
      orch→replay seam in Phase 4. The primitive exists (Plan 04-03) with the
      correct semantics; CT2 verifies its contract so a future Phase 5 wiring
      that uses this primitive is correct by construction. Documented in the
      test file's header and in "Known Stubs" below.
  - Decision: NSPanel toggle exposed; menu-bar wiring deferred
    rationale: File scope forbids App/** touches. DevOverlayWindow.toggle()
      is the primitive; Phase 1 App-shell wiring or a dedicated plan later
      will bind it to a menu-bar item / global hotkey.
  - Decision: TextInputEndToEndTests + ChannelTopologyTests placed in
      AgentOrchestratorTests (not AgentCoreTests as plan said)
    rationale: MockLLMProvider, StubToolDispatcher, and Helpers live in
      AgentOrchestratorTests; re-using them here is clean. AgentCoreTests
      has no orchestrator fixtures. Rule 3 location fix.
  - Decision: Reused StubToolDispatcher instead of creating MockToolDispatcher
    rationale: Plan called for a new MockToolDispatcher actor with a scripted
      response map; the existing closure-based StubToolDispatcher from 04-04
      is functionally identical and simpler. No duplicate helper.
metrics:
  duration: ~60 min wall-clock
  completed: 2026-04-24
  tasks_completed: 3
  commits:
    - 1aeec87 - feat(04-05): DevOverlay package + DevSnapshot/ToolCallRow in AgentOrchestrator (OBS-01)
    - 5e50f40 - feat(04-05): DevSnapshotEmitter aggregates OrchestratorEvent → DevSnapshot (OBS-01)
    - b389455 - test(04-05): TEXT-01 headless E2E + AGENT-10 four-seam channel topology
  tests_added: 31 (14 DevOverlay + 9 emitter + 4 TEXT-01 + 4 AGENT-10)
  loc: ~1540 (including tests + comments)
  agentcore_tests_total: 131 (+17 from 114 baseline at 04-04 close)
  devoverlay_tests_total: 14
requirements-completed:
  - OBS-01
  - AGENT-10
  - TEXT-01
---

# Phase 4 Plan 5: DevOverlay + TEXT-01 E2E + AGENT-10 Topology Summary

**One-liner:** DevOverlay SwiftUI surface (NSPanel, @Observable) driven by a DevSnapshotEmitter that aggregates OrchestratorEvent into atomic snapshots — plus TEXT-01 headless text-input E2E proof and AGENT-10 four-seam channel topology verification, closing Phase 4.

## What shipped

### 1. DevOverlay package (OBS-01)

A new SPM package at `packages/DevOverlay/` (macOS 14 floor, for @Observable) providing a floating NSPanel dev overlay:

- **DevOverlayView** (SwiftUI) renders the full OBS-01 surface per research §9: state + turn-id row, provider + model row, input/output token counts, cache creation + read counts with hit percentage, TTFB + total latency, last-5 tool calls table. All read-only.
- **DevOverlayViewModel** is `@Observable @MainActor final class` with a single mutation entry point (`apply(_:)`). The UI never writes to `snapshot`; only the channel subscriber task does.
- **DevOverlayWindow** is an NSPanel wrapper with `.floating` window level + `.nonactivatingPanel` style mask. Hidden by default; `show() / hide() / toggle()` drive visibility. Menu-bar + hotkey wiring is deferred to a later plan (file scope forbids App/** touches here).
- **DevOverlayBridge** pumps a `BoundedAsyncChannel<DevSnapshot>` to the view-model on the main actor. `attach()` spawns the subscriber task; `detach()` cancels it; re-attaching cancels the previous task.

### 2. DevSnapshotEmitter (OBS-01 + AGENT-10)

Actor in AgentOrchestrator target that consumes `OrchestratorEvent` and produces `DevSnapshot` updates on a `BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)` — the AGENT-10 orch→devoverlay seam.

- TTFB tracked via `ContinuousClock` between `.stateChange(.thinking)` and the first `.tokenDelta`.
- Total latency tracked between `.thinking` and `.turnEnd`.
- Last-5 tool-call ring dedupes on `toolUseId` — repeated updates for the same tool_use overwrite the existing row rather than flood the ring (T-04-05-03 DoS mitigation). A single tool call with 100 phase updates produces at most 1 row.
- `.turnEnd` is idempotent — double-fire doesn't crash.

The emitter's single write path is `apply(_:)` → `output.send(current)`. The whole aggregator is one serialised state machine.

### 3. OrchestratorEvent.usage additive case

`OrchestratorEvent` gains `.usage(turnId: TurnID, usage: TurnUsage)` so DevOverlay can show live token counts + cache hit ratio without reading the replay log. The orchestrator emits this alongside its existing `replayLog.record(.usage(...))` call whenever it processes `LLMEvent.usage`.

**SEC-06 invariant preserved:** `TurnUsage` has no nonce field. The `grep -v '^//' OrchestratorEvent.swift | grep -c 'nonce'` gate still returns 0.

### 4. TEXT-01 headless text-input E2E proof

Four tests in `TextInputEndToEndTests.swift` demonstrate that text and voice turns share the orchestrator's entry (only `TurnInput.source` differs):

- **TE1 (critical TEXT-01 proof):** Scripts a two-call turn — call 1 emits `"Let me check. "` + `toolUseRequested(get_time)` + `.stopReason(.toolUse)`; `StubToolDispatcher` returns `"22:57 UTC"`; call 2 emits `"It's "` + `"22:57 "` + `"UTC"` + `.usage` + `.stopReason(.endTurn)`. Collects all OrchestratorEvents from the orchestrator's channel. Asserts the concatenated tokenDelta text equals `"Let me check. It's 22:57 UTC"`, exactly one completed `.toolCardUpdate` for get_time, exactly one `.turnEnd(.endTurn)`, exactly one `.usage` event.
- **TE2:** ReplayLog receives the turn's events (DB on-disk has non-trivial bytes; full byte-level assertions live in ReplayTests).
- **TE3:** Text vs voice parity — re-runs the same scripted turn twice, once with `TurnInput.text`, once with `TurnInput.voice`; asserts the ordered sequence of event **kinds** is byte-identical.
- **TE4:** Inspect the second provider.stream call's messages for a `.tool` role; assert its content carries the `<UNTRUSTED_CONTENT id="...">` envelope (SEC-06 nonce-wrap applied).

### 5. AGENT-10 four-seam channel topology verification

Four tests in `ChannelTopologyTests.swift`:

- **CT1 (orch→bus):** `orchestrator.events.capacity == 256 && policy == .suspend`.
- **CT2 (orch→replay primitive):** `TokenDeltaDropOldestChannel<Tag>` contract — tokenDelta CAN drop under load; non-tokenDelta tags (tool_call / turn_end / reconfigure) NEVER drop. Verified with 500 tokenDeltas + 10 non-tokenDelta elements through a capacity-64 channel.
- **CT3 (orch→devoverlay):** `DevSnapshotEmitter.output.capacity == 32 && policy == .dropOldest`. Verified under stalled-consumer stress (100 events queued; drained; ≤ 33 snapshots visible).
- **CT4 (end-to-end stress):** Scripts a multi-call turn with 200 tokenDeltas + 3 tool_calls through `orchestrator.submit`. Asserts all 200 tokenDeltas AND all 6 tool_card updates (running + completed for each of 3 tools) AND the single .turnEnd AND at least 2 .stateChange events are delivered on `orchestrator.events`. `.suspend` policy is non-lossy.

## Deviations from Plan

### Auto-fixed (Rule 3)

**1. [Rule 3 - Blocking] DevSnapshot + ToolCallRow placed in AgentOrchestrator target, not DevOverlay**

- **Found during:** Task 1.
- **Issue:** The plan frontmatter listed `DevSnapshot.swift` and `ToolCallRow.swift` under `packages/DevOverlay/Sources/DevOverlay/`. But Task 2's `DevSnapshotEmitter` (living inside AgentOrchestrator because it consumes OrchestratorEvent) also needs to reference these types. Hosting them in DevOverlay would create AgentOrchestrator → DevOverlay → AgentOrchestrator — a cycle.
- **Fix:** Parked both in `packages/AgentCore/Sources/AgentOrchestrator/`. DevOverlay imports `AgentOrchestrator` and gets them transitively. Same Rule 3 rationale Plan 04-04 used when it split `AgentOrchestrator.swift` out of `AgentCore` for the same cycle reason.
- **Files modified:** file locations only.
- **Commit:** 1aeec87.

**2. [Rule 3 - Blocking] DevSnapshotEmitter placed in AgentOrchestrator target, not AgentCore**

- **Found during:** Task 2.
- **Issue:** Plan said `packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift`. But `OrchestratorEvent` lives in the AgentOrchestrator target; hosting the emitter in AgentCore would require AgentCore → AgentOrchestrator, a backwards dependency.
- **Fix:** File lives at `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift` instead.
- **Commit:** 5e50f40.

**3. [Rule 3 - Blocking] BoundedAsyncChannel.capacity + .policy made `nonisolated`**

- **Found during:** Task 2 test compile.
- **Issue:** Channel topology tests (CT1, CT3, DE8) need to assert `channel.capacity == 32 && channel.policy == .dropOldest`. Both were declared `public let` inside the actor, making them actor-isolated and inaccessible without `await`. Worse, since they're returned from an actor property call they'd be inaccessible altogether.
- **Fix:** Added `nonisolated` to both declarations. Both are `let`-constants set at init — no mutation to guard. This is the AGENT-10 compliance surface that verification tests need.
- **Files modified:** `packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift`.
- **Commit:** 5e50f40.

**4. [Rule 3 - Location] TextInputEndToEndTests + ChannelTopologyTests + DevSnapshotEmitterTests in AgentOrchestratorTests, not AgentCoreTests**

- **Found during:** Task 2, Task 3.
- **Issue:** Plan listed all three test files under `packages/AgentCore/Tests/AgentCoreTests/`, but `MockLLMProvider`, `StubToolDispatcher`, and `Helpers` live in `AgentOrchestratorTests`; re-using them cross-target would require exposing them as public.
- **Fix:** Tests live in `packages/AgentCore/Tests/AgentOrchestratorTests/` where the fixtures are. Zero architectural impact.
- **Commit:** 5e50f40 + b389455.

**5. [Rule 3 - Simplification] Reused StubToolDispatcher instead of creating MockToolDispatcher**

- **Found during:** Task 3.
- **Issue:** Plan described a new actor `MockToolDispatcher` with a scripted response map (`scripts: [String: Data]`). The existing closure-based `StubToolDispatcher` from Plan 04-04 is functionally identical (you pass a `@Sendable (ToolUseRequest) async throws -> Data` closure) and simpler.
- **Fix:** Reused `StubToolDispatcher`. Matches "minimum code that solves the problem."
- **Commit:** b389455.

No Rule 1 (bug) or Rule 2 (missing critical functionality) auto-fixes were needed — all 04-01..04-04 surfaces worked as advertised.

No Rule 4 (architectural) checkpoints triggered.

## Authentication gates

None. All work was headless package code + tests.

## Test verification

| Package    | Before | After | Delta                                                               |
| ---------- | -----: | ----: | ------------------------------------------------------------------- |
| AgentCore  |    114 |   131 | +17 (9 emitter + 4 TEXT-01 + 4 AGENT-10)                            |
| DevOverlay |      — |    14 | +14 new package (7 DS + 4 VM + 3 bridge)                            |
| Replay     |     25 |    25 | 0 (no regression)                                                   |
| Bus        |     47 |    47 | 0 (no regression)                                                   |

Release builds: AgentCore, DevOverlay — both exit 0.

### Grep-gate verification

- `grep -c 'cacheReadInputTokens\|cacheCreationInputTokens' DevSnapshot.swift` → 15 (both token fields rendered).
- `grep -c 'capacity: 32' DevSnapshotEmitter.swift` → 1 (via default arg, channel instantiation uses `capacity:`).
- `grep -c 'capacity: 256' AgentOrchestrator.swift` → 1.
- `grep -c 'TurnInput.text\|TurnInput.voice\|.text(\|.voice(' TextInputEndToEndTests.swift` → 6 (text + voice parity).
- `grep -v '^//' OrchestratorEvent.swift | grep -c 'nonce'` → 0 (SEC-06 preserved).
- `grep -c 'NSPanel' DevOverlayWindow.swift` → 3.
- `grep -c '@Observable\|@MainActor' DevOverlayViewModel.swift` → 4.
- `grep -c 'Last 5 tool calls' DevOverlayView.swift` → 2.

## Known Stubs

- **NSPanel menu-bar + hotkey wiring:** `DevOverlayWindow.toggle()` is exposed; binding it to a menu-bar item or global hotkey requires App/** changes which this plan's file scope forbids. Deferred to Phase 1 App-shell wiring or a dedicated later plan.
- **Real MCP tool dispatcher:** TEXT-01 E2E uses `StubToolDispatcher` with a closure returning `"22:57 UTC"`. The real MCP dispatcher lands in Phase 5.
- **orch→replay channel instance:** The `TokenDeltaDropOldestChannel<Tag>` primitive exists (Plan 04-03) with the correct semantics (tokenDelta lossy, others never lossy — verified by CT2). The orchestrator currently calls `replayLog.record(...)` synchronously on the actor; there is no channel between them today. A future plan that introduces a pre-actor replay channel will instantiate this primitive with `capacity: 2048, dropTag: .tokenDelta`. The AGENT-10 contract is already provable.
- **DevOverlay app-shell wiring:** No App code instantiates `DevSnapshotEmitter` or connects it to `orchestrator.events` yet. Phase 5 or the app-shell plan will wire: `let emitter = DevSnapshotEmitter(); await emitter.subscribe(to: orch.events); let bridge = DevOverlayBridge(viewModel: window.viewModel); bridge.attach(channel: await emitter.output)`.

## Phase 4 closure

All 5 plans merged. All 9 active Phase 4 REQ-IDs covered:

- **AGENT-01** (`LLMProvider` protocol + LLMEvent) — 04-01
- **AGENT-02** (Anthropic streaming) — 04-01
- **AGENT-03** (SSE state-machine edges) — 04-01
- **AGENT-04** (Ollama NDJSON + tool_calls-on-sight) — 04-02
- **AGENT-06** (submit / cancelAndSubmit) — 04-04
- **AGENT-07** (cap-recovery + tool-choice discipline) — 04-01, 04-02, 04-04
- **AGENT-08** (8 KB tool_result cap + nonce wrap) — 04-04
- **AGENT-09** (1-shot stream_truncated retry) — 04-04
- **AGENT-10** (four-seam bounded-channel topology) — 04-01 primitives + **04-05 verification**
- **OBS-01** (DevOverlay surface) — **04-05**
- **OBS-02** (Replay log) — 04-03
- **OBS-07** (crash-recovery orphan detection) — 04-03
- **TEXT-01** (text-input E2E) — **04-05**
- **SEC-06** (per-turn nonce + untrusted wrapper, nonce never on bus) — 04-04

**Next:** `/gsd-code-review 4` → `/gsd-verify-phase 4` → close.

## Self-Check: PASSED

All commit hashes verified present (`git log --oneline --all | grep -E '1aeec87|5e50f40|b389455'` returns 3). All created files exist. Grep gates pass. Test totals match claimed numbers.
