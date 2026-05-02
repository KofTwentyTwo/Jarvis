---
phase: 09-orchestrator-wiring
plan: 03
subsystem: agent
tags: [agent, orchestrator, presence, context-enrichment, vision-03-boundary, int-07-03, d-13, d-14]

# Dependency graph
requires:
  - phase: 09-orchestrator-wiring
    provides: AgentOrchestrator instantiation in installAgent + visionRouter constructor arg (Plans 09-01 + 09-02)
  - phase: 07-memory-vision
    provides: PresenceEvent + Presence enum + PresenceSignalBus + ContextBuilder.installPresence stub (Plans 07-04, 07-05, 07-06)
provides:
  - "PresenceStateSnapshot actor (Vision package) with .shared singleton + record + currentEnrichment(now:) — D-13"
  - "ContextBuilder.installPresence body that drains AsyncStream<PresenceEvent> into PresenceStateSnapshot.shared.record"
  - "AgentOrchestrator constructor gains optional presenceSnapshot: PresenceStateSnapshot? after visionRouter (Plan 2)"
  - "AgentOrchestrator.runTurn appends presenceSnapshot.currentEnrichment() to system prompt OUTSIDE UntrustedWrapper.composeSystemPrompt (SEC-06)"
  - "AppDelegate.installAgent passes PresenceStateSnapshot.shared into the orchestrator"
affects:
  - "Plan 09-04 (voice/text adapters): no surface impact — Plan 4's voice/text adapters and rejection banners are independent of presence enrichment"

# Tech tracking
tech-stack:
  added:
    - "PresenceStateSnapshot actor as the SOLE writer→reader bridge between PresenceSignalBus and the per-turn system prompt"
  patterns:
    - "Plain-sentence injection (D-14) — no XML/JSON tags. Suppression is collapsed into a String? return so the call site is a one-line append"
    - "Trusted enrichment lives OUTSIDE the nonce-wrapped untrusted region (presence text is locally rendered from a typed enum, not user input)"

key-files:
  created:
    - "packages/Vision/Sources/Vision/PresenceStateSnapshot.swift"
    - "packages/Vision/Tests/VisionTests/PresenceStateSnapshotTests.swift"
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorPresenceEnrichmentTests.swift"
  modified:
    - "packages/Vision/Sources/Vision/ContextBuilder.swift (installPresence body now drains into PresenceStateSnapshot.shared)"
    - "packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (constructor + stored property + runTurn enrichment append)"
    - "App/AppDelegate.swift (installAgent passes PresenceStateSnapshot.shared)"

key-decisions:
  - "D-14 sentence wording chosen per CONTEXT.md examples: \"User is at the desk.\" for present and \"User has been away from the desk for N minutes.\" for absent / absentLongTerm. No XML/JSON tags."
  - "5-second present-suppression threshold is computed from observation age (now - observedAt), not from the transition's `at` timestamp. This means the suppression rules (D-14) bite immediately after a transition, regardless of when the transition itself happened — matches the intent of \"don't spam the model on every turn while presence is stable\"."
  - "5-minute absent threshold (D-11) is computed from `since` (the time presence went absent), not from observedAt. This decouples 'how long has the user been away' from 'when did the monitor publish the event' — important when the bus reorders or the snapshot is queried minutes after the transition."
  - "Constructor argument order: presenceSnapshot inserted AFTER visionRouter (Plan 2) per WARNING-1 strict Wave 3 ordering. Plan 2 had already committed in Wave 2 when this plan ran, so the existing `visionRouter:` parameter was preserved unchanged."
  - "Presence enrichment lives OUTSIDE the UntrustedWrapper.composeSystemPrompt result (a separate string concat after composeSystemPrompt returns). This keeps SEC-06's turnNonce-paired-tag invariant intact — the wrapper region never contains presence text, and presence text is rendered from a typed enum (not from user input or tool results) so it does not need to be quarantined."
  - "Documentation comments in PresenceStateSnapshot.swift were rewritten to AVOID using the literal tokens `TTSEngine`, `runTurn`, and `AgentOrchestrator`. The plan's acceptance criterion required `grep -cE \"TTSEngine|runTurn|AgentOrchestrator\" packages/Vision/Sources/Vision/PresenceStateSnapshot.swift == 0`. The first draft used those tokens to explain the boundary; rewording to \"speech-synthesis layer\" / \"agent loop\" / \"App-side install code\" preserves the boundary-explanation while satisfying the gate."
  - "Test 2 (testRunTurnWithPresentSnapshotAppendsSentence) requires a real 5.1s wait because PresenceStateSnapshot.record stamps observedAt with Date() (no injection seam) and currentEnrichment uses Date() by default in production. Tests 4 and 5 use absentLongTerm with a back-dated `since` to get deterministic minute-count assertions without waiting."

