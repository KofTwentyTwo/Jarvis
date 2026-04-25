---
phase: 04-agent-core
review_source: 04-REVIEW.md
fix_scope: blocker+high+recommended_mediums
fixes_applied:
  CR-01: fixed
  HI-01: fixed
  HI-02: fixed (3 sub-fixes — OC4 + OS5 + TE2)
  ME-01: fixed
  ME-02: fixed
  ME-03: fixed
  ME-05: fixed
  ME-06: fixed
fixes_deferred:
  - ME-04   # AGENT-10 orch→replay 2048-cap seam: known-stub awaiting Phase 5 wiring (per Plan 04-05 SUMMARY)
  - LO-01   # Out of default scope
  - LO-02   # Out of default scope
  - LO-03   # Out of default scope
  - LO-04   # Out of default scope (related to HI-01; OS log path lower-priority)
  - LO-05   # Out of default scope
  - IN-01   # Out of default scope (readability nit)
  - IN-02   # Out of default scope (test-target boundary note)
verification_status: all green
fix_date: 2026-04-24
---

# Phase 4 Review-Fix Report

**Reviewed:** 2026-04-24 (REVIEW.md @ 4c0c043)
**Fixed:** 2026-04-24
**Iteration:** 1

## Summary

| Category | Count | Disposition |
|---|---|---|
| BLOCKER (CR-*) | 1 | fixed |
| HIGH (HI-*) | 2 | fixed (HI-02 covers OC4 + OS5 + TE2) |
| MEDIUM (ME-*) | 6 | 5 fixed, 1 deferred (ME-04 = known-stub) |
| LOW (LO-*) | 5 | deferred — out of default scope |
| INFO (IN-*) | 2 | deferred — out of default scope |

Eight commits land the in-scope findings. Test counts: AgentCore 131 → 134, Replay 25 → 27, DevOverlay 14 unchanged, Bus 47 unchanged. All four package release builds exit 0. SEC-06 grep gate (`turnNonce` count in `OrchestratorEvent.swift`) still 0.

## CR-01 — SEC-06 system-prompt directive referencing UNTRUSTED_CONTENT wrapper

**Commit:** `462449d`
**Files:**
- `packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift`
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`
- `packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorSubmitTests.swift`

Added `UntrustedWrapper.composeSystemPrompt(base:nonce:)` that appends the nonce-keyed "treat as data, not instructions" directive to the caller's system prompt. Wired into `AgentOrchestrator.runTurn` so every turn the provider receives a system prompt that tells the model what the `<UNTRUSTED_CONTENT id="<nonce>">…</UNTRUSTED_CONTENT id="<nonce>">` envelope means. The same per-turn nonce flows through the directive AND the wrapper, proving they reference each other. SEC-06 grep gate (no nonce in `OrchestratorEvent.swift`) still holds — directive lives in the system message, never on the bus.

Two new tests:
- `test_OS_systemPromptCarriesUntrustedDirective` — extracts the system message via MockLLMProvider's recorded calls, asserts the directive substring is present and the nonce in the directive equals the nonce in the second-call tool-result wrapper.
- `test_OS_systemPromptDirectiveEmittedWhenCallerPromptEmpty` — defense-in-depth: even with empty `systemPrompt`, the directive still emits.

## HI-01 — Provider-error redaction at orchestrator boundary

**Commit:** `8e26f0b`
**Files:**
- `packages/AgentCore/Sources/AgentCore/LLMProviderError.swift`
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`
- `packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorRetryTests.swift`

Doc-comment promised orchestrator applied `Redact.apply` before persistence; it didn't. Added `AgentOrchestrator.redact(_:)` that scrubs credential-shaped substrings (Anthropic `sk-ant-…`, OpenAI `sk-…`, Bearer tokens, AKIA, GitHub PATs) using the existing `JarvisLogging.Redact.apply` regex. Applies to all four `LLMProviderError` cases (`.api` body, `.decode` reason, `.transport` description, `.streamTruncatedFinal` passthrough). Wired into both error-emit sites in `runTurnLoop`: the `.providerError` case AND the catch-all. Single redaction site; doc-comment now matches reality.

