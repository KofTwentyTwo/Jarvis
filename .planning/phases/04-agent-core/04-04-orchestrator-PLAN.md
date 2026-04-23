---
phase: 04-agent-core
plan: 04
type: execute
wave: 3
depends_on: [01, 02, 03]
files_modified:
  - packages/AgentCore/Package.swift
  - packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift
  - packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift
  - packages/AgentCore/Sources/AgentCore/SubmitOutcome.swift
  - packages/AgentCore/Sources/AgentCore/TurnInput.swift
  - packages/AgentCore/Sources/AgentCore/PerTurnSnapshot+Agent.swift
  - packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift
  - packages/AgentCore/Sources/AgentCore/TurnNonce.swift
  - packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift
  - packages/AgentCore/Sources/AgentCore/ToolDispatcher.swift
  - packages/AgentCore/Sources/AgentCore/TurnState.swift
  - packages/AgentCore/Sources/AgentCore/RetryState.swift
  - packages/AgentCore/Tests/AgentCoreTests/UntrustedWrapperTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/ToolResultPackerTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/TurnNonceTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/OrchestratorSubmitTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/OrchestratorCancelTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/OrchestratorRetryTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/OrchestratorCapRecoveryTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/MockLLMProvider.swift
autonomous: true
requirements: [AGENT-06, AGENT-07, AGENT-08, AGENT-09, SEC-06]
must_haves:
  truths:
    - "AgentOrchestrator is an actor with submit(_:) and cancelAndSubmit(_:) as the only turn-lifecycle entry points (AGENT-06)"
    - "SubmitOutcome has exactly three cases: .ran(turnId), .superseded(priorId, reason), .rejected(reason) (AGENT-06)"
    - "cancelAndSubmit cancels the in-flight Turn.task and awaits task completion BEFORE assigning a new currentTurn — no actor-reentrancy race on .messageStop from the cancelled stream"
    - "Per-turn turnNonce is 16 random bytes (SecRandomCopyBytes), base64url-encoded ≈ 22 chars (SEC-06)"
    - "UntrustedWrapper.wrap(content:) strips tag-like substrings (regex `</?UNTRUSTED_CONTENT[^>]*>`) BEFORE wrapping with paired nonce tags (SEC-06)"
    - "turnNonce is persisted in ReplayLog via startTurn(turnNonce:) — never included in OrchestratorEvent emitted to the bus (SEC-06 — nonce never crosses to webview)"
    - "OrchestratorEvent enum has no field named `turnNonce` or containing nonce bytes — enforced by a grep gate + a compile-time inspection test"
    - "Tool-result content is capped at 8 KB with a truncation marker appended to the model-facing message; the full blob writes to ReplayLog via .toolResultFull (AGENT-08)"
    - "stream_truncated retry is bounded at exactly 1 per turn; second truncation in the same turn is terminal .providerError(.streamTruncatedFinal) (AGENT-09)"
    - "Retry turn gets a fresh turnId; ReplayLog.startTurn is called with retryOf = originalTurnId (AGENT-09)"
    - "Retry re-reads PerTurnSnapshot — config changes between original attempt and retry are honored (AGENT-09)"
    - "Retry resets tool-call budget — partial progress on first attempt does not count against retry (AGENT-09)"
    - "Tool-call budget exceeded triggers cap-recovery: rebuild prompt with toolChoice: .none, re-invoke provider.stream(...) — AGENT-07 acceptance"
    - "When submit() is called with a turn in flight, SubmitOutcome.rejected(.turnInFlight) is returned without touching the live turn"
    - "When cancelAndSubmit() is called with a turn in flight, the prior turn's task.cancel() is called, the task is awaited to completion, and then a new turn begins; prior turn's id appears in .superseded(priorId:reason:)"
    - "MockLLMProvider is a test-only LLMProvider implementation with a scriptable event sequence; used by all 4 orchestrator test files"
  artifacts:
    - path: "packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift"
      provides: "The turn-lifecycle actor; single entry point for text/voice/memoryExtraction turns (AGENT-06)"
      contains: "AgentOrchestrator"
    - path: "packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift"
      provides: "SEC-06 turnNonce wrapping with tag-strip prefilter"
      contains: "UNTRUSTED_CONTENT"
    - path: "packages/AgentCore/Sources/AgentCore/TurnNonce.swift"
      provides: "SecRandomCopyBytes(16) wrapper returning base64url-encoded 22-char nonces"
      contains: "SecRandomCopyBytes"
    - path: "packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift"
      provides: "AGENT-08 8KB cap with truncation marker; full blob routes to ReplayLog separately"
      contains: "TRUNCATED"
    - path: "packages/AgentCore/Sources/AgentCore/SubmitOutcome.swift"
      provides: "AGENT-06 three-case displacement primitive"
      contains: "superseded"
    - path: "packages/AgentCore/Tests/AgentCoreTests/MockLLMProvider.swift"
      provides: "Scriptable test provider used across all orchestrator tests"
      contains: "MockLLMProvider"
  key_links:
    - from: "packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift"
      to: "packages/AgentCore/Sources/AgentCore/TurnNonce.swift"
      via: "runTurn() generates a fresh TurnNonce per turn; passes to ReplayLog and UntrustedWrapper"
      pattern: "TurnNonce"
    - from: "packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift"
      to: "packages/Replay/Sources/Replay/ReplayLog.swift"
      via: "startTurn(turnNonce:...) + record(_:for:) + endTurn(_:stopReason:) lifecycle"
      pattern: "ReplayLog"
    - from: "packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift"
      to: "packages/Replay/Sources/Replay/ReplayEvent.swift"
      via: "Full blob is emitted as ReplayEvent.toolResultFull; capped blob goes into LLMMessage.toolResult"
      pattern: "toolResultFull"
    - from: "packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift"
      to: "packages/AgentCore/Sources/AgentCore/RetryState.swift"
      via: "stream_truncated retry path: budget -= 1; fresh turnId; retryOf = original"
      pattern: "retryOf"
---

<objective>
Deliver the `AgentOrchestrator` actor — the heart of Phase 4 — which owns turn lifecycle, tool dispatch, injection defense, replay logging, and retry logic. Single entry point `submit(_:)`; single barge-in primitive `cancelAndSubmit(_:)`. All provider interaction goes through the `LLMProvider` protocol from Plan 04-01; all replay writes go through `ReplayLog` from Plan 04-03; tool dispatch uses `ToolDispatcher` (a protocol implemented by mock adapters in P4 tests, and by the real MCP client in Plan 05).