requirements-completed: [VIS-06, AGENT-09]

# Metrics
duration: 10min
completed: 2026-05-01
---

# Phase 9 Plan 3: Presence-aware system-prompt enrichment Summary

**PresenceStateSnapshot actor records the latest PresenceEvent and renders a plain-sentence enrichment that AgentOrchestrator.runTurn appends to the system prompt; ContextBuilder.installPresence becomes a real implementation (replacing the 07-06 no-op drain). Closes audit gap INT-07-03 and lights up VIS-06 + AGENT-09. VISION-03 boundary preserved — the snapshot returns only String? to its consumer.**

## Performance

- **Duration:** ~10 min coding + ~6 min waiting on builds/tests (single 5.1s real-time wait inside Test 2 of the enrichment suite)
- **Started:** 2026-05-02T00:58:21Z
- **Completed:** 2026-05-02T01:08:59Z
- **Tasks:** 2 (both autonomous, no checkpoints)
- **Files changed:** 6 (3 created + 3 modified)

## Accomplishments

- **D-13 PresenceStateSnapshot actor.** New `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` with a `.shared` singleton, internal `latest: PresenceEvent?` + `observedAt: Date?`, `record(_:)` populator, and `currentEnrichment(now:)` reader that returns a plain-sentence String?. The actor never exposes PresenceEvent values outward — its only outbound surface is `String?` (VISION-03 invariant).
- **D-14 enrichment rules codified.** present + observation < 5s → nil; present + observation ≥ 5s → "User is at the desk."; absent(since:) + elapsed < 5min → nil; absent(since:) + elapsed ≥ 5min → "User has been away from the desk for N minutes."; absentLongTerm(since:) → "User has been away from the desk for N minutes."; .unknown → nil. The 5-second suppression rule is tested with a deterministic forced `now:` parameter; the absent-minute calculation uses the back-dated `since` field so tests don't need real-time waits.
- **ContextBuilder.installPresence body replaced.** The Phase 7 placeholder `for await _ in stream {}` no-op drain is gone. The detached drain task now calls `await PresenceStateSnapshot.shared.record(event)` for every PresenceEvent. The function is still a `public static` on a `Sendable` struct (07-05's locked surface preserved). VISION-03 grep gate stays green.
- **AgentOrchestrator constructor + runTurn enrichment.** New optional `presenceSnapshot: PresenceStateSnapshot? = nil` parameter inserted AFTER Plan 2's `visionRouter:` (constructor is now 9 args). New stored `private let presenceSnapshot: PresenceStateSnapshot?`. In runTurn, after `UntrustedWrapper.composeSystemPrompt(...)` returns, we await `presenceSnapshot?.currentEnrichment()` and append `\n\n<sentence>` to the composed system prompt iff the call returned non-nil. The wrapper region is unchanged — presence text lives OUTSIDE the nonce-paired tags (SEC-06 preserved).
- **AppDelegate.installAgent wiring.** The orchestrator construction call site now passes `presenceSnapshot: PresenceStateSnapshot.shared` after `visionRouter: self.visionRouter`. Production turns therefore carry ambient presence enrichment in their system prompt whenever PresenceMonitor has published a transition.
- **10 PresenceStateSnapshotTests** prove the actor: initial nil; 5-second suppression on present; present sentence after 10s; absent < 5min nil; absent at 7min sentence; absentLongTerm at 30min sentence; unknown nil; record overwrites prior; return-type is String?; ContextBuilder.installPresence round-trip from AsyncStream into the .shared singleton.
- **5 AgentOrchestratorPresenceEnrichmentTests** prove the orchestrator path: no-snapshot unenriched; present (after real 5.1s wait) appends the suffix; suppressed-present (within 5s window) does NOT append; absentLongTerm appends "User has been away from the desk for 7 [or 8] minutes." (allowing minor minute-rollover drift); two consecutive turns observe the same enrichment (snapshot is read-only on the orchestrator side).

## Task Commits

Each task committed atomically inside the worktree:

1. **Task 1: PresenceStateSnapshot actor + ContextBuilder.installPresence drain + 10 tests** — `b87981c` (feat)
2. **Task 2: AgentOrchestrator constructor + runTurn enrichment + AppDelegate wiring + 5 tests** — `d4af611` (feat)

## Files Created / Modified

### Created

- **`packages/Vision/Sources/Vision/PresenceStateSnapshot.swift`** — `public actor PresenceStateSnapshot` with `.shared` singleton; `record(_:)` + `currentEnrichment(now:)`. ~70 lines including doc comments.
- **`packages/Vision/Tests/VisionTests/PresenceStateSnapshotTests.swift`** — 10 tests covering all D-14 branches plus a ContextBuilder round-trip.
- **`packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorPresenceEnrichmentTests.swift`** — 5 tests covering nil-snapshot, present sentence, 5s suppression, absent away sentence, no-mutation across two turns.

### Modified

- **`packages/Vision/Sources/Vision/ContextBuilder.swift`** — `installPresence(_:)` body changed from `for await _ in stream {}` no-op drain to `for await event in stream { await PresenceStateSnapshot.shared.record(event) }`. Doc comment rewritten to point at Plan 09-03's behavior.
- **`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`** — `presenceSnapshot:` constructor parameter (after `visionRouter:`); stored `private let presenceSnapshot: PresenceStateSnapshot?`; runTurn system-prompt composition now appends `presenceLine` to `composedSystem` outside the UntrustedWrapper region.
- **`App/AppDelegate.swift`** — `installAgent` step 3 (orchestrator construction) now passes `presenceSnapshot: PresenceStateSnapshot.shared`.

## Decisions Made

(Canonical list in the frontmatter `key-decisions`. Highlights below.)

- **Sentence wording.** Chose CONTEXT.md's example phrasing — "User is at the desk." / "User has been away from the desk for N minutes." — to match D-14's intent of natural-language ambient context. Plain-sentence form (no XML/JSON tags).
- **5-second present-suppression** is observation-age based (now − observedAt), not transition-age based (now − transition.at). This means the rule fires immediately after `record()` is called, regardless of how stale the transition itself is. This matches the intent of "don't spam the model on every turn while presence is stable" — the moment the monitor publishes a transition, the snapshot is fresh.
- **5-minute absent-threshold** is `since`-based (now − transition.since(_:)), so "how long has the user been away" decouples cleanly from "when did the monitor publish this event."
- **Constructor argument ordering.** `presenceSnapshot` is inserted AFTER `visionRouter` per WARNING-1's strict Wave-3-after-Wave-2 ordering. Plan 2 had already committed in Wave 2 when Plan 3 ran (worktree-base reset confirmed `87aec28` is the tip), so the existing `visionRouter:` parameter is preserved verbatim.
- **Trusted-region placement.** Presence text is rendered locally from a typed enum (not from user input or tool results), so it does not need to ride inside `UntrustedWrapper.composeSystemPrompt`'s nonce-paired tags. The append happens AFTER `composeSystemPrompt` returns. SEC-06's invariant — "tool_result content is wrapped" — is unaffected.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Plan body's PresenceEvent.transition signature differed from the real enum**
- **Found during:** Task 1 test authoring
- **Issue:** The plan body's example tests used `.transition(to: .present, at: now, debounceWindowMs: 2000)`, but the real PresenceEvent.transition case is `case transition(to: Presence, at: Date, debounced: TimeInterval)` (third label is `debounced:` not `debounceWindowMs:`, and the type is TimeInterval seconds, not Int milliseconds).
- **Fix:** Tests use the real signature: `.transition(to: .present, at: now, debounced: 2.0)`. The PresenceStateSnapshot's pattern-match `case let .transition(presence, _, _)` ignores the debounced field entirely (it's already-applied debounce metadata for replay introspection — not used for enrichment rendering).
- **Files modified:** `packages/Vision/Tests/VisionTests/PresenceStateSnapshotTests.swift`, `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorPresenceEnrichmentTests.swift`, `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` (the source file's pattern-match also adapted)
- **Committed in:** `b87981c` + `d4af611`

**2. [Rule 1 - Bug] Forbidden-token grep failed on PresenceStateSnapshot.swift doc comments**
- **Found during:** Task 1 acceptance-criterion check
- **Issue:** The plan's acceptance criterion `grep -cE "TTSEngine|runTurn|AgentOrchestrator" packages/Vision/Sources/Vision/PresenceStateSnapshot.swift returns 0`. The first draft used those literal tokens in doc comments to EXPLAIN the boundary ("never references TTSEngine or AgentOrchestrator..."). The grep returned 3.
- **Fix:** Reworded doc comments to use "speech-synthesis layer" / "agent loop" / "App-side install code" instead of the literal forbidden tokens. The boundary-explanation intent is preserved; the gate is now satisfied.
- **Files modified:** `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift`
- **Committed in:** `b87981c`

**3. [Rule 1 - Bug] AsyncStream.makeStream is not available; use raw initializer**
- **Found during:** Task 1 test authoring
- **Issue:** The plan body's example used `AsyncStream<PresenceEvent>.makeStream()` which is iOS 18+/macOS 15+ API. The Vision package targets macOS 14, so this would fail to compile.
- **Fix:** Used the captured-continuation pattern: `var continuation: AsyncStream<PresenceEvent>.Continuation!` + `let stream = AsyncStream<PresenceEvent> { cont in continuation = cont }`. Same semantics, available on macOS 14.
- **Files modified:** `packages/Vision/Tests/VisionTests/PresenceStateSnapshotTests.swift`
- **Committed in:** `b87981c`

---

**Total deviations:** 3 auto-fixed (3 Rule 1 bugs).
**Impact on plan:** All three were tactical adaptations to the live codebase. Plan 3's substantive contracts (D-13, D-14, INT-07-03 closure, VISION-03 boundary preservation, constructor-arg ordering after visionRouter) all met. No scope creep, no architectural changes.

## Issues Encountered

- Worktree base was at commit `4f321a7` (one commit before phase-9 plan files landed); `worktree_branch_check` reset to the expected base `4e5dbcd` cleanly. Build subsequently saw all of Plans 1 + 2's commits as expected.
- A pre-existing modification to `App/Resources/webview/index.html` (asset-hash drift from prior local build, also flagged in Plan 1's summary) was left out of all Task commits — environment drift, regenerated by `build-webview.sh`. Not part of this plan's work.
- Test 2 of the orchestrator enrichment suite intentionally sleeps 5.1 seconds because PresenceStateSnapshot.record stamps observedAt with `Date()` (no injection seam) and the orchestrator queries `currentEnrichment()` with default `now = Date()`. Tests 4 and 5 use absentLongTerm + back-dated `since:` to keep their assertions deterministic without waits.

## Next Plan Readiness

- **Plan 09-04 (voice + text adapters):** Plan 3 introduces NO chat-panel surface, NO HUD work, NO Bus protocol changes. Plan 4's voice/text adapters and rejection banners are entirely independent of presence enrichment. The constructor is now 9 args (Plan 1's 7 + Plan 2's `visionRouter` + Plan 3's `presenceSnapshot`) — Plan 4 is not expected to add another constructor parameter, but if it does it should append at the end.
- **`PresenceStateSnapshot.shared`** is owned by `ContextBuilder.installPresence` (sole writer) and `AgentOrchestrator.runTurn` (sole reader, via the optional snapshot dep). Plan 4 must not introduce a third writer or reader on the snapshot.

## Self-Check: PASSED

**Files exist:**
- FOUND: `packages/Vision/Sources/Vision/PresenceStateSnapshot.swift`
- FOUND: `packages/Vision/Tests/VisionTests/PresenceStateSnapshotTests.swift`
- FOUND: `packages/AgentCore/Tests/AgentOrchestratorTests/AgentOrchestratorPresenceEnrichmentTests.swift`

**Commits exist (on this worktree branch):**
- FOUND: `b87981c` (Task 1: PresenceStateSnapshot actor + ContextBuilder drain)
- FOUND: `d4af611` (Task 2: AgentOrchestrator constructor + runTurn enrichment + AppDelegate wiring)

**Tests pass:**
- `swift test --package-path packages/Vision --filter PresenceStateSnapshotTests` → 10/10 pass (incl. ContextBuilder round-trip)
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorPresenceEnrichmentTests` → 5/5 pass
- `swift test --package-path packages/AgentCore` (full suite) → 177/177 pass (no regressions to Plan 1's broadcaster, Plan 2's vision-dispatch, BLOCKER-2 voice tracking, or any Phase 4 orchestrator tests)
- `swift test --package-path packages/AgentCore --filter OrchestratorEventBroadcasterTests` → pass (Plan 1 invariant intact)
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorVisionDispatchTests` → 6/6 pass (Plan 2 invariants intact)
- `swift test --package-path packages/AgentCore --filter AgentOrchestratorVoiceTurnTrackingTests` → 3/3 pass (BLOCKER-2 intact)
- `swift test --package-path packages/Memory --filter MemoryWiringEndToEndTests` → 1/1 pass (BLOCKER-1 intact)
- `bash scripts/check-app-builds.sh` → exit 0 (App target compiles cleanly)
- `bash scripts/check-presence-vision-isolation.sh` → exit 0 (VISION-03 invariant preserved)
- `bash scripts/check-orchestrator-events-single-consumer.sh` → exit 0 (Plan 1 grep gate intact)

**Acceptance grep checks:**
- `grep -c "public actor PresenceStateSnapshot" packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` → 1
- `grep -c "public static let shared = PresenceStateSnapshot()" packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` → 1
- `grep -c "PresenceStateSnapshot.shared.record" packages/Vision/Sources/Vision/ContextBuilder.swift` → 1
- `grep -c "// 07-06 deferred wiring: drain only" packages/Vision/Sources/Vision/ContextBuilder.swift` → 0 (placeholder gone)
- `grep -cE "TTSEngine|runTurn|AgentOrchestrator" packages/Vision/Sources/Vision/PresenceStateSnapshot.swift` → 0 (boundary doc-comment satisfied)
- `grep -c "presenceSnapshot: PresenceStateSnapshot?" packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` → 2 (param + stored property)
- `grep -c "presenceSnapshot?.currentEnrichment" packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` → 1
- `grep -c "presenceSnapshot: PresenceStateSnapshot.shared" App/AppDelegate.swift` → 1

---
*Phase: 09-orchestrator-wiring, Plan 3*
*Completed: 2026-05-01*