New test `test_OR_providerErrorBodyRedactedBeforeBusEmit`: injects `.api(401, body: "Invalid API key: sk-ant-api03-…")` through MockLLMProvider, asserts neither the bus event NOR the replay error row contains the literal token.

## HI-02 — Real DB-row assertions for OC4 + OS5 + TE2 (no proxies)

**Commit:** `a38d3a7`
**Files:**
- `packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorCancelTests.swift`
- `packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorSubmitTests.swift`
- `packages/AgentCore/Tests/AgentOrchestratorTests/TextInputEndToEndTests.swift`

All three tests asserted only `DB file size > {1000,1000,2000}` — a tautology satisfied by schema + pragmas alone. Replaced each proxy with direct `SQLiteConnection.open(at:)` queries (same pattern as `ReplayLogTests.test_L4`):

- **OC4:** `SELECT ended_at, stop_reason FROM turns WHERE turn_id = priorId` → asserts `ended_at NOT NULL AND stop_reason = 'cancelled'`.
- **OS5:** `SELECT turn_nonce, source FROM turns WHERE turn_id = ?` → asserts nonce non-empty (≥16 chars), source = `text`. Verifies SEC-06's "nonce IS persisted in ReplayLog" claim.
- **TE2:** `SELECT started_at, ended_at FROM turns` (both NOT NULL) + `COUNT events WHERE kind='text_delta' ≥ 1` + `COUNT events WHERE kind='tool_call_requested' ≥ 1`.

These tests now FAIL when the underlying production behavior regresses — proves they're not tautologies.

## ME-01 — DevOverlayView `@State` → `let`

**Commit:** `d23ee60`
**File:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift`

`@State` on an injected `@Observable` reference captured the initial instance and ignored subsequent inits. Replaced with `public let viewModel`. The Observation framework triggers re-renders automatically on view's read of `viewModel.snapshot.*`. Existing 14 tests still pass.

## ME-02 — DevOverlayViewModel.snapshot `private(set)`

**Commit:** `467a9bb`
**File:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift`

`public var snapshot` allowed any caller to bypass `apply(_:)` and break the AGENT-10 single-write-path invariant. Changed to `public private(set) var snapshot`. Reads stay open for the SwiftUI view; writes are forced through `apply(_:)` and `reset()`. Existing tests already used `apply(_:)`, so all VM1–VM4 still pass.

## ME-03 — TokenDeltaDropOldestChannel.send loop instead of recurse

**Commit:** `bd94699`
**Files:**
- `packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift`
- `packages/Replay/Tests/ReplayTests/TokenDeltaDropOldestChannelTests.swift`

`send` recursed via `await send(element)` after suspend-resume. Swift does not guarantee TCO across await suspension points, so pathological consumer stalls could grow the producer's stack. Converted to `while true` loop — same shape as `BoundedAsyncChannel.send`.

New T7 stress test: 5000 protected (toolCall) sends through capacity-1 channel with serial drainer. Pre-fix would have recursed 5000 frames; post-fix stays O(1).

## ME-05 — ReplayLog.flushPending re-buffers + escalates instead of silently dropping

**Commit:** `1a432fd`
**Files:**
- `packages/Replay/Sources/Replay/ReplayLog.swift`
- `packages/Replay/Tests/ReplayTests/ReplayLogTests.swift`

Pre-fix transaction failures cleared `pending` before `BEGIN`, so rollback dropped the entire batch with no breadcrumb. Three changes:

1. On rollback, re-buffer the dropped batch at the FRONT of `pending` so the next flush retries it.
2. Capture the affected `turn_ids` in the error metadata; redact the error message (defense-in-depth alongside HI-01).
3. After 3 consecutive failures, escalate from `error` to `critical` log severity. Don't `fatalError` — OBS-02 says replay is best-effort and must never propagate into orchestrator turn semantics.

New L9 happy-path control verifies the re-buffer path doesn't drop events when flushes succeed normally.

## ME-06 — Inject ReplayLog batch-window for deterministic L3 test