Purpose: Plans 04-01 through 04-03 built the components. This plan wires them into a coherent turn state machine. AGENT-06 (submit/cancelAndSubmit/SubmitOutcome), AGENT-08 (8KB tool-result cap), AGENT-09 (stream_truncated retry), and SEC-06 (turnNonce injection defense) all land here. AGENT-07 cap-recovery (tool-choice .none) lands here too — the providers serialize it correctly, but the orchestrator is what actually invokes it when budget is exhausted.

Output: An orchestrator that can run a turn end-to-end against a `MockLLMProvider` test fixture, correctly emits `SubmitOutcome` across race conditions (in-flight submission, barge-in during streaming), handles all six edge cases via mocked provider output (cap recovery, stream truncation retry, turn supersession), and produces a clean replay-log record + emits `OrchestratorEvent`s ready for Plan 04-05 to wire into the bus / HUD / DevOverlay.

**Scope note:** ~20 files, above the threshold. Four tasks: Task 1 = injection defense + tool-result packer (pure functions, foundational); Task 2 = orchestrator actor + turn state machine + submit / cancelAndSubmit; Task 3 = stream_truncated retry + cap-recovery paths; Task 4 = comprehensive test matrix using MockLLMProvider. Commits atomic per task.

This plan is Wave 3 — must run AFTER Plans 04-01, 04-02, 04-03. The MockLLMProvider in Task 4 conforms to `LLMProvider` from Plan 04-01. ReplayLog from Plan 04-03 is injected as an actor. ToolDispatcher (the mock one for P4) is an inline closure-based test double.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/STATE.md
@.planning/phases/04-agent-core/04-RESEARCH.md
@.planning/phases/04-agent-core/04-01-SUMMARY.md
@.planning/phases/04-agent-core/04-02-SUMMARY.md
@.planning/phases/04-agent-core/04-03-SUMMARY.md

<interfaces>
From Plan 04-01:
- `LLMProvider` protocol with mandatory toolChoice.
- `LLMEvent`, `StopReason`, `ToolUseRequest`, `TurnUsage`, `LLMMessage` with `untrusted: Bool`, `ToolSchema`, `ToolChoice`, `ModelID`, `CacheHints`, `TurnID`, `LLMProviderError`, `BoundedAsyncChannel`.

From Plan 04-02:
- `AnthropicProvider` actor — consumed via LLMProvider protocol only (orchestrator does not reference by concrete type in tests).
- `OllamaProvider` actor — same.

From Plan 04-03:
- `ReplayLog` actor with beginSession/startTurn/record/endTurn/close.
- `ReplayEvent` enum with ten cases.
- `SessionID`, `TurnSource`, `OrphanDetector`.
- `TokenDeltaDropOldestChannel<Tag>` actor.

From Phase 1:
- `PerTurnSnapshot` — extended in this plan via a dedicated file `PerTurnSnapshot+Agent.swift` adding agent-specific read helpers (e.g., `perTurn.resolvedProvider() -> ProviderSelection`, `perTurn.maxToolCallsPerTurn() -> Int`).
- `ConfigStore` actor with `perTurn()` and `stream()`.

This plan ESTABLISHES (consumed by Plan 04-05):

- `AgentOrchestrator` actor with submit / cancelAndSubmit.
- `SubmitOutcome` enum.
- `TurnInput` struct (user text + TurnSource + optional prior-context tag).
- `OrchestratorEvent` enum (what the orchestrator emits to downstream consumers): cases for stateChange, toolCardUpdate, tokenDelta, turnEnd, confirmationRequest, error.
- `ToolDispatcher` protocol (stub in P4, real in P5).
- `TurnState` enum (internal state machine states, exposed for DevOverlay).
</interfaces>

<codebase_patterns>
- `nonisolated(unsafe)` for Apple non-Sendable types (established Plan 01-02 pattern).
- Swift 6 strict concurrency on every target.
- Keychain fetch-per-request via `@Sendable () async throws -> String` closure (pattern from Plan 04-01 AnthropicProvider).
- Logs go through `Logger(label: JarvisLogChannel.agent.rawValue)` and `Logger(label: JarvisLogChannel.replay.rawValue)`.
- Actor reentrancy hazard: `await` inside an actor method releases isolation. For `cancelAndSubmit` race safety, use explicit Task handles and `await task.value` to serialize correctly.
- Test doubles live in the Tests directory with access-level `internal`; `@testable import AgentCore` brings them into scope. MockLLMProvider is a full LLMProvider conformance (not a partial mock).
</codebase_patterns>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Injection defense — TurnNonce + UntrustedWrapper + ToolResultPacker</name>
  <files>
    packages/AgentCore/Sources/AgentCore/TurnNonce.swift,
    packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift,
    packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift,
    packages/AgentCore/Tests/AgentCoreTests/TurnNonceTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/UntrustedWrapperTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/ToolResultPackerTests.swift
  </files>
  <behavior>
    - Test TN1 (TurnNonceTests): `TurnNonce.fresh()` returns a non-empty string; two calls return different values (10,000 iterations, zero collisions).
    - Test TN2 (TurnNonceTests): Format — base64url alphabet only (`[A-Za-z0-9_-]+`), length between 20 and 24 chars (16 random bytes → 22 base64url chars typical; no padding).
    - Test TN3 (TurnNonceTests): `TurnNonce.fresh().rawValue` contains no `+`, `/`, or `=` characters (true base64url, not classic base64).
    - Test UW1 (UntrustedWrapperTests): `UntrustedWrapper(nonce:).wrap("hello world")` returns `<UNTRUSTED_CONTENT id="<nonce>">\nhello world\n</UNTRUSTED_CONTENT id="<nonce>">`.
    - Test UW2 (UntrustedWrapperTests): Content containing `</UNTRUSTED_CONTENT id="fake">` is pre-stripped (replaced with `[REDACTED_TAG]`) BEFORE wrapping; the resulting wrapped output contains `[REDACTED_TAG]` inside the wrapper and the attacker's tag is neutralized.
    - Test UW3 (UntrustedWrapperTests): Content containing `<UNTRUSTED_CONTENT id="x">` (open tag) also pre-stripped.
    - Test UW4 (UntrustedWrapperTests): Case-sensitive — content with `<untrusted_content>` (lowercase) is NOT stripped (we match the exact literal our agent emits). Document this decision in a comment.
    - Test UW5 (UntrustedWrapperTests): Multiple nested tag attempts in a single payload are all stripped; 5 tag-like substrings become 5 REDACTED_TAG markers.
    - Test TP1 (ToolResultPackerTests): Input 4 KB Data → `packedForModel` returns the full string decoded from the bytes (no truncation); `fullForReplay` returns the original Data unchanged.
    - Test TP2 (ToolResultPackerTests): Input 16 KB Data → `packedForModel` returns the first 8192 bytes decoded as UTF-8 + a truncation marker `\n\n[TRUNCATED: 8192 bytes omitted; full blob in replay log]`; `fullForReplay` returns the full 16 KB Data.
    - Test TP3 (ToolResultPackerTests): Input exactly 8192 bytes → no truncation marker (equal-to-cap is not over).
    - Test TP4 (ToolResultPackerTests): Input 16 KB with a multi-byte UTF-8 boundary at byte 8192 — the packed string uses `String(decoding: capped, as: UTF8.self)` which replaces invalid bytes with U+FFFD (no crash). Assert no precondition failure.
    - Test TP5 (ToolResultPackerTests): The truncation marker text is deterministic and grep-able — assert it contains "TRUNCATED" and "full blob in replay log".
  </behavior>
  <action>
