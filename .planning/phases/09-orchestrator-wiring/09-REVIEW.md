---
phase: 09-orchestrator-wiring
reviewed: 2026-05-01T00:00:00Z
depth: standard
files_reviewed: 26
files_reviewed_list:
  - App/AppDelegate.swift
  - App/Tests/AppTests/VoiceOrchestratorAdapterTests.swift
  - App/Vision/AppDelegateFrameAttachAdapters.swift
  - App/Voice/RejectReasonCopy.swift
  - App/Voice/VoiceBusEmitterAdapter.swift
  - App/Voice/VoiceOrchestratorAdapter.swift
  - App/Voice/VoiceTTSAdapter.swift
  - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift
  - packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEventBroadcaster.swift
  - packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift
  - packages/AgentCore/Sources/AgentOrchestrator/TurnTranscriptStore.swift
  - packages/Bus/Sources/Bus/BusInbound.swift
  - packages/Bus/Sources/Bus/BusOutbound.swift
  - packages/Bus/Sources/Bus/Protocol.swift
  - packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift
  - packages/Replay/Sources/Replay/ReplayEvent.swift
  - packages/Replay/Sources/Replay/Schema.swift
  - packages/Vision/Sources/Vision/ContextBuilder.swift
  - packages/Vision/Sources/Vision/PresenceStateSnapshot.swift
  - webview/packages/bus/src/protocol.ts
  - scripts/check-install-order.sh
  - scripts/check-no-null-voice-adapters.sh
  - scripts/check-orchestrator-events-single-consumer.sh
  - scripts/check-presence-vision-isolation.sh
  - packages/AgentCore/Tests/AgentOrchestratorTests/* (8 test files)
  - packages/Bus/Tests/BusTests/CodableRoundTripTests.swift + 4 fixtures (Swift + TS)
findings:
  critical: 0
  warning: 7
  info: 6
  total: 13
status: issues_found
---

# Phase 9: Code Review Report

**Reviewed:** 2026-05-01
**Depth:** standard
**Files Reviewed:** 26
**Status:** issues_found

## Summary

The Phase 9 wiring is structurally sound: `OrchestratorEventBroadcaster` correctly enforces D-05/D-08 (single drain, fan-out via per-priority subscribers), the BLOCKER-1 transcript store + memory wiring closes the long-standing nil-stub regression, and the Bus protocol bump (2.1.0 → 2.3.0) keeps Swift and TS sides in lockstep with hand-written Codable + exhaustive TS switches. The structural gates (D-05, D-08, D-09, D-10, WARNING-5) all have grep-script enforcement plus XCTest mirrors.

Findings cluster around three themes:

1. **Unbounded actor state** — `imageBearingTurns` and `voiceOriginatedTurns` grow forever; the inline comment claiming "kilobytes per session" is correct only if "session" means "one app launch" and the user never leaves Jarvis running for days. There is also no transcript-store cleanup on cancelled / errored / max-tokens / refusal turns, so `TurnTranscriptStore.entries` accumulates partial entries for every non-`endTurn` turn.
2. **Concurrency seams that compile but are unsafe in principle** — `nonisolated(unsafe) private weak var bannerCoordinator` in `VoiceOrchestratorAdapter`, `nonisolated` continuation yields from unrelated actor isolation domains, and an outbound `Task { @MainActor in coord?.enqueue(...) }` that could race with a concurrent `bannerCoordinator?.enqueue` on the main thread.
3. **Test-quality smells** — the `VoiceOrchestratorAdapterTests.testVoiceBusEmitterAdapterForwardsRMSToBatcher` relies on a 60ms sleep to trigger a 10ms drain window (race-prone on loaded CI), and the `recordOnActor`/`sendRaw` indirection in `RecordingSink` introduces a non-obvious actor-hop that masks ordering issues.

No security findings (no plaintext secrets, no shell injection, no eval-equivalent paths). The frame-attach release subscriber path is correct — image-bearing turns release through `FrameAttachController.onAssistantTurnComplete()` only when both `turnHadImage(turnId)` and the broadcaster's `.frameAttach` priority subscription fire.

## Warnings

### WR-01: `imageBearingTurns` / `voiceOriginatedTurns` grow without bound

**File:** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:81-88`
**Issue:** Both `Set<TurnID>` accumulators grow monotonically across the orchestrator's lifetime. The inline comment ("Grows monotonically; pruning is deferred (each entry is the size of a UUID-string TurnID, so even a long-running app accumulates only kilobytes per session)") is wrong about "kilobytes per session" — at ~36 bytes per `TurnID.rawValue` plus Set overhead (~64-80 bytes per entry on Apple Silicon), a Jarvis instance running for a week with 10 turns/hour reaches ~1700 turns × ~80 bytes × 2 sets ≈ **272 KB before container realloc overhead**. More importantly the lookup is `O(1)`, but the *actor isolation domain* must serialize every `turnHadImage` / `turnSourceWasVoice` call from the broadcaster's voice + frame-attach subscribers — the cost is async-hop, not lookup-hop. Correctness is preserved, but the "kilobytes per session" claim is misleading and there's no mechanism to ever shrink the sets.
**Fix:** On `.turnEnd` (and on the existing `currentTurn = nil` paths inside `runTurnLoop`), `remove(turnId)` from both sets after the broadcaster has had a chance to read them. The cleanup must happen AFTER the events fan-out so the voice / frame-attach subscribers can still query — a simple approach is to broadcast a synthetic `.turnRetired(turnId)` event after fan-out drains, or have the broadcaster's drain loop signal back to the orchestrator. Alternatively, cap each set at e.g. 1024 entries with FIFO eviction:
```swift
private func recordVoiceTurn(_ turnId: TurnID) {
    voiceOriginatedTurns.insert(turnId)
    if voiceOriginatedTurns.count > 1024 {
        // FIFO eviction would need an ordered structure;
        // simpler: clear when count exceeds 2048 — accepts a one-time
        // false-negative for ancient turns that subscribers should have
        // long since processed.
    }
}
```

### WR-02: `TurnTranscriptStore.entries` accumulates partial entries on non-`endTurn` terminations

**File:** `packages/AgentCore/Sources/AgentOrchestrator/TurnTranscriptStore.swift:60-70` + `App/AppDelegate.swift:881-892`
**Issue:** `flushPair(_:)` removes the entry only when BOTH `userText` and `assistantText` are non-empty. The transcript subscriber drains `.tokenDelta` events (assistant side) and the voice/text submit handlers append the user side. But on `.error`, `.refusal`, `.maxTokens`, `.streamTruncatedFinal`, or any path where the orchestrator does NOT emit `.turnEnd(stopReason: .endTurn)`, `MemoryExtractionCoordinator`'s drain skips extraction (per D-01) and `flushPair` is never called for that turn. The entry sits in `entries` forever. Same is true for cancelled turns: `cancelAndSubmit` cancels the task but the prior turn's accumulated user-side text + any partial assistant-side text are orphaned.
**Fix:** Wire `discard(_:)` calls from the orchestrator's terminal paths (or from the broadcaster's drain on `.error` / `.turnEnd(stopReason: != .endTurn)` / cancellation) so partial entries don't leak. Concretely, in AppDelegate's transcript subscriber:
```swift
transcriptSubscriberTask = Task { [weak self] in
    for await event in transcriptSub.stream {
        if Task.isCancelled { break }
        guard let self else { break }
        switch event {
        case let .tokenDelta(turnId, text):
            await self.turnTranscriptStore?.append(
                turnId: turnId, role: .assistant, deltaText: text)
        case let .turnEnd(turnId, stopReason) where stopReason != .endTurn:
            await self.turnTranscriptStore?.discard(turnId)
        case let .error(turnId, _):
            await self.turnTranscriptStore?.discard(turnId)
        default: break
        }
    }
}
```
Without this, a long-running session with many cancelled / errored turns accumulates orphan transcript entries (each potentially several KB of streamed text). This is the same pruning concern as WR-01 but with bigger payloads.

### WR-03: `nonisolated(unsafe) weak var bannerCoordinator` in `VoiceOrchestratorAdapter` is the documented escape hatch

**File:** `App/Voice/VoiceOrchestratorAdapter.swift:23`
**Issue:** Marking a stored property `nonisolated(unsafe)` to a non-Sendable `weak var` opts out of Swift 6's data-race checking entirely. The reads in `handleOutcome` happen on the actor's executor (the `Task { @MainActor }` inner closure captures `coord`, which is read once), so in practice there's no race today — but the moment a future change reads `bannerCoordinator` from a different isolation context (or assigns to it from anywhere), the compiler will not catch the race. The weakness is documented ("nonisolated(unsafe)") but contradicts the Phase 9 plan's strict-concurrency posture (`SWIFT_STRICT_CONCURRENCY: complete` in `project.yml`).
**Fix:** Either (a) make `bannerCoordinator` a strong reference passed by closure injection (`@Sendable () -> HUDBannerCoordinator?`) so the actor never holds the `weak var` directly, or (b) move banner enqueue to `AppDelegateBannerAdapter` (which already conforms to `VoiceBannerInterface` via `@unchecked Sendable`) and have `VoiceOrchestratorAdapter` accept an `any VoiceBannerInterface` instead of the concrete coordinator. Option (b) matches the existing pattern in `installVoice` where `AppDelegateBannerAdapter(coordinator: bannerCoordinator)` is built and passed to `VoiceController`.

### WR-04: `bannerForReason` priority hardcoded to 5; collision risk with future banner content

**File:** `App/Voice/VoiceOrchestratorAdapter.swift:96`
**Issue:** Voice rejection banners are enqueued at priority 5. Existing `BannerContent` presets use 1-3 (hard blocks), 10 (voice-aec), 99 (dev-overlay-stub), and 2 (`hud-not-ready` — assigned at the call site). Future banner content additions in the 4-9 range will silently re-order ahead of or behind voice rejections without any structural test catching the drift. The doc-comment claims "above voice-aec-banner (10) and below wizard / hard-block banners (1-3)" — that's correct only because no other banner uses 4-6 today.
**Fix:** Add a typed banner-priority enum (or constants on a `BannerPriority` namespace) and reference it here so a future grep sees `BannerPriority.voiceRejection.rawValue` as the magic number, not bare `5`. Alternatively, add an XCTest that enumerates every known `BannerContent` preset and asserts non-overlap.

### WR-05: `voiceEventTranslatorTask` per-turn dictionary leaks on error paths that don't emit `.error`

**File:** `App/AppDelegate.swift:946-980`
**Issue:** The voice subscriber drains a `var perTurnAssistantText: [TurnID: String] = [:]` keyed by turnId. Entries are removed on `.turnEnd` and on `.error`, but the orchestrator's `runTurnLoop` cancellation path returns early on `Task.isCancelled` WITHOUT emitting `.error` for the cancelled turn (line 366-369: "cancelAndSubmit called endTurn; just exit"). So if a voice turn is cancelled mid-stream by `cancelAndSubmit` (barge-in), accumulated `.tokenDelta` text for that turn is orphaned in `perTurnAssistantText`. The orphan is small (a partial assistant message) and bounded by the number of in-flight voice barge-ins, but in a heavy barge-in session the dictionary grows.
**Fix:** When `cancelAndSubmit` is called from the voice path, also emit a `.cancelled` event on the voice events stream (already done — `eventsCont.yield(.cancelled)` in `VoiceOrchestratorAdapter.cancelAndSubmit`). Then the voice subscriber drain should remove the prior turn's entry on cancellation. But — the voice subscriber drains `OrchestratorEvent`, not `VoiceOrchestratorEvent`, so it never sees `.cancelled`. The structural fix is to make the broadcaster's voice subscriber gate on a `.turnEnd(stopReason: .cancelled)` synthetic event from the orchestrator, OR have the orchestrator emit a `.error` event when a turn is cancelled mid-stream so the existing branch handles cleanup.

### WR-06: `MemoryExtractionCoordinator.start` — `subscription` is a `Task.detached` capturing `[weak self]` but the body closes over `turnContent` strongly

**File:** `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift:54-80`
**Issue:** The drain task is `Task.detached { [weak self] in ... }`, so `self` is captured weakly — good. But the closure `turnContent` (typed `@Sendable (TurnID) async -> (user: String, assistant: String)?`) is captured strongly. In `installAgent`, the closure is built as `{ [weak self] turnId in ... await self?.turnTranscriptStore?.flushPair(turnId) ... }`, so the weak self pattern is preserved. However, the closure is also captured in the detached task itself (via `subscription = Task.detached { ... turnContent(turnId) ... }`), and there is no explicit weak capture of `turnContent` — this is fine because closures are reference-types-via-heap-allocation and the closure's own retain cycle would only matter if it captured `self` strongly. Verified: the closure created in AppDelegate uses `[weak self]` correctly. This is a non-issue for retain cycles, but the comment chain mixes concerns; consider strengthening the doc-comment to make explicit that the strong-capture of `turnContent` is intentional and bounded by the subscription's lifetime.
**Fix:** Add a one-liner doc explaining that `turnContent` may strongly capture the AppDelegate-built closure but the detached task's `[weak self]` ensures `MemoryExtractionCoordinator` itself doesn't outlive AppDelegate.

### WR-07: `VoiceOrchestratorAdapterTests.testVoiceBusEmitterAdapterForwardsRMSToBatcher` uses 60ms sleep — race-prone on CI

**File:** `App/Tests/AppTests/VoiceOrchestratorAdapterTests.swift:107-137`
**Issue:** The test creates an `OutboundBatcher(sink: sink, windowMillis: 10)` and sleeps for 60ms before snapshotting. On a loaded CI machine, the batcher's drain task may not have fired within 60ms (the window is 10ms but the scheduler can stretch sleep arbitrarily under load). The test's failure mode is `XCTAssertEqual(recorded.count, 1)` failing with `recorded.count == 0` — a flake, not a regression. Any timer-driven test in CI should poll-with-deadline rather than fixed-sleep.
**Fix:** Replace the fixed sleep with a poll loop:
```swift
let deadline = Date().addingTimeInterval(2.0)
while Date() < deadline {
    let snap = await sink.snapshot()
    if !snap.isEmpty { break }
    try await Task.sleep(for: .milliseconds(20))
}
```
Same pattern used in `OrchestratorEventBroadcasterTests.testDropOldestOnTokenDeltaSaturation` (lines 113-117) — that's the right idiom; this test slipped past it.

## Info

### IN-01: `eventsCont.yield(.cancelled)` is fired from the actor's caller side BEFORE `cancelAndSubmit` actually cancels the prior turn

**File:** `App/Voice/VoiceOrchestratorAdapter.swift:49`
**Issue:** `cancelAndSubmit` does `eventsCont.yield(.cancelled)` then `await orchestrator.cancelAndSubmit(.voice(text))`. The `.cancelled` event reaches `VoiceController.handleOrchestratorEvent` BEFORE the orchestrator actually finishes cancelling (the orchestrator's cancel-and-await drain is synchronous from the caller's perspective, but the event ordering relative to the broadcaster's voice subscriber is: voice events stream gets `.cancelled` immediately, broadcaster's voice subscriber will get a future `.turnEnd` for the new turn after it completes). VoiceController's `.cancelled` arm is a `break` no-op — fine — but the ordering is subtle. A future change that adds non-trivial logic to the `.cancelled` arm could trip on the assumption that the prior turn's cleanup has completed.
**Fix:** Document the ordering or move the yield AFTER the cancel:
```swift
let outcome = await orchestrator.cancelAndSubmit(.voice(text))
eventsCont.yield(.cancelled)  // moved post-cancel
```
This guarantees `.cancelled` reaches the controller after the cancel completes, at the cost of slightly delayed UI state.

### IN-02: `VoiceTTSAdapter.synthesize` swallows synthesis errors silently

**File:** `App/Voice/VoiceTTSAdapter.swift:52`
**Issue:** `try? await engine.synthesize(...)` swallows all errors. The doc-comment says "the underlying error is already logged through TTSEvent and JarvisLogChannel.tts" — true, but if `TTSEngineActor.synthesize` is later refactored to throw a class of error not logged through TTSEvent, the failure becomes silent. Defense-in-depth would route the error through the Voice package's existing error surface.
**Fix:** Replace `try? await` with a `do/catch` that explicitly logs through `JarvisLogChannel.tts` so removing the in-engine logging doesn't accidentally make TTS failures undetectable:
```swift
do {
    try await engine.synthesize(text, tier: tier, voice: voiceId)
} catch {
    Logger(label: JarvisLogChannel.tts.rawValue)
        .warning("VoiceTTSAdapter.synthesize threw: \(error)")
}
```

### IN-03: `FrameAttachReplaySinkAdapter.recordPlaceholder` retains `replayLog` solely to avoid an "unused let" warning

**File:** `App/Vision/AppDelegateFrameAttachAdapters.swift:62-67`
**Issue:** The adapter's `recordPlaceholder` method does `_ = replayLog` to silence the unused-property warning. The doc-comment documents this is for a future-plan migration. Today, the adapter logs to `JarvisLogChannel.replay` and never persists the placeholder to the events table (per the FK constraint discussion). This is intentional and well-documented, but the dead-store hint flags as a smell to future readers.
**Fix:** Either (a) add an underscore prefix to the property name (`_replayLog`) to signal "captured-but-unused-yet", or (b) leave a `#warning("FrameAttachReplaySinkAdapter.replayLog is captured for the upcoming TurnID-threading migration; remove this warning when the persistence path lands.")` so the dead capture is visible in build output.

### IN-04: `EscalationKind` enum has only one case but uses `switch` exhaustiveness — single-case enum smell

**File:** `packages/Replay/Sources/Replay/ReplayEvent.swift:80-83` + `packages/Replay/Tests/ReplayTests/EscalationAttemptMarkerTests.swift:48-55`
**Issue:** `EscalationKind` is declared as an enum with a single `.t1ToT2` case. The test `testEscalationAttemptKindIsExtensible` is a compile-time pin that "if we add `.t2ToT3` later, this test breaks at compile-time and forces an explicit decision." Today the encoding round-trip (`.t1ToT2 → "t1_to_t2"`) and the `kind == .t1ToT2 ? "t1_to_t2" : "unknown"` ternary in `ReplayEvent.encoded()` are both effectively dead branches (`unknown` is unreachable). When a second case is added, the `else "unknown"` arm becomes a silent fallback for any new case the encoder forgot to handle.
**Fix:** Replace the ternary with an exhaustive switch:
```swift
let kindString: String
switch kind {
case .t1ToT2: kindString = "t1_to_t2"
}
```
This forces a compile error when `.t2ToT3` is added rather than silently encoding it as `"unknown"`.

### IN-05: `ContextBuilder.installPresence` spawns an unmanaged `Task.detached`

**File:** `packages/Vision/Sources/Vision/ContextBuilder.swift:37-43`
**Issue:** `installPresence` spawns a detached task that drains `stream` indefinitely. There is no handle returned, so no cancellation point exists. If `installPresence` is ever called twice (e.g. test seam re-runs), two detached tasks accumulate, each draining the (now-finished) stream. The test `testContextBuilderInstallPresenceWritesToSnapshot` exercises this pattern by yielding then `finish()`-ing the continuation, which lets the drain task complete naturally — but in production `bus.stream` is open for the lifetime of the app, so this is conceptually a one-shot.
**Fix:** Either (a) return the `Task` so AppDelegate can cancel it on shutdown, or (b) document explicitly that this is a fire-and-forget that runs for app lifetime and add a one-line idempotency guard (e.g. a `static var installed: Bool` mutex). Today only AppDelegate calls this once, so it's correct in practice.

### IN-06: `BUS_PROTOCOL_VERSION` parity gate runs at xcodebuild pre-build but not in `swift test`

**File:** `project.yml:222-229` + `packages/Bus/Sources/Bus/Protocol.swift:28` + `webview/packages/bus/src/protocol.ts:18`
**Issue:** The pre-build script `check-bus-protocol-version.sh` enforces Swift/TS version parity at xcodebuild time. Standalone `swift test` runs (e.g. CI matrix that runs SPM tests independently of the Xcode app target) skip the gate. The CodableRoundTripTests asserts the Swift-side fixture content but doesn't read `BUS_PROTOCOL_VERSION` against any expectation; the TS side does check `expect(BUS_PROTOCOL_VERSION).toBe("2.3.0")` but that's hard-coded to 2.3.0, not derived from the Swift constant.
**Fix:** Add a Swift-side test asserting `BUS_PROTOCOL_VERSION == "2.3.0"` so a Swift-only `swift test` regression catches future bumps that update one side without the other. Trivial:
```swift
func test_busProtocolVersionMatchesExpected() {
    XCTAssertEqual(BUS_PROTOCOL_VERSION, "2.3.0")
}
```
Same idiom on the TS side already exists. Together they form a redundant tripwire.

---

## Notable strengths (not findings — context for future review)

1. **D-05 / D-08 single-drain enforcement is robust** — `OrchestratorEventBroadcaster.start()` is idempotent (cancels prior task), the `for await` in the drain task uses `[weak self]` correctly, and the `scripts/check-orchestrator-events-single-consumer.sh` regex correctly excludes the constructor-arg pattern (`OrchestratorEventBroadcaster(upstream: orchestrator.events)`) while flagging any direct iteration outside the broadcaster file.

2. **D-07 protection matrix is table-tested** — `OrchestratorEventBroadcasterTests.testIsProtectedForPriorityMatrix` enumerates all 7 event types × 5 priorities and asserts each cell of the table. Adding a new priority or event class without updating the matrix fails this test deterministically.

3. **Hand-written Codable in BusOutbound / BusInbound is the right call** — the doc-comment at `BusOutbound.swift:6-12` correctly explains why SE-0295 synthesis would break TS parity, and the round-trip tests have an explicit "synthesized shape didn't leak" assertion. Adding a case without a switch arm is a compile error in both Swift (exhaustive switch) and TypeScript (exhaustiveness via `const _exhaustive: never = type`).

4. **BLOCKER-1 has both unit + end-to-end coverage** — `TurnTranscriptStoreTests` (7 unit tests) + `MemoryWiringEndToEndTests.testMemoryEnqueueReceivesNonNilUserAndAssistantText` (the regression-anchor test that actually drives the broadcaster + transcript store + memory coordinator wiring).

5. **HI-01 redaction hits the bus AND replay paths** — `AgentOrchestrator.redact(_:)` is called at both the `.providerError` event arm and the catch-boundary, so credential-shaped substrings can't leak into either the webview or persistent storage. Single redaction site (the `Redact.apply` regex lives in `JarvisLogging`).

6. **The actor-reentrancy guard in `cancelAndSubmit` is correct and tested** — `OC3` test asserts `currentTurn` after cancelAndSubmit returns is NOT the prior id, which would only fail if the `await task.value` drain were missing. The throttled mock ensures the race window is real, not just a nominal sequence.

---

_Reviewed: 2026-05-01_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