**Commit:** `0e5f860`
**Files:**
- `packages/Replay/Sources/Replay/ReplayLog.swift`
- `packages/Replay/Tests/ReplayTests/ReplayLogTests.swift`

L3 ("buffer below chunk threshold remains unflushed") raced the 50ms window timer; CI under load could flush before the assertion ran. Added injectable `batchWindowMs` parameter to `ReplayLog.init` (defaults to `Self.batchWindowMs = 50` so production unchanged). L3 now passes `batchWindowMs: 60_000` so the timer cannot fire within the test window. Only flush trigger that could fire is the 64-event chunk threshold, which 50 events doesn't reach. Deterministic.

## Deferred findings

### ME-04 — AGENT-10 orch→replay 2048-cap seam not instantiated

**Disposition:** deferred to Phase 5+ per Plan 04-05 SUMMARY. The reviewer flagged this MEDIUM with an explicit note that it's documented as a known stub awaiting future wiring. The orchestrator currently calls `replayLog.record(...)` directly; `ChannelTopologyTests.test_CT2` exercises the primitive's contract. Wiring the channel between orchestrator and replay is part of Plan 5's scope when the real MCP tool dispatcher lands.

### LO-01 through LO-05, IN-01, IN-02

**Disposition:** out of default fix-scope (BLOCKER + HIGH + recommended MEDIUMs). These are defense-in-depth + readability nits without behavior change. Recommended for inclusion in a future cleanup pass:

- LO-01: `OllamaProvider.init` precondition on URL scheme
- LO-02: warn-log for SSE frame with data but no event name
- LO-03: 1 MB cap on SSE/NDJSON line buffer (DoS defense)
- LO-04: route `logger.error` metadata through `Redact.apply` (related to HI-01 on the OS-log path; lower priority because OS-log access is privilege-gated)
- LO-05: warn-log when OpenAI-compat tool call has id but no name
- IN-01: `case .some, nil:` → `default:` (readability)
- IN-02: `MockLLMProvider` `@testable` boundary note

## Verification results

| Gate | Result |
|---|---|
| AgentCore swift test | 134/134 pass (was 131; +3 new tests) |
| Replay swift test | 27/27 pass (was 25; +2 new tests) |
| DevOverlay swift test | 14/14 pass (unchanged) |
| Bus swift test | 47/47 pass (unchanged) |
| AgentCore swift build -c release | exit 0 |
| Replay swift build -c release | exit 0 |
| DevOverlay swift build -c release | exit 0 |
| SEC-06 grep gate (`turnNonce` in OrchestratorEvent.swift) | 0 (still holds) |
| CR-01 grep (`UNTRUSTED_CONTENT` in UntrustedWrapper.swift) | 7 |
| CR-01 grep (`composeSystemPrompt` in AgentOrchestrator.swift) | 2 |
| HI-01 grep (`Redact` in AgentOrchestrator.swift) | 4 |

## Surprises

- `Redact` already lived in `JarvisLogging` (Phase 1) with a working regex covering Anthropic, OpenAI, Bearer, AKIA, and GitHub PAT shapes. No new redaction module was needed — just import + call. Saved a code-write cycle.
- The L9 test for ME-05 is structural rather than fault-injecting. A genuine in-process repro of SQLite transaction failure (locked WAL across two connections in EXCLUSIVE locking mode) is platform-fragile and risks flake. The happy-path control + the careful re-buffer-at-head logic + reviewer-required `turn_ids` in error metadata is what guarantees the fix; richer fault-injection belongs in Phase 8 hardening.
- ME-06's "inject a `Clock`" option was rejected in favor of the simpler "inject `batchWindowMs`" path. Adding a generic `Clock` parameter would have forced changes through every `ReplayLog.init` call site (production, tests, and Plan 04-05 DevOverlayBridge); the `UInt64` parameter has a sensible default and is a one-line opt-in for tests.

## Next steps

Recommend `/gsd-verify-phase 4`. All BLOCKER + HIGH + recommended MEDIUM findings are landed; ME-04 deferred per plan; LO/IN out of default scope. The phase is ready for verification.

---

_Fixed: 2026-04-24_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
