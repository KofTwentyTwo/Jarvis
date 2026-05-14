# Local-first LLM Routing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the default chat-turn provider from Anthropic to local Ollama, with one-shot reactive escalation to Claude Opus 4.7 on detectable Ollama failure modes. Surface escalation to the HUD via a new bus event.

**Architecture:** Extend the existing per-turn retry hook in `AgentOrchestrator` (lines 780–819) so its trigger broadens from `{streamTruncated}` to the full `OllamaFailureKind` enum. Carry the per-turn escalation budget on the orchestrator's existing retry-counter. Add `escalationEnabled: Bool` to `PerTurnSnapshot` so the user can opt out of escalation. Emit a single `BusOutbound.escalated(...)` event per turn for the HUD badge.

**Tech Stack:** Swift 6 + SPM; SwiftUI Settings; WKWebView bus over typed JSON; ConfigStore actor for hot-reload; Harness package `MockLLMProvider` for fixture-driven eval.

**Spec:** `docs/superpowers/specs/2026-05-14-local-first-llm-routing-design.md` (commit `3612c5d`, PR #197).

---

## File map

**New files:**

- `packages/AgentCore/Sources/AgentCore/OllamaFailureKind.swift` — closed enum + `EscalationDecision` struct.
- `packages/AgentCore/Tests/AgentCoreTests/OllamaFailureKindTests.swift` — pure-type tests.
- `packages/Harness/Tests/HarnessTests/EscalationHarnessTests.swift` — three eval lanes from spec §7.
- `webview/packages/hud/src/components/EscalationBadge.tsx` — small inline badge component.
- `webview/packages/hud/src/components/EscalationBadge.test.tsx` — Vitest snapshot + render test.

**Modified files:**

- `packages/Config/Sources/Config/ProviderSelection.swift` — no change in shape; documentation comment update only (clarify `.ollama` is now the default).
- `packages/Config/Sources/Config/PerTurnSnapshot.swift` — add `escalationEnabled: Bool` field.
- `packages/Config/Sources/Config/Resources/default-config.json` — flip `"provider"` to `"ollama"`, add `"escalationEnabled": true`.
- `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift` — assert default decoding now sets `provider == .ollama` and `escalationEnabled == true`.
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` — extend lines 780–819 to handle `OllamaFailureKind` (not just `streamTruncated`); enforce escalation budget; emit `BusOutbound.escalated`.
- `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` (or the parser file) — detect `malformedToolCall` (tool_calls JSON decode failure), `unknownTool` (tool name not in registry — wait, registry is orchestrator-side; this trigger fires in orchestrator), `emptyResponse` (zero textDelta + zero toolUseRequested at messageStop). `connectionFailure` already surfaces as a thrown URLSession error.
- `packages/Bus/Sources/Bus/BusOutbound.swift` — add `.escalated(EscalationDecision)` case + bump `Kind` enum + protocol version.
- `packages/Bus/Sources/Bus/Codec/BusOutboundCodec.swift` (or wherever the JSON shape lives) — encode/decode the new case.
- `webview/packages/bus/src/bridge.ts` — add inbound `escalated` event type.
- `webview/packages/hud/src/MessageList.tsx` (or whichever component renders chat messages) — wire `EscalationBadge` to render when message has an `escalation` field.
- `scripts/check-bus-harness-parity.sh` — accommodate new event.
- `App/Settings/SettingsView.swift` (or current Settings UI file) — add 3-mode picker.

**File-touched counts:** ~12 modified + 5 new = 17 files. Single PR.

---

## Task 1: Branch off latest develop

**Files:** none (git only)

- [ ] **Step 1: Verify clean working tree on develop**

Run:
```bash
cd /Users/james.maes/Git.Local/Kof22/Jarvis
git status
git branch --show-current
```
Expected: branch `develop`, working tree clean (untracked `.claude/scheduled_tasks.lock` is OK).

- [ ] **Step 2: Sync develop with origin**

Run:
```bash
git pull --ff-only
```
Expected: "Already up to date" OR fast-forward of N commits with no merge conflict.

- [ ] **Step 3: Create feature branch**

Run:
```bash
git checkout -b feat/local-first-llm-routing
```
Expected: switched to new branch `feat/local-first-llm-routing`.

- [ ] **Step 4: Commit checkpoint**

No commit yet — branch is empty relative to develop. Move to Task 2.

---

## Task 2: Add `OllamaFailureKind` enum + `EscalationDecision` struct

**Files:**
- Create: `packages/AgentCore/Sources/AgentCore/OllamaFailureKind.swift`
- Create: `packages/AgentCore/Tests/AgentCoreTests/OllamaFailureKindTests.swift`

- [ ] **Step 1: Write the failing test**

Create `packages/AgentCore/Tests/AgentCoreTests/OllamaFailureKindTests.swift`:

```swift
import XCTest
@testable import AgentCore

final class OllamaFailureKindTests: XCTestCase {
    func test_failure_kind_round_trips_codable() throws {
        let kinds: [OllamaFailureKind] = [
            .streamTruncated, .malformedToolCall, .unknownTool,
            .refusal, .connectionFailure, .emptyResponse
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(OllamaFailureKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_escalation_decision_is_sendable_codable() throws {
        let decision = EscalationDecision(
            from: .ollama,
            to: .anthropic,
            reason: .malformedToolCall,
            firedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(EscalationDecision.self, from: data)
        XCTAssertEqual(decoded.from, .ollama)
        XCTAssertEqual(decoded.to, .anthropic)
        XCTAssertEqual(decoded.reason, .malformedToolCall)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run:
```bash
swift test --package-path packages/AgentCore --filter OllamaFailureKindTests
```
Expected: FAIL — "cannot find 'OllamaFailureKind' in scope".

- [ ] **Step 3: Implement the enum + struct**

Create `packages/AgentCore/Sources/AgentCore/OllamaFailureKind.swift`:

```swift
import Foundation
import Config

/// Closed enumeration of detectable failure modes for the local Ollama provider
/// that trigger one-shot escalation to Anthropic Claude Opus 4.7.
///
/// See `docs/superpowers/specs/2026-05-14-local-first-llm-routing-design.md` §2.
///
/// Adding a new case is a breaking change: orchestrator + tests + HUD badge
/// reason mapping all need to be updated together.
public enum OllamaFailureKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Mid-stream EOF before `messageStop`. Already wired pre-spec.
    case streamTruncated
    /// `tool_calls` payload failed to decode against `ToolUseRequest`.
    case malformedToolCall
    /// Model invoked a tool name not in the registry.
    case unknownTool
    /// `stopReason: .refusal` event observed.
    case refusal
    /// URLSession error before any tokens received.
    case connectionFailure
    /// `messageStop` with zero `textDelta` and zero `toolUseRequested`.
    case emptyResponse
}

/// Recorded once when reactive escalation fires. Emitted to the HUD via
/// `BusOutbound.escalated(...)`.
public struct EscalationDecision: Sendable, Codable, Equatable {
    public let from: ProviderSelection
    public let to: ProviderSelection
    public let reason: OllamaFailureKind
    public let firedAt: Date

    public init(from: ProviderSelection, to: ProviderSelection, reason: OllamaFailureKind, firedAt: Date) {
        self.from = from
        self.to = to
        self.reason = reason
        self.firedAt = firedAt
    }
}
```

- [ ] **Step 4: Run test, verify it passes**

Run:
```bash
swift test --package-path packages/AgentCore --filter OllamaFailureKindTests
```
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

Run:
```bash
git add packages/AgentCore/Sources/AgentCore/OllamaFailureKind.swift \
        packages/AgentCore/Tests/AgentCoreTests/OllamaFailureKindTests.swift
git commit -m "$(cat <<'EOF'
feat(agent-core): add OllamaFailureKind enum + EscalationDecision struct

Closed enum of six detectable Ollama failure modes that trigger reactive
escalation to Anthropic per the local-first routing spec. EscalationDecision
is the record emitted once per escalated turn.

Refs design spec §2-§3.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `escalationEnabled` field to `PerTurnSnapshot`

**Files:**
- Modify: `packages/Config/Sources/Config/PerTurnSnapshot.swift`
- Modify: `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift` (create if absent)

- [ ] **Step 1: Inspect the test file (or create stub if missing)**

Run:
```bash
ls packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift 2>&1 || echo "missing"
```
If missing, the engineer creates the file with the test below; otherwise edits the existing one to add the test.

- [ ] **Step 2: Add failing test**

Add to `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`:

```swift
import XCTest
@testable import Config

final class PerTurnSnapshotEscalationTests: XCTestCase {
    func test_escalation_enabled_round_trips() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "ollama",
          "escalationEnabled": true,
          "tts": { "tier": "tier1" },
          "stt": { "whisperKitFallback": false },
          "featureFlags": { "orpheusTTSEnabled": false, "whisperKitSTTEnabled": false }
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
        XCTAssertEqual(snapshot.provider, .ollama)
        XCTAssertTrue(snapshot.escalationEnabled)
    }

    func test_escalation_enabled_defaults_to_true_when_absent() throws {
        // Older configs without the field should default to `true` to opt
        // existing users into the new local-first behavior on upgrade.
        let json = """
        {
          "schemaVersion": 1,
          "provider": "ollama",
          "tts": { "tier": "tier1" },
          "stt": { "whisperKitFallback": false },
          "featureFlags": { "orpheusTTSEnabled": false, "whisperKitSTTEnabled": false }
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
        XCTAssertTrue(snapshot.escalationEnabled)
    }
}
```

- [ ] **Step 3: Run test, verify it fails**

Run:
```bash
swift test --package-path packages/Config --filter PerTurnSnapshotEscalationTests
```
Expected: FAIL — "value of type 'PerTurnSnapshot' has no member 'escalationEnabled'".

- [ ] **Step 4: Add the field with a custom decoder**

Edit `packages/Config/Sources/Config/PerTurnSnapshot.swift` to:

```swift
import Foundation

public struct PerTurnSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let provider: ProviderSelection
    public let escalationEnabled: Bool
    public let tts: TTSConfig
    public let stt: STTConfig
    public let featureFlags: FeatureFlags
    // DO NOT add: ollama host, applescript policy, toolBlocklist, confirmationPolicy (all Launch-pinned per SEC-05).

    public init(
        schemaVersion: Int,
        provider: ProviderSelection,
        escalationEnabled: Bool = true,
        tts: TTSConfig,
        stt: STTConfig,
        featureFlags: FeatureFlags
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.escalationEnabled = escalationEnabled
        self.tts = tts
        self.stt = stt
        self.featureFlags = featureFlags
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, escalationEnabled, tts, stt, featureFlags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.provider = try c.decode(ProviderSelection.self, forKey: .provider)
        self.escalationEnabled = try c.decodeIfPresent(Bool.self, forKey: .escalationEnabled) ?? true
        self.tts = try c.decode(TTSConfig.self, forKey: .tts)
        self.stt = try c.decode(STTConfig.self, forKey: .stt)
        self.featureFlags = try c.decode(FeatureFlags.self, forKey: .featureFlags)
    }
}
```

- [ ] **Step 5: Run test, verify it passes**

Run:
```bash
swift test --package-path packages/Config --filter PerTurnSnapshotEscalationTests
```
Expected: PASS — 2 tests.

- [ ] **Step 6: Run the rest of the Config tests to verify no regression**

Run:
```bash
swift test --package-path packages/Config
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add packages/Config/Sources/Config/PerTurnSnapshot.swift \
        packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift
git commit -m "$(cat <<'EOF'
feat(config): add escalationEnabled field to PerTurnSnapshot

Defaults to true. Custom decoder uses decodeIfPresent so older configs
without the field opt into the new local-first behavior on upgrade.

Refs design spec §6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Flip `default-config.json` default + add escalation field

**Files:**
- Modify: `packages/Config/Sources/Config/Resources/default-config.json`

- [ ] **Step 1: Write the failing test**

Add to `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`:

```swift
func test_default_config_resource_is_local_first() throws {
    let url = Bundle.module.url(forResource: "default-config", withExtension: "json")!
    let data = try Data(contentsOf: url)
    let snapshot = try JSONDecoder().decode(PerTurnSnapshot.self, from: data)
    XCTAssertEqual(snapshot.provider, .ollama,
        "default-config.json must specify ollama as the default chat-turn provider (local-first)")
    XCTAssertTrue(snapshot.escalationEnabled,
        "default-config.json must enable escalation for new users (local-first)")
}
```

- [ ] **Step 2: Run test, verify it fails**

Run:
```bash
swift test --package-path packages/Config --filter test_default_config_resource_is_local_first
```
Expected: FAIL — `provider == .anthropic` not `.ollama`.

- [ ] **Step 3: Flip the JSON**

Edit `packages/Config/Sources/Config/Resources/default-config.json`:

```json
{
  "schemaVersion": 1,
  "ollama": {
    "baseURL": "http://127.0.0.1:11434"
  },
  "applescript": {
    "confirmationRequired": true
  },
  "provider": "ollama",
  "escalationEnabled": true,
  "tts": { "tier": "tier1" },
  "stt": { "whisperKitFallback": false },
  "featureFlags": {
    "orpheusTTSEnabled": false,
    "whisperKitSTTEnabled": false
  },
  "toolBlocklist": [],
  "confirmationPolicy": { "timeoutSeconds": 60 },
  "logging": { "fileLevel": "info", "osLogLevel": "info" }
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
swift test --package-path packages/Config --filter test_default_config_resource_is_local_first
```
Expected: PASS.

- [ ] **Step 5: Full Config package test**

```bash
swift test --package-path packages/Config
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add packages/Config/Sources/Config/Resources/default-config.json \
        packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift
git commit -m "$(cat <<'EOF'
feat(config): default to local-first (ollama + escalation enabled)

Closes the policy half of the local-first routing spec. Pinned-anthropic
and pinned-ollama remain valid via Settings.

Refs design spec §1, §6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Detect Ollama-side failure kinds in the provider parser

**Files:**
- Modify: `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` (or whichever file owns the streaming parser; if split into multiple files, modify the one that decodes `tool_calls` and detects empty responses)

**Note for executor:** This is the most code-heavy task. Before writing code, run:
```bash
ls packages/AgentCore/Sources/OllamaProvider/
```
to locate the parser. Likely files include `OllamaProvider.swift`, `OllamaNDJSONDecoder.swift`, or similar.

- [ ] **Step 1: Add failing test for malformedToolCall detection**

Create `packages/AgentCore/Tests/OllamaProviderTests/OllamaFailureDetectionTests.swift`:

```swift
import XCTest
@testable import OllamaProvider
@testable import AgentCore

final class OllamaFailureDetectionTests: XCTestCase {
    func test_malformed_tool_call_emits_provider_error() async throws {
        // NDJSON chunk that says "tool_calls present" but with a non-decodable arguments payload
        let badChunk = #"""
        {"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":"this is not json"}}]},"done":false}
        {"done":true}
        """#

        let events = try await collectEvents(decoding: badChunk)
        XCTAssertTrue(events.contains { event in
            if case .providerError(let err) = event,
               case .malformedToolCall = err.kind { return true }
            return false
        }, "Expected providerError(.malformedToolCall) on undecodable tool_calls payload")
    }

    func test_empty_response_emits_provider_error() async throws {
        // Stream that closes with zero textDelta and zero toolUseRequested
        let emptyChunk = #"""
        {"message":{"role":"assistant","content":""},"done":true}
        """#

        let events = try await collectEvents(decoding: emptyChunk)
        XCTAssertTrue(events.contains { event in
            if case .providerError(let err) = event,
               case .emptyResponse = err.kind { return true }
            return false
        }, "Expected providerError(.emptyResponse) on terminated stream with no content")
    }

    // helper — engineer wires this to the actual parser entrypoint; see OllamaProvider.swift
    private func collectEvents(decoding ndjson: String) async throws -> [LLMEvent] {
        // ... call the parser with ndjson as Data and collect emitted events
        // Implementation depends on parser API; if there's already a unit test
        // file calling the parser, follow that pattern.
        fatalError("Replace this fatalError with the actual parser invocation pattern")
    }
}
```

**Important:** the `collectEvents` helper is engineer-completed when the parser API is known. Look at existing OllamaProvider unit tests (`packages/AgentCore/Tests/OllamaProviderTests/`) for a working pattern and copy it.

- [ ] **Step 2: Run test, verify it fails**

```bash
swift test --package-path packages/AgentCore --filter OllamaFailureDetectionTests
```
Expected: FAIL — either `.malformedToolCall` / `.emptyResponse` don't exist as `LLMProviderError.Kind` yet, or parser doesn't emit them.

- [ ] **Step 3: Add `OllamaFailureKind` mapping into `LLMProviderError`**

The simplest wiring: add a `kind: OllamaFailureKind?` field to `LLMProviderError`, OR add a parallel constructor that carries an `OllamaFailureKind`. Engineer picks the approach that disrupts the existing error type least. Read `packages/AgentCore/Sources/AgentCore/LLMEvent.swift` for the current `LLMProviderError` shape.

If the existing shape doesn't support carrying a typed kind, add an extension type:

```swift
public extension LLMProviderError {
    var ollamaFailureKind: OllamaFailureKind? {
        // Decode from userInfo or a dedicated field; engineer chooses.
        // For the spec, what matters is that the orchestrator can ask:
        // "did this error indicate an OllamaFailureKind?"
        get { /* return self.userInfo["ollamaFailureKind"] as? OllamaFailureKind */ nil }
    }
}
```

- [ ] **Step 4: Implement the parser detection**

In the OllamaProvider parser, around the `tool_calls` decode site:

```swift
// Existing: decode tool_calls into ToolUseRequest
do {
    let toolCall = try JSONDecoder().decode(ToolCallShape.self, from: payload)
    // ... emit toolUseRequested
} catch {
    // NEW: malformed tool_call → emit providerError + close
    let err = LLMProviderError.malformedToolCall(underlying: error)
    continuation.yield(.providerError(err))
    continuation.finish()
    return
}
```

At the `done: true` terminator handler:

```swift
// NEW: detect emptyResponse
if !sawAnyTextDelta && !sawAnyToolUseRequested {
    let err = LLMProviderError.emptyResponse
    continuation.yield(.providerError(err))
    continuation.finish()
    return
}
// Existing: emit messageStop
continuation.yield(.messageStop)
continuation.finish()
```

Engineer adapts to the actual variable names and continuation pattern in the existing code.

- [ ] **Step 5: Run all OllamaProvider tests**

```bash
swift test --package-path packages/AgentCore --filter OllamaProviderTests
```
Expected: all pass including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add packages/AgentCore/Sources/OllamaProvider/ \
        packages/AgentCore/Tests/OllamaProviderTests/ \
        packages/AgentCore/Sources/AgentCore/LLMEvent.swift
git commit -m "$(cat <<'EOF'
feat(ollama): detect malformedToolCall and emptyResponse failure kinds

Wire detection into the NDJSON parser. Emits LLMProviderError with
typed OllamaFailureKind for orchestrator-side escalation decisions.

Refs design spec §2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Extend `AgentOrchestrator` escalation logic

**Files:**
- Modify: `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` (lines 780–819 area)
- Modify: `packages/AgentCore/Tests/AgentOrchestratorTests/` — add `LocalFirstEscalationTests.swift`

- [ ] **Step 1: Write failing test for reactive fallback**

Create `packages/AgentCore/Tests/AgentOrchestratorTests/LocalFirstEscalationTests.swift`:

```swift
import XCTest
@testable import AgentOrchestrator
@testable import AgentCore
import Harness

final class LocalFirstEscalationTests: XCTestCase {
    func test_malformed_tool_call_triggers_one_escalation_to_anthropic() async throws {
        // Use MockLLMProvider with a fixture that returns malformedToolCall on first call
        // and a clean response on second (Anthropic) call.
        let mock = MockLLMProvider(scriptedSequence: [
            .ollamaNDJSON(named: "malformed-tool-call.ndjson"),  // fixture forthcoming
            .anthropicSSE(named: "happy-path.sse")                // existing fixture
        ])
        let orchestrator = makeOrchestrator(providerFactory: { selection in
            // first call → ollama, second call → anthropic
            return mock
        }, perTurn: PerTurnSnapshot(
            schemaVersion: 1,
            provider: .ollama,
            escalationEnabled: true,
            tts: .default, stt: .default, featureFlags: .default
        ))

        let events = try await orchestrator.runOneTurn(input: "test")

        XCTAssertTrue(events.contains { if case .escalated(let dec) = $0,
            dec.reason == .malformedToolCall { return true } else { return false } },
            "Expected one escalation event with reason malformedToolCall")
        XCTAssertEqual(mock.callCount, 2, "Expected one retry after malformedToolCall")
    }

    func test_escalation_budget_is_one_per_turn() async throws {
        // Both ollama AND anthropic fail. Assert orchestrator surfaces error,
        // does NOT loop, emits exactly one .escalated event.
        let mock = MockLLMProvider(scriptedSequence: [
            .ollamaNDJSON(named: "malformed-tool-call.ndjson"),
            .anthropicSSE(named: "stream-truncated.sse")  // anthropic also fails
        ])
        let orchestrator = makeOrchestrator(providerFactory: { _ in mock },
            perTurn: PerTurnSnapshot(
                schemaVersion: 1,
                provider: .ollama, escalationEnabled: true,
                tts: .default, stt: .default, featureFlags: .default
            ))

        let events = try await orchestrator.runOneTurn(input: "test")

        let escalationCount = events.filter { if case .escalated = $0 { return true } else { return false } }.count
        XCTAssertEqual(escalationCount, 1, "Budget is one escalation per turn")
        XCTAssertTrue(events.contains { if case .error = $0 { return true } else { return false } },
            "Expected final error after second-provider failure")
    }

    func test_escalation_disabled_surfaces_error_directly() async throws {
        // perTurn.escalationEnabled = false. Ollama fails. Assert NO escalation,
        // error surfaced directly, MockLLMProvider called once.
        let mock = MockLLMProvider(scriptedSequence: [
            .ollamaNDJSON(named: "malformed-tool-call.ndjson")
        ])
        let orchestrator = makeOrchestrator(providerFactory: { _ in mock },
            perTurn: PerTurnSnapshot(
                schemaVersion: 1,
                provider: .ollama, escalationEnabled: false,
                tts: .default, stt: .default, featureFlags: .default
            ))

        let events = try await orchestrator.runOneTurn(input: "test")

        XCTAssertEqual(mock.callCount, 1, "Disabled escalation must not retry")
        XCTAssertFalse(events.contains { if case .escalated = $0 { return true } else { return false } },
            "No escalation event when escalationEnabled=false")
    }

    // Engineer-completed helper — call the orchestrator's actual public run API
    private func makeOrchestrator(providerFactory: @escaping (ProviderSelection) async throws -> any LLMProvider,
                                  perTurn: PerTurnSnapshot) -> AgentOrchestrator {
        fatalError("Replace with actual AgentOrchestrator init using providerFactory + perTurn")
    }
}
```

**Engineer task:** look at existing `AgentOrchestratorTests` for the orchestrator's actual init/run public surface and replace the fatalErrors with real calls. The fixtures (`malformed-tool-call.ndjson`, `stream-truncated.sse`) should be added under `packages/Harness/Resources/fixtures/` following the existing convention. If new fixtures are needed, mark them as part of this task and copy from the closest existing analog.

- [ ] **Step 2: Run test, verify it fails**

```bash
swift test --package-path packages/AgentCore --filter LocalFirstEscalationTests
```
Expected: FAIL — orchestrator doesn't yet emit `.escalated`, doesn't retry on `malformedToolCall`.

- [ ] **Step 3: Extend orchestrator retry logic**

Edit `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` around lines 780–819. The existing pattern matches on `case .streamTruncated:`. Add a sibling branch:

```swift
// Existing branch — keep.
case .streamTruncated:
    // ... existing retry-on-streamTruncated code ...

// NEW branch — covers all OllamaFailureKind cases except streamTruncated
// (which already had its own handler). Engineer chooses whether to fold
// streamTruncated into this branch or keep them parallel.
case .providerError(let err) where err.ollamaFailureKind != nil:
    let failureKind = err.ollamaFailureKind!
    guard perTurn.escalationEnabled,
          perTurn.resolvedProvider == .ollama,
          !escalatedThisTurn else {
        // Escalation disabled, provider isn't ollama, or budget exhausted.
        // Surface the error.
        await events.send(.error(turnId: currentTurnId, error: .ollamaFailureFinal(failureKind)))
        escalatedThisTurn = false
        return
    }

    escalatedThisTurn = true
    let decision = EscalationDecision(
        from: .ollama,
        to: .anthropic,
        reason: failureKind,
        firedAt: Date()
    )
    // Emit to orchestrator events (will be relayed to bus) and to bus directly
    await events.send(.escalated(decision))

    // Swap provider for the rest of the turn
    var updated = perTurn
    updated = updated.with(provider: .anthropic)
    nextProvider = try await providerFactory(updated.resolvedProvider)
    // ... continue retry pattern matching the streamTruncated branch ...
```

Add `escalatedThisTurn: Bool = false` to the orchestrator's per-turn state (resets on each new turn). Add `case escalated(EscalationDecision)` to whatever event enum the orchestrator emits internally to consumers.

Add `func with(provider: ProviderSelection) -> Self` to `PerTurnSnapshot` as a convenience method (or inline the construction).

- [ ] **Step 4: Run tests**

```bash
swift test --package-path packages/AgentCore --filter LocalFirstEscalationTests
```
Expected: 3 pass.

```bash
swift test --package-path packages/AgentCore
```
Expected: all pre-existing orchestrator tests still pass (no regression).

- [ ] **Step 5: Commit**

```bash
git add packages/AgentCore/
git commit -m "$(cat <<'EOF'
feat(orchestrator): reactive escalation from ollama to anthropic

Extend the existing per-turn retry hook (formerly streamTruncated-only)
to handle all OllamaFailureKind cases. Enforces at-most-one escalation
per turn; second failure surfaces ollamaFailureFinal.

Refs design spec §2, §3.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add `BusOutbound.escalated` event

**Files:**
- Modify: `packages/Bus/Sources/Bus/BusOutbound.swift`
- Modify: `packages/Bus/Tests/BusTests/CodableRoundTripTests.swift`
- Modify: `webview/packages/bus/src/bridge.ts` (TS decoder)
- Modify: `webview/packages/bus/src/bridge.test.ts` (if it exists)
- Modify: `scripts/check-bus-harness-parity.sh` (likely no changes needed; verify)

- [ ] **Step 1: Write failing Swift test**

Add to `packages/Bus/Tests/BusTests/CodableRoundTripTests.swift`:

```swift
func test_escalated_round_trips() throws {
    let decision = EscalationDecision(
        from: .ollama, to: .anthropic,
        reason: .malformedToolCall,
        firedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let event = BusOutbound.escalated(decision)
    let data = try BusOutbound.encoder.encode(event)
    let decoded = try JSONDecoder().decode(BusOutbound.self, from: data)
    XCTAssertEqual(decoded, event)
}
```

- [ ] **Step 2: Run, verify fail**

```bash
swift test --package-path packages/Bus --filter test_escalated_round_trips
```
Expected: FAIL — `.escalated` not a case.

- [ ] **Step 3: Add the case**

Edit `packages/Bus/Sources/Bus/BusOutbound.swift`:

```swift
import AgentCore  // for EscalationDecision

public enum BusOutbound: Equatable, Sendable {
    // ... existing cases ...
    case audioLevel(rms: Float)
    case escalated(EscalationDecision)   // NEW

    public enum Kind: String, Sendable {
        // ... existing cases ...
        case audioLevel
        case escalated   // NEW
    }
}
```

Update the encode/decode logic in `BusOutboundCodec.swift` (or wherever the JSON shape is defined) to handle the new case. Use the pattern of existing cases — engineer reads file first to find the right place to add.

Add to the TS side at `webview/packages/bus/src/bridge.ts`:

```typescript
export type BusOutbound =
    // ... existing variants ...
    | { kind: "audioLevel"; rms: number }
    | { kind: "escalated"; decision: { from: string; to: string; reason: string; firedAt: string } };
```

And update the decoder switch. Run `pnpm --filter @jarvis/bus build` to regenerate `dist/`.

- [ ] **Step 4: Run all tests**

```bash
swift test --package-path packages/Bus
cd webview && pnpm --filter @jarvis/bus test && cd ..
```
Expected: pass.

- [ ] **Step 5: Run boundary gates**

```bash
bash scripts/check-bus-harness-parity.sh
bash scripts/check-bus-protocol-version.sh
```
Expected: PASS (bump protocol version if the script demands it — read the failure message).

- [ ] **Step 6: Commit**

```bash
git add packages/Bus/ webview/packages/bus/
git commit -m "$(cat <<'EOF'
feat(bus): add BusOutbound.escalated event

Carries the EscalationDecision for HUD-side badge rendering. TS decoder
updated; protocol version bumped if required by the parity gate.

Refs design spec §4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: HUD `EscalationBadge` component

**Files:**
- Create: `webview/packages/hud/src/components/EscalationBadge.tsx`
- Create: `webview/packages/hud/src/components/EscalationBadge.test.tsx`
- Modify: the chat-message renderer (engineer locates — likely `webview/packages/hud/src/components/MessageList.tsx` or similar)

- [ ] **Step 1: Write failing component test**

Create `webview/packages/hud/src/components/EscalationBadge.test.tsx`:

```typescript
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { EscalationBadge } from "./EscalationBadge";

describe("EscalationBadge", () => {
    it("renders the failure reason in a friendly form", () => {
        render(<EscalationBadge reason="malformedToolCall" />);
        expect(screen.getByText(/malformed tool call/i)).toBeInTheDocument();
        expect(screen.getByText(/escalated to opus/i)).toBeInTheDocument();
    });

    it("uses a stable test id for selector use", () => {
        render(<EscalationBadge reason="streamTruncated" />);
        expect(screen.getByTestId("escalation-badge")).toBeInTheDocument();
    });
});
```

- [ ] **Step 2: Run, verify fail**

```bash
cd webview && pnpm --filter @jarvis/hud test EscalationBadge && cd ..
```
Expected: FAIL — `EscalationBadge` module doesn't exist.

- [ ] **Step 3: Implement component**

Create `webview/packages/hud/src/components/EscalationBadge.tsx`:

```typescript
import React from "react";

type Reason =
    | "streamTruncated" | "malformedToolCall" | "unknownTool"
    | "refusal" | "connectionFailure" | "emptyResponse";

const FRIENDLY: Record<Reason, string> = {
    streamTruncated: "stream truncated",
    malformedToolCall: "malformed tool call",
    unknownTool: "unknown tool",
    refusal: "refusal",
    connectionFailure: "connection failure",
    emptyResponse: "empty response",
};

export function EscalationBadge({ reason }: { reason: Reason }) {
    return (
        <span data-testid="escalation-badge" className="escalation-badge">
            Escalated to Opus — {FRIENDLY[reason]}
        </span>
    );
}
```

Add minimal CSS for `.escalation-badge` to the existing HUD stylesheet (engineer picks the right file; pattern follows other badge styles).

Wire the badge into the message-list renderer: when a `BusOutbound.escalated` event arrives, attach the reason to the message it relates to (the most-recent assistant message), then render `<EscalationBadge reason={msg.escalation.reason} />` inline.

- [ ] **Step 4: Run tests**

```bash
cd webview && pnpm --filter @jarvis/hud test && pnpm --filter @jarvis/hud build && cd ..
```
Expected: all tests pass, build succeeds, `webview/packages/hud/dist/` populated.

- [ ] **Step 5: Run webview build script for App Resources**

```bash
bash scripts/build-webview.sh
ls App/Resources/webview/assets/
```
Expected: directory contains only the active bundle (cleanup from #46 still works).

- [ ] **Step 6: Commit**

```bash
git add webview/packages/hud/
git commit -m "$(cat <<'EOF'
feat(hud): EscalationBadge component for local-first escalation events

Inline badge that renders alongside the assistant message when a turn
was escalated from ollama to anthropic. Reason mapped to friendly text.

Refs design spec §4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Settings UI — Provider preference picker

**Files:**
- Modify: existing Settings view file (engineer locates — try `App/Sources/App/Settings/` or `App/Views/Settings/`)

- [ ] **Step 1: Locate Settings view**

```bash
find App -name "*.swift" | xargs grep -l "SettingsView\|@AppStorage.*provider\|ProviderSelection" 2>/dev/null | head -5
```
Engineer picks the right file.

- [ ] **Step 2: Add Provider section to Settings**

Add a `Picker` bound to a derived `ProviderMode` enum:

```swift
// In SettingsView.swift (or whichever file is the Settings root)
enum ProviderMode: String, CaseIterable, Identifiable {
    case localFirst    // .ollama + escalationEnabled
    case anthropicOnly // .anthropic
    case ollamaOnly    // .ollama + !escalationEnabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .localFirst: return "Local-first (recommended)"
        case .anthropicOnly: return "Anthropic only"
        case .ollamaOnly: return "Ollama only"
        }
    }
}

// In the view:
Section("Provider") {
    Picker("Mode", selection: $providerMode) {
        ForEach(ProviderMode.allCases) { mode in
            Text(mode.label).tag(mode)
        }
    }
}
.onChange(of: providerMode) { _, newValue in
    let (provider, escalation): (ProviderSelection, Bool) = {
        switch newValue {
        case .localFirst: return (.ollama, true)
        case .anthropicOnly: return (.anthropic, false)
        case .ollamaOnly: return (.ollama, false)
        }
    }()
    Task { await configStore.updatePerTurn { snap in
        snap.with(provider: provider, escalationEnabled: escalation)
    } }
}
```

Add `func with(provider: ProviderSelection, escalationEnabled: Bool? = nil) -> PerTurnSnapshot` to `PerTurnSnapshot` to keep the call site clean.

- [ ] **Step 3: Manual UI verification**

```bash
bash scripts/check-app-builds.sh
open build/Build/Products/Debug/Jarvis.app
```
Open Settings → Provider section. Toggle between the three modes. Verify each toggle updates `default-config.json` (or wherever the runtime persists user settings) and that the running app picks up the change without a restart (`ConfigStore` actor handles hot-reload).

- [ ] **Step 4: Commit**

```bash
git add App/
git commit -m "$(cat <<'EOF'
feat(settings): provider mode picker — Local-first / Anthropic only / Ollama only

Three-way picker maps to the {provider, escalationEnabled} pairs. Wired
to ConfigStore for hot-reload. Local-first is the new default.

Refs design spec §6.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Full verification + open PR

**Files:** none (verification + git only)

- [ ] **Step 1: Run all SPM package tests**

```bash
for pkg in AgentCore Bus Config Harness Memory Vision Voice MCP Shell Replay Keychain Logging DevOverlay; do
    echo "=== $pkg ==="
    swift test --package-path packages/$pkg || { echo "FAIL: $pkg"; break; }
done
```
Expected: every package passes.

- [ ] **Step 2: Run all boundary gates**

```bash
for s in scripts/check-*.sh; do
    [[ "$s" == "scripts/check-app-builds.sh" ]] && continue
    printf "%-60s " "$s"
    bash "$s" >/dev/null 2>&1 && echo PASS || echo "FAIL"
done
```
Expected: all PASS.

- [ ] **Step 3: Build the App target**

```bash
bash scripts/check-app-builds.sh
```
Expected: `[check-app-builds] PASS — App target compiles cleanly`.

- [ ] **Step 4: Run the webview test suite**

```bash
cd webview && pnpm --filter @jarvis/hud test && pnpm --filter @jarvis/bus test && cd ..
```
Expected: all pass.

- [ ] **Step 5: Push branch**

```bash
git push -u origin feat/local-first-llm-routing
```
Expected: new branch on origin.

- [ ] **Step 6: Open PR**

```bash
gh pr create --title "feat: local-first LLM routing with reactive Opus escalation" \
    --body "$(cat <<'EOF'
## Summary

Implements the local-first LLM routing design spec (PR #197). Chat turns now default to local Ollama (`qwen2.5-coder:32b-instruct-q8_0`); if Ollama fails in any of six detectable ways, the orchestrator escalates the same turn to Claude Opus 4.7 and the HUD shows a one-line badge on the affected message.

## Behavior changes

- New `default-config.json` ships `provider: "ollama"` and `escalationEnabled: true`.
- Old configs without `escalationEnabled` decode with the field defaulting to `true` (opt-in on upgrade).
- Settings → Provider section has a three-way picker: Local-first / Anthropic only / Ollama only.
- Per-turn escalation budget is 1. A second failure on the same turn surfaces `ollamaFailureFinal`.

## What this PR does NOT do

- No predictive routing or router model
- No "continue from partial Ollama output" — clean restart on escalation
- No automatic re-Ollama after Anthropic finishes
- No memory-extraction changes (already Ollama-only)

## Test plan

- [ ] Default fresh install uses Ollama (`PerTurnSnapshotTests.test_default_config_resource_is_local_first`)
- [ ] `malformedToolCall` triggers one escalation (`LocalFirstEscalationTests.test_malformed_tool_call_triggers_one_escalation_to_anthropic`)
- [ ] Escalation budget honored when both providers fail (`...test_escalation_budget_is_one_per_turn`)
- [ ] `escalationEnabled=false` mode surfaces error directly (`...test_escalation_disabled_surfaces_error_directly`)
- [ ] `BusOutbound.escalated` round-trips (`CodableRoundTripTests.test_escalated_round_trips`)
- [ ] HUD badge renders with friendly reason text (`EscalationBadge.test.tsx`)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Wait for CI green and merge**

Watch CI (boundary gates + 13 SPM jobs + App target + webview). On green, merge with `gh pr merge <num> --squash --delete-branch`. Memory-flake disposition from Wave 1 still applies — one rerun on `SPM Memory` or `SPM AgentCore` failure, then merge if it passes.

---

## Self-review check (run after writing tasks; this is the planner's own checklist, not a deliverable)

**Spec coverage:**
- §1 default flip → Task 4
- §2 trigger taxonomy → Tasks 2 (types), 5 (detection), 6 (orchestrator switch)
- §3 escalation contract → Task 2 (EscalationDecision), Task 6 (per-turn budget)
- §4 bus event + badge → Tasks 7 (bus), 8 (HUD)
- §5 per-turn vs sticky → Task 6 (`escalatedThisTurn` resets per turn)
- §6 Settings UX → Task 9
- §7 testing → Tasks 2, 3, 5, 6, 7, 8 (each task is TDD)
- §8 non-goals → enforced by what tasks do NOT do
- §9 effort → 10 tasks ~3-4 hrs total

**Placeholder scan:** the `fatalError` placeholders in Task 5 and Task 6 test helpers are deliberate — they signal "engineer-completed when the parser API is known". This is acceptable because the surrounding test structure is complete; only the helper invocation pattern is engineer-discoverable. Mark these clearly so they aren't missed.

**Type consistency:**
- `OllamaFailureKind` used in Tasks 2 → 5 → 6 → 7 → 8 → consistent name throughout.
- `EscalationDecision` used in Tasks 2 → 6 → 7 → 8 → consistent name throughout.
- `PerTurnSnapshot.escalationEnabled` used in Tasks 3 → 4 → 6 → 9 → consistent name throughout.
- `BusOutbound.escalated(EscalationDecision)` used in Tasks 7 → 8 → consistent signature.
- `ProviderSelection` (existing) referenced throughout as `.ollama` / `.anthropic`.

No type drift detected.