**`TurnNonce.swift`**:

```swift
import Foundation
import Security

public struct TurnNonce: Sendable, Equatable, Hashable {
    public let rawValue: String

    public static func fresh() -> TurnNonce {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed — cryptographic primitive unavailable")
        return TurnNonce(rawValue: Data(bytes).base64URLEncodedString())
    }

    private init(rawValue: String) { self.rawValue = rawValue }
}
```

Note: `Data.base64URLEncodedString()` was already created in Plan 04-01 Task 2 (AnthropicProvider's `Base64URL.swift`) but scoped `internal` to the AnthropicProvider target. Promote it to `AgentCore` by moving `Base64URL.swift` from `Sources/AnthropicProvider/` to `Sources/AgentCore/` and making it `public` (or `internal` — either works since both targets are in the same package). If Plan 04-01 already made it public, just reuse. Otherwise: either re-declare in TurnNonce.swift (duplicate extension), OR move the file. **Prefer move** — cleaner module boundaries. Update Plan 04-01's references accordingly (AnthropicProvider now imports AgentCore for Base64URL; already does for LLMEvent).

**`UntrustedWrapper.swift`**:

```swift
import Foundation

public struct UntrustedWrapper: Sendable {
    public let nonce: TurnNonce

    public init(nonce: TurnNonce) { self.nonce = nonce }

    public func wrap(_ untrusted: String) -> String {
        // 1. Strip any tag-like substring that could close our wrapper early.
        //    Match opening or closing tags (case-sensitive, exact literal).
        let pattern = #"</?UNTRUSTED_CONTENT[^>]*>"#
        let stripped = untrusted.replacingOccurrences(
            of: pattern, with: "[REDACTED_TAG]",
            options: .regularExpression
        )
        // 2. Wrap with paired tags carrying the per-turn nonce.
        return """
        <UNTRUSTED_CONTENT id="\(nonce.rawValue)">
        \(stripped)
        </UNTRUSTED_CONTENT id="\(nonce.rawValue)">
        """
    }
}
```

Document in a header comment:
- Case-sensitivity is intentional. An attacker crafting `<untrusted_content>` (lowercase) cannot close our wrapper because our wrapper emits uppercase.
- Tag-strip runs BEFORE wrapping — order matters. Reversed order would allow tags through if the attacker included matching-case tag strings.

**`ToolResultPacker.swift`**:

```swift
import Foundation

public enum ToolResultPacker {
    /// Cap for model-facing tool_result content in bytes.
    /// Rationale (AGENT-08): Opus 4.7 tokenizer produces ~1.35× tokens vs Opus 3.x;
    /// 8 KB at ~3.5 chars/token old ratio = ~9K tokens, at Opus 4.7 ratio ~12K tokens.
    /// Three tool calls / turn × 12K = 36K tokens which is manageable on a 1M-context model but
    /// conservative against context blowout. Revisit empirically via DevOverlay cache-ratio signal.
    public static let modelFacingCapBytes: Int = 8 * 1024

    /// Result of packing: (model-facing content, full bytes for replay, wasCapped).
    public struct Packed: Sendable {
        public let modelFacing: String
        public let fullBytes: Data
        public let wasCapped: Bool
        public let omittedByteCount: Int
    }

    public static func pack(_ raw: Data) -> Packed {
        let cap = modelFacingCapBytes
        let capped = raw.prefix(cap)
        let wasCapped = raw.count > capped.count
        let omitted = raw.count - capped.count
        let modelFacing: String
        if wasCapped {
            let head = String(decoding: capped, as: UTF8.self)
            modelFacing = head + "\n\n[TRUNCATED: \(omitted) bytes omitted; full blob in replay log]"
        } else {
            modelFacing = String(decoding: capped, as: UTF8.self)
        }
        return Packed(
            modelFacing: modelFacing,
            fullBytes: raw,
            wasCapped: wasCapped,
            omittedByteCount: omitted
        )
    }
}
```

Write the three test files with the 13 tests from `<behavior>`.

Commit: `feat(04-04): TurnNonce + UntrustedWrapper + ToolResultPacker — SEC-06 injection defense + AGENT-08 8KB cap`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-04-t1.log && swift test --filter TurnNonceTests --filter UntrustedWrapperTests --filter ToolResultPackerTests 2>&1 | tee /tmp/test-04-04-t1.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-04-t1.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter TurnNonceTests --filter UntrustedWrapperTests --filter ToolResultPackerTests` exits 0 with 13 tests passing.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/TurnNonce.swift | grep -c 'SecRandomCopyBytes'` equals 1.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift | grep -c 'UNTRUSTED_CONTENT'` at least 2.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift | grep -c 'REDACTED_TAG'` equals 1.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift | grep -c 'TRUNCATED'` at least 1.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift | grep -c '8 \\* 1024\\|8192'` at least 1 (the cap constant).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: AgentOrchestrator actor — turn state machine + submit / cancelAndSubmit (AGENT-06)</name>
  <files>
    packages/AgentCore/Package.swift,
    packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift,
    packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift,
    packages/AgentCore/Sources/AgentCore/SubmitOutcome.swift,
    packages/AgentCore/Sources/AgentCore/TurnInput.swift,
    packages/AgentCore/Sources/AgentCore/PerTurnSnapshot+Agent.swift,
    packages/AgentCore/Sources/AgentCore/ToolDispatcher.swift,
    packages/AgentCore/Sources/AgentCore/TurnState.swift,
    packages/AgentCore/Tests/AgentCoreTests/MockLLMProvider.swift,
    packages/AgentCore/Tests/AgentCoreTests/OrchestratorSubmitTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/OrchestratorCancelTests.swift
  </files>
  <behavior>
    - Test OS1 (OrchestratorSubmitTests): Fresh orchestrator, no turn in flight → `submit(TurnInput.text("hello"))` returns `.ran(turnId:)` with a UUID-shaped turnId; orchestrator emits `.stateChange(.thinking)` on its event stream; when MockLLMProvider completes, emits `.stateChange(.idle)` and `.turnEnd(turnId:, stopReason:.endTurn)`.
    - Test OS2 (OrchestratorSubmitTests): While a turn is in flight (MockLLMProvider holds the stream open on a throttle), a second `submit()` returns `.rejected(.turnInFlight)` — no state change, prior turn continues uninterrupted.
    - Test OS3 (OrchestratorSubmitTests): MockLLMProvider yields 5 textDeltas; orchestrator emits 5 `.tokenDelta` events to its output channel in the same order.
    - Test OS4 (OrchestratorSubmitTests): MockLLMProvider yields 1 toolUseRequested for "get_time"; orchestrator calls ToolDispatcher.dispatch(toolUse:); on receipt of ToolResult, orchestrator appends a .toolResult LLMMessage to history; orchestrator re-invokes provider.stream (loop iteration). This tests the basic tool-call loop shape.
    - Test OS5 (OrchestratorSubmitTests): ReplayLog.startTurn is called with the fresh turnId, session_id, retryOf=nil, turn_nonce=the fresh nonce, source=.text, provider="mock", model_id=model.rawValue. Verified by inspecting the mock ReplayLog's recorded calls.
    - Test OS6 (OrchestratorSubmitTests): ReplayLog.record is called for every .textDelta with a ReplayEvent.textDelta; for the tool_use with ReplayEvent.toolCallRequested; for the tool_result with ReplayEvent.toolResultFull (**using the FULL blob, not the 8KB-capped model-facing string** — AGENT-08 replay invariant). Verified via mock inspection.
    - Test OS7 (OrchestratorSubmitTests): ReplayLog.endTurn is called exactly once per turn with the final stop_reason string.
    - Test OC1 (OrchestratorCancelTests): Turn in flight (MockLLMProvider holds on throttle), call `cancelAndSubmit(new input)` → returns `.superseded(priorId: originalId, reason: .bargedIn)`. Prior turn's event stream shows `.stateChange(.reconfiguring)` briefly then a turnEnd event with stopReason "cancelled". New turn proceeds normally.
    - Test OC2 (OrchestratorCancelTests): cancelAndSubmit on a fresh orchestrator (no turn in flight) → returns `.ran(turnId:)` normally (no supersession because there was nothing to supersede).
    - Test OC3 (OrchestratorCancelTests, **critical actor-reentrancy guard**): `cancelAndSubmit` must await the cancelled Task's completion BEFORE starting the new turn — test interleaves events using a controllable MockLLMProvider that emits a delayed `.messageStop` AFTER cancellation; assert the orchestrator does NOT overwrite currentTurn with the new turn until the late `.messageStop` is discarded (or: assert that currentTurn field, observed via a test hook, never holds BOTH a cancelled-but-not-drained task AND the new task simultaneously).
    - Test OC4 (OrchestratorCancelTests): ReplayLog.endTurn is called for the cancelled turn with stopReason "cancelled" (via either .stopReason(.streamTruncated) from the cancelled provider OR a synthetic "cancelled" stop_reason). Either behavior is acceptable — document which.
  </behavior>
  <action>
**Update `packages/AgentCore/Package.swift`** — add `../Replay` as a package dependency (path: `../Replay`) and add `.product(name: "Replay", package: "Replay")` to the AgentCore target dependencies. The orchestrator imports `Replay` for `ReplayLog`, `ReplayEvent`, `SessionID`, `TurnSource`, `OrphanDetector`, `TokenDeltaDropOldestChannel`.

Also: move `Base64URL.swift` from `Sources/AnthropicProvider/` to `Sources/AgentCore/` (per Task 1 note) so TurnNonce can use it without cross-target visibility gymnastics. Plan 04-01 placed it in AnthropicProvider; relocate in this plan since it's now shared. Update any imports in AnthropicProvider that previously accessed it.

**`TurnInput.swift`**:

```swift
import Foundation
import Replay   // TurnSource

public struct TurnInput: Sendable {
    public let source: TurnSource
    public let userText: String
    public let submittedAt: Date
    public init(source: TurnSource, userText: String, submittedAt: Date = Date())
}

public extension TurnInput {
    static func text(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .text, userText: s, submittedAt: date)
    }
    static func voice(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .voice, userText: s, submittedAt: date)
    }
}
```

**`SubmitOutcome.swift`**:

```swift
public enum SubmitOutcome: Sendable, Equatable {
    case ran(turnId: TurnID)
    case superseded(priorId: TurnID, reason: SupersedeReason)
    case rejected(reason: RejectReason)
}

public enum SupersedeReason: Sendable, Equatable {
    case bargedIn
    case userCancelled
}

public enum RejectReason: Sendable, Equatable {
    case turnInFlight
    case providerUnavailable
    case configError
}
```

**`TurnState.swift`** — internal state machine states surfaced in DevOverlay (Plan 04-05):

```swift
public enum TurnState: Sendable, Equatable {
    case idle
    case booting
    case thinking
    case speaking            // reserved for P6; never emitted in P4
    case listening           // reserved for P6
    case awaitingConfirmation(ConfirmationID)   // P5 will wire the ID shape; P4 stubs it
    case reconfiguring
}

public struct ConfirmationID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
```

**`OrchestratorEvent.swift`** — what the orchestrator emits to Plan 04-05's DevOverlay / bus:

```swift
public enum OrchestratorEvent: Sendable {
    case stateChange(TurnState)
    case tokenDelta(turnId: TurnID, text: String)
    case thinkingDelta(turnId: TurnID, text: String)
    case toolCardUpdate(ToolCardUpdate)
    case turnEnd(turnId: TurnID, stopReason: StopReason)
    case error(turnId: TurnID, error: LLMProviderError)
    // NB: NO field named turnNonce anywhere. SEC-06 requires the nonce never
    //     appears in any event that can cross to the webview via the bus.
}

public struct ToolCardUpdate: Sendable {
    public enum Phase: Sendable { case pending, running, awaitingApproval, completed, failed }
    public let turnId: TurnID
    public let toolUseId: String
    public let toolName: String
    public let phase: Phase
    public let resultPreview: String?     // capped to ~200 chars for HUD display
    public let error: String?
}
```

**`PerTurnSnapshot+Agent.swift`** — extension adding agent-specific read helpers:

```swift
import Config

public extension PerTurnSnapshot {
    /// Tool-call budget per turn (cap-recovery triggers when exceeded).
    func maxToolCallsPerTurn() -> Int { 10 }   // conservative default; could be made configurable in P5+

    /// Max output tokens per turn.
    func maxOutputTokens() -> Int { 8192 }     // AGENT-08 rationale

    /// The resolved provider.
    var resolvedProvider: ProviderSelection { provider }
}
```

**`ToolDispatcher.swift`** — the protocol consumed by the orchestrator; implemented by a mock in tests and by the MCP client in Plan 05:

```swift
public protocol ToolDispatcher: Sendable {
    /// Invoke the tool; return the raw result bytes.
    /// Throwing maps to OrchestratorEvent.toolCardUpdate(phase: .failed).
    func dispatch(toolUse: ToolUseRequest) async throws -> Data

    /// Return true if this tool requires human confirmation before dispatch.
    /// In P4 this always returns false (no real tools wired yet).
    func requiresConfirmation(toolName: String) -> Bool
}
```

**`AgentOrchestrator.swift`** — the core actor:

```swift
import Foundation
import Config
import Replay
import JarvisLogging
import Logging

public actor AgentOrchestrator {
    // Injected dependencies
    private let configStore: ConfigStore
    private let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider
    private let toolDispatcher: any ToolDispatcher
    private let replayLog: ReplayLog
    private let sessionId: SessionID
    private let systemPrompt: String
    private let logger: Logger

    // Outbound event channel for Plan 04-05 consumption
    public let events: BoundedAsyncChannel<OrchestratorEvent>    // capacity 256, .suspend

    // Replay channel: per-element drop (tokenDelta only)
    private let replayChannel: TokenDeltaDropOldestChannel<ReplayEventTag>

    // Turn state (actor-protected)
    private var currentTurn: TurnExecution?

    public init(
        configStore: ConfigStore,
        providerFactory: @escaping @Sendable (ProviderSelection) async throws -> any LLMProvider,
        toolDispatcher: any ToolDispatcher,
        replayLog: ReplayLog,
        sessionId: SessionID,
        systemPrompt: String
    ) {
        self.configStore = configStore
        self.providerFactory = providerFactory
        self.toolDispatcher = toolDispatcher
        self.replayLog = replayLog
        self.sessionId = sessionId
        self.systemPrompt = systemPrompt
        self.logger = Logger(label: JarvisLogChannel.agent.rawValue)
        self.events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)
        self.replayChannel = TokenDeltaDropOldestChannel<ReplayEventTag>(capacity: 2048, dropTag: .tokenDelta)

        // Spawn a replay-drain task that forwards TokenDeltaDropOldestChannel elements
        // into ReplayLog.record. This task runs for the orchestrator's lifetime.
        Task.detached { [replayChannel, replayLog] in
            for await tagged in replayChannel {
                guard let payload = ReplayChannelPayload(data: tagged.payload) else { continue }
                await replayLog.record(payload.event, for: payload.turnId)
            }
        }
    }

    public func submit(_ input: TurnInput) async -> SubmitOutcome {
        if currentTurn != nil { return .rejected(reason: .turnInFlight) }
        return await runTurn(input: input, retryOf: nil, supersededPrior: nil)
    }

    public func cancelAndSubmit(_ input: TurnInput) async -> SubmitOutcome {
        let priorId = currentTurn?.id
        if let priorTask = currentTurn?.task {
            priorTask.cancel()
            _ = await priorTask.value   // Wait for clean shutdown — AGENT-06 actor-reentrancy guard
        }
        await replayLog.endTurn(priorId ?? TurnID.fresh(), stopReason: "cancelled")   // if prior exists
        currentTurn = nil
        let outcome = await runTurn(input: input, retryOf: nil, supersededPrior: priorId)
        return outcome
    }

    private func runTurn(
        input: TurnInput,
        retryOf: TurnID?,
        supersededPrior: TurnID?
    ) async -> SubmitOutcome {
        // 1. Allocate IDs and nonce.
        let turnId = TurnID.fresh()
        let nonce = TurnNonce.fresh()
        let perTurn = await configStore.perTurn()
        let provider: any LLMProvider
        do {
            provider = try await providerFactory(perTurn.resolvedProvider)
        } catch {
            return .rejected(reason: .providerUnavailable)
        }

        // 2. Start replay turn row.
        do {
            try await replayLog.startTurn(
                turnId: turnId,
                sessionId: sessionId,
                retryOf: retryOf,
                turnNonce: nonce.rawValue,
                source: input.source,
                provider: String(describing: perTurn.resolvedProvider),
                modelId: modelIDFor(perTurn.resolvedProvider).rawValue
            )
        } catch {
            logger.error("replayLog.startTurn failed: \(error)")
            return .rejected(reason: .configError)
        }

        // 3. Build the initial messages with the untrusted wrapper pattern
        //    (system prompt explaining the nonce + user message).
        let wrapper = UntrustedWrapper(nonce: nonce)
        var messages = buildInitialMessages(systemPrompt: systemPrompt, input: input, wrapper: wrapper)

        // 4. Emit state change: .thinking.
        await events.send(.stateChange(.thinking))

        // 5. Spawn the turn task.
        let task = Task { [provider, perTurn] in
            await runTurnLoop(
                turnId: turnId,
                provider: provider,
                messages: messages,
                perTurn: perTurn,
                wrapper: wrapper
            )
        }
        currentTurn = TurnExecution(id: turnId, task: task, startedAt: Date(), retryOf: retryOf)

        // 6. Return outcome immediately (the task runs in the background).
        //    Event channel consumers see the streaming events arrive asynchronously.
        if let supersededPrior = supersededPrior {
            return .superseded(priorId: supersededPrior, reason: .bargedIn)
        }
        return .ran(turnId: turnId)
    }

    private func runTurnLoop(
        turnId: TurnID,
        provider: any LLMProvider,
        messages: [LLMMessage],
        perTurn: PerTurnSnapshot,
        wrapper: UntrustedWrapper
    ) async {
        // Turn loop is implemented in Task 3 (stream_truncated retry + cap-recovery live there).
        // For Task 2, a simplified version: run one provider call, handle tool_uses via ToolDispatcher,
        // record to replay, emit events, endTurn.
        //
        // Details in Task 3 action block.
    }

    // Helpers...
    private struct TurnExecution: Sendable {
        let id: TurnID
        let task: Task<Void, Never>
        let startedAt: Date
        let retryOf: TurnID?
    }
}

enum ReplayEventTag: Sendable, Equatable, Hashable {
    case tokenDelta, other
}

struct ReplayChannelPayload: Sendable {
    let turnId: TurnID
    let event: ReplayEvent
    init?(data: Data) { /* decode */ }
    func encoded() -> Data { /* encode */ }
}
```

Task 2 scope: land the **skeleton** of `runTurnLoop` that covers:
- Non-retry happy path (no cap recovery, no stream truncation).
- Tool-use dispatch via ToolDispatcher.
- Replay writes for every LLMEvent.
- Event emission for stateChange / tokenDelta / toolCardUpdate / turnEnd.
- Correct endTurn on normal completion AND on cancellation.

Task 3 adds the retry + cap-recovery branches on top.

**`MockLLMProvider.swift`** (under `Tests/AgentCoreTests/`):

```swift
@testable import AgentCore

public actor MockLLMProvider: LLMProvider {
    public struct Script: Sendable {
        public var events: [LLMEvent]
        public var throttleBetweenEventsNs: UInt64
        public var recordRequests: Bool
        public init(events: [LLMEvent], throttleBetweenEventsNs: UInt64 = 0, recordRequests: Bool = true)
    }
    private var script: Script
    public private(set) var recordedCalls: [(messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice, model: ModelID)] = []
    public init(script: Script)
    public nonisolated func stream(...) -> AsyncThrowingStream<LLMEvent, Error>
    public func setScript(_ s: Script)
    public func getRecordedCalls() -> [(messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice, model: ModelID)]
}
```

The `stream(...)` implementation yields the scripted events with the throttle between each. It records the incoming call args (messages, tools, toolChoice) for later inspection by tests.

Write `OrchestratorSubmitTests.swift` and `OrchestratorCancelTests.swift` per `<behavior>` OS1-OS7 + OC1-OC4.

Commit: `feat(04-04): AgentOrchestrator actor skeleton + MockLLMProvider + submit/cancelAndSubmit happy path (AGENT-06)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-04-t2.log && swift test --filter OrchestratorSubmitTests --filter OrchestratorCancelTests 2>&1 | tee /tmp/test-04-04-t2.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-04-t2.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter OrchestratorSubmitTests --filter OrchestratorCancelTests` exits 0 with 11 tests passing.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'cancelAndSubmit'` at least 1.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift | grep -c 'turnNonce'` equals 0 (SEC-06 — nonce never leaks into bus-bound events).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'turnNonce\\|nonce.rawValue'` at least 1 (nonce IS passed to ReplayLog.startTurn).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'await priorTask.value'` at least 1 (AGENT-06 actor-reentrancy guard).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/SubmitOutcome.swift | grep -c 'case '` equals 3 (exactly three cases in SubmitOutcome).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Stream_truncated retry (AGENT-09) + cap-recovery with tool_choice .none (AGENT-07)</name>
  <files>
    packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift,
    packages/AgentCore/Sources/AgentCore/RetryState.swift,
    packages/AgentCore/Sources/AgentCore/TurnState.swift,
    packages/AgentCore/Tests/AgentCoreTests/OrchestratorRetryTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/OrchestratorCapRecoveryTests.swift
  </files>
  <behavior>
    - Test OR1 (OrchestratorRetryTests): Provider script — emits .messageStart, 2 textDeltas, .stopReason(.streamTruncated), .messageStop. Orchestrator: on first attempt gets stream_truncated; starts a retry turn with fresh turnId; ReplayLog.startTurn is called a SECOND time with retryOf = originalTurnId; second attempt proceeds normally to end_turn.
    - Test OR2 (OrchestratorRetryTests): Provider script — emits stream_truncated on BOTH first and second attempts. Orchestrator: emits `.error(turnId:, .streamTruncatedFinal)` after the second truncation and does NOT start a third attempt.
    - Test OR3 (OrchestratorRetryTests): Retry turn's tool-call budget is RESET — if first attempt consumed 8 of 10 tool calls before stream_truncated, the retry starts with 10 available.
    - Test OR4 (OrchestratorRetryTests): Retry re-reads PerTurnSnapshot — if configStore.updatePerTurn() is called between first attempt and retry (e.g., provider changes from anthropic to ollama), the retry uses the NEW provider.
    - Test OR5 (OrchestratorRetryTests): stream_truncated does NOT retry on stop_reason .refusal, .maxTokens, or transport 4xx errors. Only .streamTruncated triggers retry.
    - Test OC1 (OrchestratorCapRecoveryTests): MockLLMProvider script — yields 10 tool_use requests in a row (each tool_call returns quickly via mock dispatcher). Orchestrator hits tool-call budget (maxToolCallsPerTurn = 10). Cap-recovery triggers: orchestrator re-invokes provider.stream with toolChoice: .none; provider records the received toolChoice.
    - Test OC2 (OrchestratorCapRecoveryTests): On cap-recovery invocation, MockLLMProvider.recordedCalls[11].toolChoice equals ToolChoice.none — AGENT-07 critical assertion.
    - Test OC3 (OrchestratorCapRecoveryTests): Cap-recovery yields zero .toolUseRequested events on the recovery turn (because toolChoice is .none) — this is the R4-L1 regression guard.
    - Test OC4 (OrchestratorCapRecoveryTests): After cap-recovery completes, orchestrator emits .turnEnd normally with the recovery turn's stop_reason.
  </behavior>
  <action>
**`RetryState.swift`**:

```swift
struct RetryState: Sendable {
    var budget: Int = 1
    var originalTurnId: TurnID
    init(originalTurnId: TurnID, budget: Int = 1) {
        self.originalTurnId = originalTurnId
        self.budget = budget
    }
}
```

**Update `TurnState.swift`** — if not already present, add any additional internal states needed for the retry UX (e.g., `.reconfiguring` already exists; no new states needed for AGENT-09).

**Update `AgentOrchestrator.swift`** — flesh out `runTurnLoop` with the full retry + cap-recovery state machine:

```swift
private func runTurnLoop(
    turnId: TurnID,
    provider: any LLMProvider,
    initialMessages: [LLMMessage],
    perTurn: PerTurnSnapshot,
    wrapper: UntrustedWrapper
) async {
    var messages = initialMessages
    var toolCallBudget = perTurn.maxToolCallsPerTurn()
    var retry = RetryState(originalTurnId: turnId)
    var currentTurnId = turnId
    var currentProvider = provider

    outer: while true {
        // Compute tool_choice based on budget.
        let toolChoice: ToolChoice = toolCallBudget > 0 ? .auto : .none
        let tools = toolCallBudget > 0 ? availableTools() : []

        let stream = currentProvider.stream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            model: modelIDFor(perTurn.resolvedProvider),
            maxOutputTokens: perTurn.maxOutputTokens(),
            cacheHints: CacheHints(systemPromptTTL: .extended1h)
        )

        var seenToolUseThisIteration = false

        do {
            for try await event in stream {
                if Task.isCancelled {
                    return   // cancelAndSubmit path — caller handles replay close
                }
                await recordAndEmit(event: event, turnId: currentTurnId)

                switch event {
                case .textDelta(let s):
                    await events.send(.tokenDelta(turnId: currentTurnId, text: s))
                case .thinkingDelta(let s):
                    await events.send(.thinkingDelta(turnId: currentTurnId, text: s))
                case .toolUseRequested(let req):
                    seenToolUseThisIteration = true
                    toolCallBudget -= 1
                    await events.send(.toolCardUpdate(.init(
                        turnId: currentTurnId, toolUseId: req.id,
                        toolName: req.name, phase: .running,
                        resultPreview: nil, error: nil)))

                    // Dispatch.
                    let resultData: Data
                    do {
                        resultData = try await toolDispatcher.dispatch(toolUse: req)
                    } catch {
                        // Tool failure — record as toolCardUpdate(.failed) and append error to messages.
                        await events.send(.toolCardUpdate(.init(
                            turnId: currentTurnId, toolUseId: req.id, toolName: req.name,
                            phase: .failed, resultPreview: nil, error: String(describing: error))))
                        let errMsg = LLMMessage(
                            role: .tool,
                            content: [.toolResult(toolUseId: req.id, content: "ERROR: \(error)")],
                            untrusted: true
                        )
                        messages.append(errMsg)
                        continue
                    }

                    // Pack + wrap + log.
                    let packed = ToolResultPacker.pack(resultData)
                    // Replay gets the FULL blob via .toolResultFull.
                    await replayLog.record(
                        .toolResultFull(toolUseId: req.id, bytes: packed.fullBytes),
                        for: currentTurnId
                    )
                    // Model-facing message uses the capped string + wrapped with turnNonce.
                    let wrapped = wrapper.wrap(packed.modelFacing)
                    let toolResultMsg = LLMMessage(
                        role: .tool,
                        content: [.toolResult(toolUseId: req.id, content: wrapped)],
                        untrusted: true
                    )
                    messages.append(toolResultMsg)

                    await events.send(.toolCardUpdate(.init(
                        turnId: currentTurnId, toolUseId: req.id, toolName: req.name,
                        phase: .completed,
                        resultPreview: String(packed.modelFacing.prefix(200)),
                        error: nil)))

                case .stopReason(let reason):
                    switch reason {
                    case .endTurn:
                        await events.send(.turnEnd(turnId: currentTurnId, stopReason: .endTurn))
                        try? await replayLog.endTurn(currentTurnId, stopReason: "end_turn")
                        await events.send(.stateChange(.idle))
                        currentTurn = nil
                        return

                    case .toolUse:
                        // Continue the loop — provider said stop, but a tool use is in flight.
                        // The next iteration will re-invoke stream with the updated messages.
                        continue outer

                    case .maxTokens:
                        await events.send(.turnEnd(turnId: currentTurnId, stopReason: .maxTokens))
                        try? await replayLog.endTurn(currentTurnId, stopReason: "max_tokens")
                        await events.send(.stateChange(.idle))
                        currentTurn = nil
                        return

                    case .refusal:
                        await events.send(.turnEnd(turnId: currentTurnId, stopReason: .refusal))
                        try? await replayLog.endTurn(currentTurnId, stopReason: "refusal")
                        await events.send(.stateChange(.idle))
                        currentTurn = nil
                        return

                    case .streamTruncated:
                        // AGENT-09 retry path.
                        if retry.budget > 0 {
                            retry.budget -= 1
                            let newTurnId = TurnID.fresh()
                            // Re-read PerTurnSnapshot (AGENT-09 requirement — config change mid-retry).
                            let updated = await configStore.perTurn()
                            do {
                                currentProvider = try await providerFactory(updated.resolvedProvider)
                            } catch {
                                await events.send(.error(turnId: currentTurnId, error: .streamTruncatedFinal))
                                try? await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_final")
                                currentTurn = nil
                                return
                            }
                            try? await replayLog.startTurn(
                                turnId: newTurnId, sessionId: sessionId, retryOf: retry.originalTurnId,
                                turnNonce: wrapper.nonce.rawValue, source: .text,     // TODO: carry real source
                                provider: String(describing: updated.resolvedProvider),
                                modelId: modelIDFor(updated.resolvedProvider).rawValue
                            )
                            try? await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_retry")
                            currentTurnId = newTurnId
                            toolCallBudget = updated.maxToolCallsPerTurn()   // AGENT-09 reset budget
                            await events.send(.stateChange(.reconfiguring))
                            continue outer   // Re-invoke provider.stream with current messages
                        } else {
                            await events.send(.error(turnId: currentTurnId, error: .streamTruncatedFinal))
                            try? await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_final")
                            await events.send(.stateChange(.idle))
                            currentTurn = nil
                            return
                        }
                    }

                default:
                    break   // .messageStart / .usage / .messageStop / .toolUseBuffering / .partialToolUseAtDisconnect don't terminate the loop
                }
            }

            // Stream ended without a .stopReason — treat as streamTruncated (safety net).
            // This should be rare since SSEDecoder / NDJSONDecoder emit it explicitly.

        } catch {
            await events.send(.error(turnId: currentTurnId, error: (error as? LLMProviderError) ?? .transport(description: String(describing: error))))
            try? await replayLog.endTurn(currentTurnId, stopReason: "error")
            currentTurn = nil
            return
        }
    }
}
```

**Cap-recovery (AGENT-07) — already embedded above**: when `toolCallBudget == 0`, `toolChoice: .none` is passed AND `tools` is passed as an empty array. The provider's RequestBody encoder honors `.none` per Plan 04-01 (Anthropic: `{"type":"none"}`) and Plan 04-02 (Ollama: drops tools array entirely). The orchestrator doesn't need to know the per-provider serialization — that's the protocol abstraction working as designed.

Write `OrchestratorRetryTests.swift` and `OrchestratorCapRecoveryTests.swift` per `<behavior>`.

Commit: `feat(04-04): stream_truncated retry (AGENT-09) + cap-recovery with tool_choice .none (AGENT-07)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift test --filter OrchestratorRetryTests --filter OrchestratorCapRecoveryTests 2>&1 | tee /tmp/test-04-04-t3.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-04-t3.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter OrchestratorRetryTests --filter OrchestratorCapRecoveryTests` exits 0 with 9 tests passing.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'streamTruncated'` at least 2 (case-match + retry path).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'retry.budget'` at least 2 (decrement + guard).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'retryOf:'` at least 1 (passed to ReplayLog.startTurn on retry).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift | grep -c 'ToolChoice.none\\|toolChoice: .none'` at least 1 (cap-recovery wiring).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Tool result → model prompt | Tool results are attacker-controllable (clipboard, AppleScript output, web fetches in future tools). turnNonce wrapping is the structural defence. |
| OrchestratorEvent → bus → webview | Any field on OrchestratorEvent eventually crosses to the webview via Plan 02's bus. The nonce MUST NOT appear in any OrchestratorEvent case. |
| ToolDispatcher → external processes | In P4, dispatcher is mocked; in P5, it spawns MCP helpers. This plan's threat model stops at the protocol. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-04-01 | Information Disclosure | turnNonce leaks via OrchestratorEvent to webview | mitigate | OrchestratorEvent enum has no `turnNonce` field anywhere. Grep gate: `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift \| grep -c 'nonce'` equals 0. Structural + enforced-by-test. |
| T-04-04-02 | Tampering | Injected closing tag in tool result escapes UntrustedWrapper | mitigate | Tag-strip regex runs BEFORE wrapping (UntrustedWrapper.wrap). Tests UW2-UW5 verify strip correctness. Remaining attack: base64-encoded or Unicode-tricked variants of the tag — ASVS L1 out-of-scope, covered in P8 corpus. |
| T-04-04-03 | Elevation of Privilege | Cap-recovery turn still emits tool_use (regression) | mitigate | AGENT-07 test OC3 asserts zero `.toolUseRequested` on the recovery turn. Cap-recovery sends toolChoice: .none which providers serialize correctly (Plan 04-01 test R3 for Anthropic; Plan 04-02 test R1 for Ollama). Defence-in-depth via three test layers. |
| T-04-04-04 | Denial of Service | Infinite retry loop on persistent stream_truncated | mitigate | AGENT-09 retry budget is 1. Test OR2 verifies a second back-to-back truncation is terminal. No unbounded retry. |
| T-04-04-05 | Repudiation | Replay log misses a turn (crash between startTurn and endTurn) | mitigate | OBS-07 OrphanDetector (Plan 04-03) handles this at launch. This plan's runTurnLoop calls `endTurn` on every return path (happy, retry-exhausted, error, cancellation). Cancellation path: `cancelAndSubmit` explicitly calls endTurn with stopReason="cancelled" before awaiting task. |
| T-04-04-06 | Tampering | Actor reentrancy during cancelAndSubmit overwrites currentTurn | mitigate | AGENT-06 invariant. `await priorTask.value` blocks until the cancelled task drains before `currentTurn = nil` and new turn starts. Test OC3 is a regression guard with a controllable MockLLMProvider. |
| T-04-04-07 | Information Disclosure | Full tool result bytes leaked to webview via OrchestratorEvent | mitigate | `ToolCardUpdate.resultPreview` is capped at 200 chars (String(prefix(200))). Full bytes go to ReplayLog only. Grep gate confirms ToolCardUpdate has no full-data field. |
</threat_model>

<verification>
- `cd packages/AgentCore && swift build` — clean.
- `cd packages/AgentCore && swift test` — all tests pass (ALL four orchestrator test files + Task 1's three test files + existing AgentCoreTests + AnthropicProviderTests + OllamaProviderTests).
- `gsd-sdk query frontmatter.validate .planning/phases/04-agent-core/04-04-orchestrator-PLAN.md --schema plan` returns valid.
- SEC-06 nonce-never-in-events grep gate passes.
</verification>

<success_criteria>
- `AgentOrchestrator.submit(_:)` and `cancelAndSubmit(_:)` correctly emit SubmitOutcome across race conditions (AGENT-06).
- Tool results cap at 8 KB in model-facing history; full blob in replay (AGENT-08).
- Stream_truncated retry is bounded at exactly 1; second truncation is terminal (AGENT-09).
- Tool-call budget exhaustion triggers cap-recovery with toolChoice: .none (AGENT-07 critical).
- turnNonce is base64url 16-random-bytes; never appears in any OrchestratorEvent (SEC-06).
- UntrustedWrapper strips tag-like substrings before wrapping (SEC-06).
- `MockLLMProvider` test double supports the full test matrix without requiring a live API.
- All tests across `packages/AgentCore` (AgentCoreTests + AnthropicProviderTests + OllamaProviderTests) pass together.
</success_criteria>

<output>
After completion, create `.planning/phases/04-agent-core/04-04-SUMMARY.md` per the GSD summary template.
</output>
