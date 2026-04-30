# Phase 8: Hardening — Pattern Map

**Mapped:** 2026-04-30
**Files analyzed:** ~32 new + 2 modified surfaces (plus per-phase YAML sweep across P1–P7)
**Analogs found:** 30 / 32 new files have a strong in-tree analog

This artifact maps every Phase 8 surface (the new `packages/Harness` SPM module
+ corpora + scripts + retroactive checklist YAMLs) to the closest existing
analog in the codebase. §1 is the file → role / data-flow / analog table; §2
is per-file pattern excerpts the planner can copy into action sections; §3 is
the shared-pattern catalog (S-1..S-7); §4 is the no-analog / highest-risk
scaffold list.

P8 is greenfield harness code that **wraps and exercises** the P1–P7
pipeline — it does not modify it, except for one surgical change: extending
the `TurnSource` enum with `.replay(sessionId:)` and `.eval(scenarioId:)`
cases per R4-L7, plus computed `dispatchesToHUD` / `speaks` properties that
existing call-sites already implicitly trust because the current cases
(`.text`, `.voice`, `.memoryExtraction`) are exhaustively switched.

---

## §1. File Classification

### 1a. New files (`packages/Harness` library + executable)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `packages/Harness/Package.swift` | config | n/a | `packages/Memory/Package.swift` | exact |
| `packages/Harness/Sources/Harness/Oracle/ExclusionList.swift` | model | n/a | `packages/Replay/Sources/Replay/ReplayEvent.swift` (Codable enum + `Set<String>` constants) | role-match |
| `packages/Harness/Sources/Harness/Oracle/DriftReport.swift` | model | n/a | `packages/Replay/Sources/Replay/ReplayEvent.swift` (hand-written `Codable`, exhaustive switch) | role-match |
| `packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift` | service | transform (pure fn) | `packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift` (state-machine over input bytes; `dispatch` static fn) | role-match |
| `packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift` | service / adapter | request-response (replay) | `packages/MCP/Sources/MCP/MCPToolDispatcher.swift` (the protocol it conforms to) + `packages/MCP/Sources/MCP/InProcess/` (existing in-process dispatcher patterns) | exact (same protocol) |
| `packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift` | service / adapter | streaming (fixture bytes) | `packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift` (already replays SSE bytes through SSELineReader → SSEDecoder → `[LLMEvent]`) | exact (lift from test → library) |
| `packages/Harness/Sources/Harness/Runners/ReplayRunner.swift` | controller / actor | event-driven (consumes orchestrator events) | `packages/Memory/Sources/Memory/MemoryOrchestrator.swift` (background turn-driver actor that calls `AgentOrchestrator.submit(.memoryExtraction)`) | exact (same shape: actor wraps orchestrator submit + replay channel drain) |
| `packages/Harness/Sources/Harness/Runners/InjectionCorpusRunner.swift` | controller | request-response (corpus item → outcome) | `packages/Memory/Sources/Memory/MemoryOrchestrator.swift` | role-match |
| `packages/Harness/Sources/Harness/Runners/SSEFixtureRunner.swift` | controller | streaming (file → events) | `packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift` lines 30-60 | exact |
| `packages/Harness/Sources/Harness/Runners/NDJSONFixtureRunner.swift` | controller | streaming (file → events) | `packages/AgentCore/Tests/OllamaProviderTests/FixtureReplayTests.swift` (counterpart pattern) | exact |
| `packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` | controller | streaming (HTTP) | `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` + preflight curl pattern | role-match (preflight is new) |
| `packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift` | controller | request-response | `packages/AgentCore/Tests/AgentOrchestratorTests/` (existing R4-L1 cap-recovery tests) | exact |
| `packages/Harness/Sources/Harness/Runners/WakeHysteresisRunner.swift` | controller | streaming (WAV → frames) | `packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift` (scripted-prob feeder pattern) | exact (lift + extend with WAV decoder) |
| `packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` | controller | event-driven (SIGKILL loop) | `packages/MCP/Tests/MCPTests/MCPRestartTests.swift` lines 1-100 (100-cycle crash loop already exists) | exact |
| `packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` | controller | event-driven | `packages/Voice/Tests/VoiceTests/TeardownTests.swift` (4-trigger rebuild matrix already exists in swift-testing) | exact |
| `packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift` | controller | batch (read YAML → run mechanizations) | `scripts/check-bus-protocol-version.sh` (the unit each `type: script` row delegates to) + new YAML decoder | partial — see §4 |
| `packages/Harness/Sources/Harness/FDLeakDetector.swift` | utility | transform (lsof → Set) | `packages/MCP/Tests/MCPTests/MCPRestartTests.swift` `countOpenFDs()` (`/dev/fd` enumeration; the lsof approach is a richer alternative) | role-match |
| `packages/Harness/Sources/Harness/Corpus/InjectionCorpus.swift` | model | n/a (data) | `packages/Replay/Sources/Replay/ReplayEvent.swift` (hand-rolled `enum` + exhaustive switches, no `default`) | role-match |
| `packages/Harness/Sources/Harness/Corpus/SSEFixtureCorpus.swift` | model | n/a (data) | `packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/*.txt` (existing 9 SSE fixtures — happy/cache-hit/refusal/etc.) | exact (extend, don't rebuild) |
| `packages/Harness/Sources/Harness/Corpus/NDJSONFixtureCorpus.swift` | model | n/a (data) | `packages/AgentCore/Tests/OllamaProviderTests/Fixtures/*.txt` (existing 6 NDJSON fixtures) | exact (extend, don't rebuild) |
| `packages/Harness/Sources/Harness/Corpus/WakeHysteresisCorpus.swift` | model | n/a (data manifest) | `packages/Voice/Tests/VoiceTests/Fixtures/` + WakeWordHysteresisTests' scripted-prob array | role-match |
| `packages/Harness/Sources/jarvis-eval/main.swift` | executable | CLI dispatch | (no in-tree analog — first executable target; see §4) | none — research §Code Examples is the seed |
| `packages/Harness/Tests/HarnessTests/DriftClassifierTests.swift` | test | n/a | `packages/Replay/Tests/ReplayTests/SchemaTests.swift` (XCTest pattern) OR `packages/Voice/Tests/VoiceTests/TeardownTests.swift` (swift-testing pattern) | exact (D-03 picks swift-testing) |
| `packages/Harness/Tests/HarnessTests/ExclusionListTests.swift` | test | n/a | (same) | exact |
| `packages/Harness/Tests/HarnessTests/FDLeakDetectorTests.swift` | test | n/a | `packages/MCP/Tests/MCPTests/MCPServerHandleInitFailureFDLeakTests.swift` (source-level + runtime FD assertions) | exact |
| `packages/Harness/Corpora/injection/*.json` | corpus | n/a (data) | `packages/Bus/Tests/BusTests/Fixtures/` (committed fixture data per package) | role-match |
| `packages/Harness/Corpora/sse-anthropic/*.sse` | corpus | n/a (data) | `packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/*.txt` | exact (file-naming convention shift `.txt` → `.sse` per RESEARCH §Recommended Project Structure) |
| `packages/Harness/Corpora/ndjson-ollama/*.ndjson` | corpus | n/a (data) | `packages/AgentCore/Tests/OllamaProviderTests/Fixtures/*.txt` | exact |
| `packages/Harness/Corpora/wake-hysteresis/*.wav` + `labels.json` | corpus | n/a (data) | (no exact analog — WAV corpus is new; closest is `packages/Voice/Tests/VoiceTests/Fixtures/`) | partial — operator-recorded per host (D-18) |
| `packages/Harness/Corpora/replay-golden/*.sqlite` + `exclusions.json` | corpus | n/a (data) | (no in-tree analog — first time committing golden replay sessions) | none — see §4 + D-08/D-09/D-11 |
| `packages/Harness/Corpora/checklist/` (organizational marker; YAMLs live under `.planning/phases/`) | corpus | n/a | n/a | n/a |
| `scripts/shipping-gate.sh` | script | batch (invoke jarvis-eval all) | `scripts/check-bus-protocol-version.sh` + `scripts/verify-entitlements.sh` (bash-set-euo-pipefail + env-var indirection conventions) | exact |
| `scripts/capture-anthropic-sse.sh` | script | batch (curl → tee) | `scripts/check-bus-protocol-version.sh` (same shell-script discipline) | role-match |
| `scripts/promote-replay-session.sh` | script | batch (cp + sidecar JSON) | `scripts/check-bus-protocol-version.sh` (env-var indirection so a test harness can fault-inject) | role-match |
| `.planning/phases/{01..07}-*/checklist.yaml` (7 files) | corpus / config | n/a (YAML data) | RESEARCH §"Looks done but isn't" checklist manifest shape (lines 581-615) is the only seed | partial — see §4 + D-15/D-16/D-17 |

### 1b. Modified files

| File | Modification | Reason | Risk |
|------|--------------|--------|------|
| `packages/Replay/Sources/Replay/ReplayEvent.swift` (TurnSource enum at lines 7-11) | Add `case replay(sessionId: SessionID)` and `case eval(scenarioId: String)` | R4-L7 / D-01 — replay + eval suppression cases | **HIGH:** the enum is `String, Sendable, Equatable, Hashable, CaseIterable` with associated-value-free cases; adding associated values breaks `String` raw-representable conformance + breaks `CaseIterable`. Planner MUST split into a separate enum or relax the conformance set. See §4 for the recommended shape. Every `switch` over `TurnSource` in `Replay/ReplayLog.swift`, `AgentOrchestrator.runTurnLoop`, `Memory/ExtractionJob.swift`, `Bus/BusOutbound.swift` becomes a compile-time hit — that is the design intent (force every consumer to declare suppression policy). |
| `project.yml` | Add `Harness:` package entry under `packages:` block (mirror `Memory:` / `Voice:` lines) + add `jarvis-eval` executable target wiring | D-02 — Harness is a local SPM dep + the CLI is a standalone exe consumed by the App test bundle | LOW — mechanical mirror of existing rows |

### 1c. NOT modified (P8 is read-only against these)

`AgentOrchestrator.swift`, every `LLMProvider` conformer, `MCPClient`, `VoiceController`, `MemoryStore`, `ReplayLog` writer, `DevOverlay`, every webview / HUD file. The harness wraps the existing surfaces; suppression of TTS + bus dispatch comes from the new `TurnSource.dispatchesToHUD` / `.speaks` computed properties consumed at the EXISTING dispatch sites (which already switch over `TurnSource`).

---

## §2. Pattern Assignments

### 2.1 `packages/Harness/Package.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Memory/Package.swift` (most-recent multi-dependency package — strict-concurrency v6, depends on AgentCore + Replay + Logging in the same shape Harness needs).

**Why:** Harness needs every package the production pipeline does (it exercises the real components per RESEARCH §Pattern 1). The Memory `Package.swift` is the closest precedent because it spans Logging + AgentCore + Replay edges. Harness adds **MCP / Voice / Memory / Vision / DevOverlay** on top, plus the `swift-argument-parser` dependency for the CLI.

**Library + executable target shape excerpt** (Memory/Package.swift lines 1-60):

```swift
// swift-tools-version:6.0
//
// Package: Harness
//
// Phase 8 — eval matrix + replay-roundtrip oracle. Library target for reusable
// test plumbing (Oracle, Runners, Adapters, FDLeakDetector); executable target
// `jarvis-eval` exposes the eight pillars as swift-argument-parser
// subcommands. Tests-of-the-harness in Tests/HarnessTests/.
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],   // matches Voice (ORT 1.24.2 floor) for consistency
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "jarvis-eval", targets: ["jarvis-eval"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../Config"),
        .package(path: "../AgentCore"),
        .package(path: "../Replay"),
        .package(path: "../MCP"),
        .package(path: "../Voice"),
        .package(path: "../Memory"),
        .package(path: "../DevOverlay"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
                .product(name: "AnthropicProvider", package: "AgentCore"),
                .product(name: "OllamaProvider", package: "AgentCore"),
                .product(name: "Replay", package: "Replay"),
                .product(name: "JarvisMCP", package: "MCP"),
                .product(name: "Voice", package: "Voice"),
                .product(name: "Memory", package: "Memory"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Harness",
            resources: [
                .copy("../../Corpora"),  // ship corpora into bundle as resources
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "jarvis-eval",
            dependencies: [
                "Harness",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/jarvis-eval",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"],
            path: "Tests/HarnessTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

**Linker note:** Harness inherits all framework linkage (AVFoundation/Speech/etc.) transitively from Voice / Memory / etc. — no new `linkedFramework(...)` clauses required at the Harness level.

---

### 2.2 `packages/Replay/Sources/Replay/ReplayEvent.swift` — TurnSource extension (R4-L7)

**Analog:** Current TurnSource enum at lines 7-11 of the same file:

```swift
public enum TurnSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case text
    case voice
    case memoryExtraction
}
```

**Why this is the highest-risk modification in P8:** The existing enum's `String, RawRepresentable, CaseIterable` conformances are incompatible with associated-value cases. Naive addition of `case replay(sessionId: SessionID)` BREAKS:
- `String` raw representability (compile error)
- `CaseIterable` synthesis (compile error)
- The `turns.source` SQLite column writer in `ReplayLog.swift` line 85 (uses `source.rawValue`)
- Every consumer in `Memory/ExtractionJob.swift`, `Bus/BusOutbound.swift`

**Recommended shape — Strategy A (preferred — minimal call-site churn):** Keep `TurnSource` as the cohort tag (still String-rawValue), introduce a sibling `SuppressionPolicy` that the orchestrator consults at dispatch. `.replay` / `.eval` set the policy without polluting the rawValue column.

```swift
public enum TurnSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case text
    case voice
    case memoryExtraction
    case replay
    case eval
}

public struct SuppressionPolicy: Sendable, Equatable {
    public let dispatchesToHUD: Bool
    public let speaks: Bool
    public let mcpDispatcher: MCPDispatcherSelection  // .live or .replay(sessionId:)

    public static let user = SuppressionPolicy(dispatchesToHUD: true, speaks: true, mcpDispatcher: .live)
    public static let memoryExtraction = SuppressionPolicy(dispatchesToHUD: false, speaks: false, mcpDispatcher: .live)
    public static func replay(sessionId: SessionID) -> SuppressionPolicy {
        SuppressionPolicy(dispatchesToHUD: false, speaks: false, mcpDispatcher: .replay(sessionId: sessionId))
    }
    public static func eval(scenarioId: String) -> SuppressionPolicy {
        SuppressionPolicy(dispatchesToHUD: false, speaks: false, mcpDispatcher: .live)
    }
}

public enum MCPDispatcherSelection: Sendable, Equatable {
    case live
    case replay(sessionId: SessionID)
}
```

`TurnInput` gains a defaulted `policy: SuppressionPolicy = .user` field; existing call-sites compile unchanged.

**Strategy B (research-implied — associated values, accept the conformance pivot):** Drop `String, CaseIterable` from `TurnSource`, write a hand-rolled `var rawValue: String` switch for the SQLite column, update every consumer's switch. Higher churn; preserves the "single source of truth for cohort cases" research framing. Planner picks A or B; **do not silently pick** — note the chosen strategy in `08-01-PLAN.md`.

**Verification:** Whichever strategy lands, every existing `switch source` over `TurnSource` in the codebase must be re-checked for exhaustiveness. Run `grep -rn "switch.*source\b" packages/ App/` after the change; every hit must compile.

---

### 2.3 `packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift`
(Pure state-machine pattern; static `dispatch` fn; no actor / no async; mutable State struct; emit-via-closure idiom.)

**Why:** DriftClassifier is conceptually a state machine over two parallel event streams (recorded vs actual replay rows). SSEDecoder is the in-tree precedent for "pure Swift function over typed events with mutable State and closure emit" — same shape, different inputs.

**Pattern excerpt** (SSEDecoder.swift lines 15-63):

```swift
struct SSEDecoder: Sendable {
    /// Mutable state held across frames within one stream.
    struct State {
        var currentToolUseId: String? = nil
        // ...
    }

    static func dispatch(
        frame: SSEFrame,
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        switch frame.event {
        case "message_start":
            handleMessageStart(data: frame.data, state: &state, emit: emit)
        // ... exhaustive switch over event types ...
        default:
            // Unknown event name — log warning, continue. Don't throw.
            Self.log.warning("SSEDecoder: unknown event '\(frame.event, privacy: .public)'")
        }
    }
}
```

**Apply to DriftClassifier as:**

```swift
public struct DriftClassifier: Sendable {
    public static func classify(
        recorded: ReplayDB,
        actual: ReplayDB,
        exclusions: ExclusionList,
        recordingTemperature: Double
    ) -> DriftReport {
        var expected: [DriftItem] = []
        var unexpected: [DriftItem] = []

        // Walk paired rows by (turn_id, event_index) — turn_id IS in alwaysExcluded
        // for cross-row identity but rows must still align by ordinal position.
        // ... per-field comparison, consult exclusions, categorize remainder ...
        for (recRow, actRow) in zip(recorded.rows, actual.rows) {
            classifyRow(rec: recRow, act: actRow, exclusions: exclusions,
                        temperature: recordingTemperature,
                        emitExpected: { expected.append($0) },
                        emitUnexpected: { unexpected.append($0) })
        }
        return DriftReport(expected: expected, unexpected: unexpected)
    }
}
```

**Anti-pattern guard (RESEARCH §Anti-Patterns line 350):** Do NOT compare two replay logs with `diff` or string-equality — IDs and timestamps always differ. The exclusion-list + typed `DriftCategory` enum (`idOrTimestamp`, `samplingNondeterminism`, `schemaChange`, `orderingBug`, `truncationBug`, `valueBug`) is mandatory.

---

### 2.4 `packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift` lines 30-58

**Why:** This test file ALREADY DOES exactly what `MockLLMProvider` needs to do — read fixture bytes, push through `SSELineReader → SSEDecoder`, collect `[LLMEvent]`. P8 lifts the helper from a test method into a library type that conforms to `LLMProvider` so it can be plugged into the orchestrator.

**Pattern excerpt** (FixtureReplayTests.swift lines 30-58):

```swift
private func replay(fixture name: String) async throws -> [LLMEvent] {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "txt"),
        "fixture '\(name).txt' missing from test bundle"
    )
    let data = try Data(contentsOf: url)

    let stream = AsyncStream<UInt8> { continuation in
        for byte in data {
            continuation.yield(byte)
        }
        continuation.finish()
    }
    let reader = SSELineReader(bytes: stream)
    var state = SSEDecoder.State()
    var collected: [LLMEvent] = []
    for try await frame in reader.frames() {
        SSEDecoder.dispatch(frame: frame, state: &state) { event in
            collected.append(event)
        }
        if state.messageStopEmitted { break }
    }
    if !state.messageStopEmitted {
        SSEDecoder.flushOnEOF(state: &state) { collected.append($0) }
    }
    return collected
}
```

**Apply to MockLLMProvider as:**

```swift
public actor MockLLMProvider: LLMProvider {
    private let fixtureURL: URL
    public init(fixtureURL: URL) { self.fixtureURL = fixtureURL }

    public nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let data = try Data(contentsOf: fixtureURL)
                    // dispatch: SSE for .anthropic / NDJSON for .ollama, picked by extension
                    let events = try await Self.decodeFixture(data: data, kind: fixtureKind)
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
```

**Caveat (RESEARCH Pitfall 2 line 401):** Do NOT use a vacuous `MockLLMProvider` (e.g., one that just returns `"OK"`) for the injection-corpus runner — injection defenses are upstream of the LLM. The MockLLMProvider here is for **fixture-bytes-replay through the real decoder**, not for synthesizing fake LLM responses. The injection-corpus runner uses **fixture-recorded** Anthropic / Ollama streams so the nonce-wrap boundary is genuinely exercised.

---

### 2.5 `packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/MCP/Tests/MCPTests/MCPRestartTests.swift` lines 1-100 (100-cycle crash loop with `countOpenFDs()` snapshot, MockHelper builder, `MOCK_HELPER_CRASH_AFTER` env var)

**Why:** The 100-crash + FD-leak test that ROADMAP §OBS-04(f) specifies **already exists** in `MCPRestartTests`. P8's runner extracts the pattern out of XCTest into a swift-testing parameterized form, swaps `countOpenFDs()` for the richer `FDLeakDetector` (lsof-based, captures FD names not just counts), and adds the cycle-time profiling that D-19 mandates.

**Pattern excerpt — FD count snapshot** (MCPRestartTests.swift lines 29-34):

```swift
/// Counts open file descriptors in the current process by enumerating
/// `/dev/fd/`. POSIX-portable on macOS — same convention used by `lsof`
/// internally.
private func countOpenFDs() -> Int {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
        return 0
    }
    return entries.count
}
```

**Pattern excerpt — crash injection** (MCPRestartTests.swift lines 38-91): the MockHelper takes `MOCK_HELPER_CRASH_AFTER=N` env var and exits after N callTool invocations. Reuse the same helper builder (`packages/MCP/Tests/MCPTests/MockHelperBuilder.swift`) — do not author a new crash-helper.

**Apply in MCPCrashRunner:**

```swift
public actor MCPCrashRunner {
    public func run(crashes: Int = 100) async throws -> CrashReport {
        let helper = try MockHelperBuilder.build()
        let client = MCPClient()
        try await client.register(
            name: "mock-helper", binaryURL: helper,
            requiresConfirmation: false,
            extraEnvironment: ["MOCK_HELPER_CRASH_AFTER": "1"]
        )

        let baseline = try FDLeakDetector.snapshot()
        var samples: [(iter: Int, snap: FDSnapshot, elapsed: Duration)] = []

        for i in 0..<crashes {
            let t0 = ContinuousClock.now
            // trigger crash, await restart, callTool
            // ... (lift from MCPRestartTests test_singleCrash_followedBy_callTool ...)
            let elapsed = ContinuousClock.now - t0
            if i % 10 == 0 {
                samples.append((iter: i, snap: try FDLeakDetector.snapshot(), elapsed: elapsed))
            }
        }

        let final = try FDLeakDetector.snapshot()
        let delta = FDLeakDetector.delta(from: baseline, to: final)
        return CrashReport(crashCount: crashes, fdDelta: delta, samples: samples)
    }
}
```

**D-19 cycle-time profiling:** First run profiles per-crash duration. If > 200 ms, drop to 50 crashes per default; `--extended` flag forces 500. Document any reduction in REQUIREMENTS.md OBS-04 commentary.

---

### 2.6 `packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Voice/Tests/VoiceTests/TeardownTests.swift` (already in swift-testing; already covers the 4-trigger × 6-step matrix; uses `AudioGraphOwner` with `SucceedingBuilder` / mock builders)

**Why:** TeardownTests **already implements pillar (g)**. P8's runner is mostly an orchestration wrapper that runs each test method as a separate scenario, gathers PASS/FAIL into a `RebuildReport`, and degrades per D-14 if `AVAudioEngine` synthetic device-change injection is unavailable.

**Pattern excerpt** (TeardownTests.swift lines 15-80):

```swift
@Suite("TeardownTests", .serialized)
struct TeardownTests {
    @Test("T1: deviceChange trigger runs all six teardown steps in order then rebuilds")
    func deviceChangeTriggerRunsTeardown() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()
        let recorder = TeardownRecorder()
        // ... build AudioGraphOwner with a mock builder ...
        await owner.installRecorderSlots(recorder)
        try await owner.open()
        await owner.rebuild(trigger: .deviceChange)
        // ... assert all 6 teardown steps fired in order, then rebuild event emitted ...
    }
    // T2/T3/T4 follow same shape for AEC fallback / mic re-grant / sustained ring overflow
}
```

**Anti-pattern guard (RESEARCH Pitfall 7 line 451 + TeardownTests' `.serialized` trait):** Each trigger gets its own test method with explicit `setUp`/`tearDown`. **Never share an `AVAudioEngine` instance across triggers** — a bug that only manifests on AEC-fallback from a fresh graph stays hidden if the prior test pre-warmed the path.

**D-14 graceful degradation:** If `AVAudioEngine` synthetic device-change injection API turns out to be unavailable (RESEARCH A6, MEDIUM risk — "planner should probe `AVAudioSession` notification-posting API early"), the device-change trigger downgrades to a `MANUAL:` checklist item with operator instructions ("plug in / unplug USB-C audio interface mid-utterance"). The other 3 triggers stay automated. The degradation MUST be visible in shipping-gate output (no silent skip).

---

### 2.7 `packages/Harness/Sources/Harness/Runners/WakeHysteresisRunner.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift` lines 1-80 (scripted-prob-array feeder for `OpenWakeWordSession` — bypasses ONNX entirely for deterministic tests)

**Why:** P8 needs FAR/FRR over a per-host-recorded WAV corpus, but the **frame-feeder pattern** for hysteresis logic is identical. WakeWordHysteresisTests already drives `OpenWakeWordSession` through scripted classifier-output arrays; P8's runner adds the WAV-decode → mel → embedding → classifier upstream stages and counts fires across labeled WAVs.

**Pattern excerpt** (WakeWordHysteresisTests.swift lines 17-48):

```swift
func testH1_singletonSpike_noFire() async throws {
    let probs: [Float] = [0.6, 0.1, 0.0, 0.0, 0.0]
    let session = makeScriptedSession(probs: probs)

    let results = try await feedAll(session, count: probs.count)
    XCTAssertEqual(results.filter { $0 == .fired }.count, 0,
                   "Singleton spike MUST NOT trigger (H1)")
}
```

**Apply in WakeHysteresisRunner:**

```swift
public actor WakeHysteresisRunner {
    public func run(corpus: WakeHysteresisCorpus) async throws -> WakeReport {
        var truePositives = 0, falseNegatives = 0
        var falsePositives = 0, trueNegatives = 0
        var totalDurationSeconds: Double = 0

        for clip in corpus.clips {
            let frames = try WAVDecoder.decode(clip.url)  // 16 kHz mono Float32 → mel → embedding
            let session = makeProductionSession()  // real ONNX, not scripted
            let fired = try await feedAll(session, frames: frames).contains(.fired)
            totalDurationSeconds += clip.durationSeconds

            switch (clip.label, fired) {
            case (.positive, true): truePositives += 1
            case (.positive, false): falseNegatives += 1
            case (.negative, true): falsePositives += 1
            case (.negative, false): trueNegatives += 1
            }
        }
        let frrPct = Double(falseNegatives) / max(1, Double(truePositives + falseNegatives)) * 100
        let farPerHr = Double(falsePositives) / (totalDurationSeconds / 3600)
        return WakeReport(far: farPerHr, frr: frrPct, ...)
    }
}
```

**D-18 thresholds:** Fail at FAR > 1.0/hr OR FRR > 10%; warn between 2026-published targets (FAR < 0.5/hr, FRR < 5%) and the fail line. Warnings visible in shipping-gate output but don't block ship.

---

### 2.8 `packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift`

**Analog:** Not a single file — composite of:
- `packages/AgentCore/Tests/AgentOrchestratorTests/` (existing R4-L1 cap-recovery assertions)
- `packages/AgentCore/Sources/AgentCore/ToolChoice.swift` (the `ToolChoice.none` enum case)
- `packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift` (where `tool_choice: {"type":"none"}` serializes)

**Why:** R4-L1 says "cap-recovery turn must pass `tool_choice: .none`". RESEARCH Pitfall 5 (line 431) flags that asserting `.toolUseRequested == 0` is necessary-but-not-sufficient — you must ALSO inspect outbound HTTP request bytes. P8 runner needs both assertions.

**Pattern excerpt — outbound request body interception:** Use `URLProtocol` registration to capture the bytes. AnthropicProvider runs on `URLSession.shared`; tests can inject a `URLProtocol` subclass that records the request body and returns a canned SSE response.

```swift
final class CapturingURLProtocol: URLProtocol {
    static var capturedBodies: [Data] = []
    static var cannedResponse: Data = Data()  // SSE bytes for a no-tool-call turn

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody { Self.capturedBodies.append(body) }
        // (handle httpBodyStream variant — Anthropic uses streaming uploads for some shapes)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.cannedResponse)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

**Apply in ToolCapRecoveryRunner:**

```swift
public actor ToolCapRecoveryRunner {
    public func run() async throws -> CapRecoveryReport {
        // Setup orchestrator with capacity-1 tool-call budget so cap triggers immediately.
        URLProtocol.registerClass(CapturingURLProtocol.self)
        defer { URLProtocol.unregisterClass(CapturingURLProtocol.self) }

        // ... drive a turn that exhausts the cap, capture .toolUseRequested events ...
        let toolUseEventCount = ...
        let recoveryRequestBody = CapturingURLProtocol.capturedBodies.last!
        let json = try JSONSerialization.jsonObject(with: recoveryRequestBody) as! [String: Any]

        // Assertion (a): zero tool-use events
        let assertionA = (toolUseEventCount == 0)
        // Assertion (b): tool_choice serialized as {"type":"none"} on Anthropic
        let toolChoice = json["tool_choice"] as? [String: Any]
        let assertionB = (toolChoice?["type"] as? String == "none")

        return CapRecoveryReport(zeroToolUse: assertionA, noneSerialized: assertionB,
                                 capturedBody: recoveryRequestBody)
    }
}
```

**Ollama variant:** Drop `tools` array entirely (per CLAUDE.md tool-choice discipline note). Assertion (b) for Ollama is `json["tools"] == nil`.

---

### 2.9 `packages/Harness/Sources/Harness/FDLeakDetector.swift`

**Analog (1 — process-spawn pattern):** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/MCP/Sources/MCP/MCPServerHandle.swift` lines 89-117 (Foundation `Process` + Pipe stdout → readDataToEndOfFile)

**Analog (2 — FD enumeration):** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/MCP/Tests/MCPTests/MCPRestartTests.swift` lines 29-34 (`/dev/fd` directory enumeration — POSIX-portable, but yields **counts only**, not paths)

**Why hybrid:** RESEARCH §FD-Leak Detector (lines 555-578) specifies `lsof -p <pid> -F ftn` because counts alone hide which FD leaked. The Process spawn pattern from MCPServerHandle is the spawn template; the actual command is lsof.

**Pattern excerpt — Process + Pipe** (MCPServerHandle.swift):

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
process.arguments = ["-p", "\(pid)", "-F", "ftn"]
let pipe = Pipe()
process.standardOutput = pipe
try process.run()
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```

**Pitfall 6 / D-20 whitelist:** The steady-state FD set after MCPClient init includes (at minimum): replay-log SQLite WAL FD, SQLite journal FD, three pipes per registered helper (post-CR-01 cleanup), stderr readability handler. `FDLeakDetectorTests.swift` enumerates the expected baseline so a P8 source-level grep test fires when MCP-08 is regressed (cf. `MCPServerHandleInitFailureFDLeakTests.swift` for the pattern).

**Risk (A2 in RESEARCH §Assumptions):** `lsof -p ... -F ftn` is BSD-stable since macOS 10.x — low risk. **Edge cases requiring empirical probing:** FIFOs, socket inheritance, non-printable bytes in `path` fields. The `parseLsofTerse(data:)` helper must defend (not crash) against these.

---

### 2.10 `packages/Harness/Sources/Harness/Runners/InjectionCorpusRunner.swift`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/packages/Memory/Sources/Memory/MemoryOrchestrator.swift` (background actor that calls `AgentOrchestrator.submit(...)` for `.memoryExtraction` turns; SAME pattern P8 needs for the `.eval` cohort)

**Why:** Both run a turn through the real orchestrator with TTS+HUD suppressed. Memory's orchestrator is the closest in-tree precedent for "drive the orchestrator from outside the App for a non-user-facing turn type".

**Per-vector dispatch (D-22 — majority must be .toolResult / .mcpHelperOutput):**

```swift
public actor InjectionCorpusRunner {
    public func run(corpus: InjectionCorpus) async throws -> InjectionReport {
        var byOutcome: [InjectionAttempt.ID: ActualOutcome] = [:]
        for attempt in corpus.all {
            let actual: ActualOutcome
            switch attempt.vector {
            case .userInput:
                actual = try await runUserInputAttack(attempt)
            case .toolResult(let toolName):
                // Plant payload as the tool's response; orchestrator sees it
                // wrapped in <UNTRUSTED_CONTENT id={turnNonce}>...</UNTRUSTED_CONTENT>.
                // Assertion: wrapper present, sanitize-pass-marker present,
                // model-facing history shows wrapped payload (not raw).
                actual = try await runToolResultAttack(attempt, toolName: toolName)
            case .mcpHelperOutput(let helper):
                actual = try await runMCPHelperAttack(attempt, helper: helper)
            case .clipboardContent:
                actual = try await runClipboardAttack(attempt)
            case .appleScriptSourceDescription:
                actual = try await runAppleScriptDescAttack(attempt)
            }
            byOutcome[attempt.id] = actual
        }
        return InjectionReport(byOutcome: byOutcome, ...)
    }
}
```

**Anti-pattern (Pitfall 2 line 401):** `.userInput` corpus items test the harness, NOT the defenses (sanitize + nonce wrap live downstream of user input on the **untrusted** edge: tool results / MCP outputs / clipboard). Majority of 20+ items must be `.toolResult` or `.mcpHelperOutput`. D-24 explicitly mandates 2-3 items reach the confirmation-sheet layer (deep-defense check) — these must NOT be silently filtered as "expected blocks".

---

### 2.11 `packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift`

**Analog (partial):** No in-tree YAML reader yet. Closest analog is the **pattern of every `scripts/check-*.sh`** — they are the per-item mechanizations a `type: script` row delegates to. The runner is largely new code.

**Why partial:** D-15 says P8 retroactively sweeps P1–P7 and **folds the existing 18 check-*.sh scripts into YAML manifests as `type: script` mechanizations**. That is a one-time data migration; the runner itself is small (read YAML → for each item, dispatch by `mechanization.type` → exit code aggregation).

**`type: script` row delegate** — running `scripts/check-bus-protocol-version.sh`:

```swift
// In ChecklistRunner:
case .script(let relativePath):
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repoRoot.appendingPathComponent(relativePath).path]
    process.environment = ProcessInfo.processInfo.environment
    try process.run()
    process.waitUntilExit()
    return ItemResult(passed: process.terminationStatus == 0, exitCode: process.terminationStatus)
```

**`type: grep_negative` / `grep_positive`** — D-17 mandates `expected_count` is REQUIRED:

```swift
case .grepNegative(let file, let pattern, let expectedCount):
    let matches = try countMatches(file: file, pattern: pattern)
    return ItemResult(passed: matches == expectedCount, ...)
// Missing expected_count → YAML decoder REJECTS the manifest (catches "regex
// no longer matches anything → silent green" failure mode per RESEARCH §Security).
```

**Mechanization types (D-16 closed set):** `swift_test`, `script`, `grep_negative`, `grep_positive`, `plist_check`, `codesign_grep`, `MANUAL:`. Hand-rolled `Codable` with exhaustive switches, no `default` branch (CLAUDE.md "Established Patterns" — adding a new type forces compile-time hits on every consumer).

---

### 2.12 `packages/Harness/Sources/jarvis-eval/main.swift`

**Analog:** None in-tree — first executable target in the project. Seed pattern is RESEARCH §Code Examples (lines 466-505).

**Pattern (from RESEARCH §Code Examples, validated against swift-argument-parser docs):**

```swift
import ArgumentParser
import Harness

@main
struct JarvisEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jarvis-eval",
        abstract: "Phase 8 evaluation harness — replay oracle + 8-pillar matrix.",
        subcommands: [
            Replay.self,
            CorpusInjection.self,
            CorpusSSE.self,
            CorpusNDJSON.self,
            CapRecovery.self,
            WakeCorpus.self,
            McpCrash.self,
            AudioRebuild.self,
            Checklist.self,
            All.self,
        ]
    )
}

struct All: AsyncParsableCommand {
    @Flag(name: .long, help: "Skip live-mode pillars (Anthropic / Ollama).")
    var skipLive: Bool = false

    @Flag(name: .long, help: "Include live-mode pillars. Requires JARVIS_LIVE_EVAL=1.")
    var live: Bool = false

    func run() async throws {
        // D-04: live requires both flag AND env var (defense vs accidental burn)
        if live {
            guard ProcessInfo.processInfo.environment["JARVIS_LIVE_EVAL"] == "1" else {
                throw ValidationError("--live requires JARVIS_LIVE_EVAL=1 in environment.")
            }
        }
        // ... run all subcommands in order, aggregate reports ...
    }
}
```

**Risk (none in-tree):** The `@main` + `AsyncParsableCommand` shape is standard Apple-blessed — verify by `swift package show-dependencies` shows swift-argument-parser 1.5+ resolves cleanly before authoring action sections.

---

### 2.13 `scripts/shipping-gate.sh`

**Analog:** `/Users/james.maes/Git.Local/Kof22/Jarvis/scripts/check-bus-protocol-version.sh`
(Sets `set -euo pipefail`, supports env-var indirection so a smoke-test harness can fault-inject, prints `FAIL: <reason>` to stderr on failure.)

**Pattern excerpt** (check-bus-protocol-version.sh lines 1-30):

```bash
#!/usr/bin/env bash
#
# shipping-gate.sh — Phase 8 OBS-04 shipping gate.
#
# Invokes `jarvis-eval all` over the harness's eight pillars + replay oracle.
# Default mode is fixture-only (no Anthropic egress, no live Ollama daemon required).
# Pass `--live` to include the live-Anthropic + live-Ollama pillars; requires
# `JARVIS_LIVE_EVAL=1` in environment per D-04.
#
# Usage:
#   scripts/shipping-gate.sh                    # fixture-only (default)
#   JARVIS_LIVE_EVAL=1 scripts/shipping-gate.sh --live   # full matrix incl. live
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# Build jarvis-eval if it isn't built (don't assume CI prebuilt).
cd "$REPO/packages/Harness"
swift build --product jarvis-eval --configuration release

# Run the matrix.
LIVE_FLAG=""
[[ "${1:-}" == "--live" ]] && LIVE_FLAG="--live"
.build/release/jarvis-eval all $LIVE_FLAG
```

---

### 2.14 `.planning/phases/{01..07}-*/checklist.yaml` (sweep — D-15)

**Analog (manifest shape):** RESEARCH §"Looks done but isn't" checklist manifest shape (lines 583-615) is the only seed. The 18 existing `scripts/check-*.sh` scripts are the per-item mechanization seeds.

**Pattern excerpt** (RESEARCH lines 583-614):

```yaml
# .planning/phases/01-foundations/checklist.yaml
phase: 01-foundations
items:
  - id: P1-01
    description: "LSUIElement=YES keeps app out of Dock"
    mechanization:
      type: plist_check
      file: build/Build/Products/Release/Jarvis.app/Contents/Info.plist
      key: LSUIElement
      expected: true
  - id: P1-02
    description: "com.apple.developer.speech-recognition-assets entitlement present in signed archive"
    mechanization:
      type: codesign_grep
      identity: "Developer ID Application"
      pattern: "com.apple.developer.speech-recognition-assets"
      expected_count: 1
  - id: P1-03
    description: "Input Monitoring TCC denial surfaces HUD banner, not silent no-op (R4-S2)"
    mechanization:
      type: swift_test
      suite: ShellTests
      test: test_inputMonitoringDenialSurfacesBanner
  - id: P1-04
    description: "com.apple.security.cs.allow-unsigned-executable-memory is NOT in entitlements (forbidden)"
    mechanization:
      type: grep_negative
      file: App/Jarvis.entitlements
      pattern: "allow-unsigned-executable-memory"
      expected_count: 0
```

**Sweep recipe (per phase):**
1. Read `.planning/phases/<NN>-<slug>/<NN>-XX-SUMMARY.md` for every plan's items.
2. Bucket each item by mechanization type:
   - **Existing `scripts/check-*.sh` script?** → `type: script, path: scripts/check-X.sh`
   - **Existing XCTest / swift-testing test method?** → `type: swift_test, suite: …, test: …`
   - **Entitlement / Info.plist invariant?** → `type: plist_check` or `type: codesign_grep`
   - **Architecturally forbidden pattern?** → `type: grep_negative, expected_count: 0`
   - **Manual hardware/UAT step?** → `MANUAL: <description>` (always visible, never blocks ship per D-16)
3. **D-17 enforcement:** every grep-style row MUST carry `expected_count` or `expected_value`. ChecklistRunner's YAML decoder rejects manifests where it's missing.

**Existing 18 check-*.sh scripts that fold directly into manifests:**

| Script | Likely Phase | YAML row |
|--------|--------------|----------|
| `check-bus-protocol-version.sh` | 02-bus | `type: script, path: scripts/check-bus-protocol-version.sh` |
| `check-bus-harness-parity.sh` | 02-bus | `type: script, path: scripts/check-bus-harness-parity.sh` |
| `check-no-evaluate-javascript.sh` | 02-bus / 03-hud | `type: script` |
| `check-no-modal-presentation.sh` | 05-mcp | `type: script` |
| `check-single-writer-hudstate.sh` | 03-hud | `type: script` |
| `check-presence-vision-isolation.sh` | 07-memory-vision | `type: script` |
| `check-presence-bus-no-tts-orchestrator.sh` | 07-memory-vision | `type: script` |
| `check-single-memory-mutated-emit.sh` | 07-memory-vision | `type: script` |
| `check-single-memory-used-emit.sh` | 07-memory-vision | `type: script` |
| `check-embedding-dim-literal.sh` | 07-memory-vision | `type: script` |
| `check-vision-isolation.sh` | 07-memory-vision | `type: script` |
| `check-app-builds.sh` | (cross-phase) | `type: script` (P8 manifest or per-phase smoke) |
| `verify-entitlements.sh` | 01-foundations | `type: script` (with `--post-codesign` arg captured in `args:` field) |
| `verify-codesign-settings.sh` | 01-foundations | `type: script` |
| `probe-speech-assets.sh` | 06-voice | `type: script` |
| `fetch-openwakeword-models.sh` / `fetch-silero-models.sh` | 06-voice | NOT checklist — these are setup, not invariant assertions |
| `smoke-test-hud.sh` | 03-hud | `type: script` |
| `test-check-*.sh` / `test-verify-*.sh` | (test-of-the-checks) | NOT checklist — they're the meta-tests of the check scripts |

---

## §3. Shared Patterns (apply across multiple files)

### S-1. Hand-rolled `Codable` with exhaustive switches, no `default` branch
**Source:** `packages/Replay/Sources/Replay/ReplayEvent.swift` (`encoded()` switch, lines 82-125)
**Apply to:** `InjectionAttempt.Vector`, `InjectionAttempt.Category`, `InjectionAttempt.ExpectedOutcome`, `DriftCategory`, `MechanizationType`, `MCPDispatcherSelection` (or whichever shape the TurnSource extension lands).
**Why:** Adding a new case forces a compile-time hit on every consumer — the architectural-invariant guard. CLAUDE.md "Established Patterns" calls this out explicitly.

### S-2. `ChildSpawnGate.shared.prepare()` BEFORE every `Process.run()`
**Source:** `packages/MCP/Sources/MCP/MCPServerHandle.swift` lines 86-103
**Apply to:** `FDLeakDetector` (lsof spawn), `MCPCrashRunner` (helper spawn — already covered by `MCPClient.register`), any future Process spawn from harness code.
**Code:**
```swift
try await ChildSpawnGate.shared.prepare()
let process = Process()
process.executableURL = ...
process.environment = ChildSpawnGate.minimalEnvironment  // PATH=/usr/bin:/bin only
try process.run()
```
**Caveat:** lsof spawn is short-lived enough that `minimalEnvironment` may suffice; the gate's main purpose is FD_CLOEXEC sweep, which DOES apply to lsof.

### S-3. Fixture loading via `Bundle.module.url(forResource:)`
**Source:** `packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift` lines 33-37
**Apply to:** Every `Corpora/*` consumer in Harness (SSEFixtureRunner, NDJSONFixtureRunner, InjectionCorpusRunner, WakeHysteresisRunner, ReplayRunner).
**Caveat:** `Bundle.module` works for both library AND test targets; in the executable target (`jarvis-eval/main.swift`), use `Bundle(for: <some Harness type>)` instead — executable targets don't synthesize `Bundle.module` the same way. Verify at first compile.

### S-4. swift-testing `@Suite("...", .serialized)` with `@Test(arguments: ...)` parameterization
**Source:** `packages/Voice/Tests/VoiceTests/TeardownTests.swift` lines 16-22
**Apply to:** All new HarnessTests + corpus-driven runners (parameterized over `InjectionCorpus.all`, `SSEFixtureCorpus.all`, etc.)
**D-03 lock:** swift-testing for new P8 suites; XCTest for any test that must share fixtures with an earlier-phase XCTest (rare — `Bundle.module` works in both).

### S-5. `actor` for shared mutable state; `nonisolated let events: BoundedAsyncChannel<...>` for outbound
**Source:** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` lines 29-77
**Apply to:** Every Runner (ReplayRunner, InjectionCorpusRunner, MCPCrashRunner, WakeHysteresisRunner). Each is a long-lived owner of in-flight test state with an outbound report channel.

### S-6. URL-based env-var indirection in scripts (test-harness fault injection)
**Source:** `scripts/check-bus-protocol-version.sh` lines 23-29
**Apply to:** `shipping-gate.sh`, `capture-anthropic-sse.sh`, `promote-replay-session.sh` — every new script supports `: "${VAR:=default}"` so a smoke-test harness can substitute paths/values.

### S-7. Live-mode dual-gating (D-04 — flag AND env var)
**Source:** New pattern (no in-tree analog yet — first time we have an opt-in egress).
**Apply to:** `jarvis-eval all --live`, `jarvis-eval corpus-sse --live`, `jarvis-eval corpus-ndjson --live`.
**Code:**
```swift
if live {
    guard ProcessInfo.processInfo.environment["JARVIS_LIVE_EVAL"] == "1" else {
        throw ValidationError("--live requires JARVIS_LIVE_EVAL=1 in environment (defense vs CI / autonomous-loop accidental Anthropic burn).")
    }
}
```

---

## §4. No-Analog / Highest-Risk Scaffolds

These five surfaces have no close in-tree match and need extra design care
during plan authoring:

### 4.1 `TurnSource` enum extension (Modified file in §1b)
**Risk:** HIGH. The current enum is `String, RawRepresentable, CaseIterable` with associated-value-free cases. Adding `case replay(sessionId: SessionID)` / `case eval(scenarioId: String)` BREAKS the `String` rawValue + `CaseIterable` synthesis + the `turns.source` SQLite column writer in `ReplayLog.swift` line 85.
**Recommendation:** Strategy A in §2.2 (companion `SuppressionPolicy` struct, keep TurnSource as String-rawValue + add `.replay` / `.eval` cases as distinct cohort tags). Avoids associated-value churn while preserving R4-L7 suppression semantics. Planner picks A or B (associated values) — must explicitly declare in `08-01-PLAN.md`.

### 4.2 `AVAudioEngine` synthetic device-change injection (RESEARCH A6)
**Risk:** MEDIUM. RESEARCH explicitly flags this as unconfirmed: "if no injection API, the 4-trigger matrix degrades to 3 triggers with device-change being manual."
**Recommendation:** Plan `08-03` Wave 1 task: probe `AVAudioSession.routeChangeNotification` posting capability + `AVAudioEngine.notify(...)` private API availability with a 30-minute spike. If unavailable, file device-change as `MANUAL:` in `phase=06-voice/checklist.yaml` with explicit operator instructions per D-14. The other 3 triggers (AEC fallback / mic re-grant / sustained ring overflow) stay automated — Voice/TeardownTests already drives them.

### 4.3 `lsof -F ftn` parsing portability (RESEARCH A2)
**Risk:** LOW-MEDIUM. lsof is BSD-stable; edge cases (FIFOs, anonymous sockets, non-printable bytes in path) need empirical probing.
**Recommendation:** `parseLsofTerse(data:)` MUST defend (not crash) against non-UTF-8 path bytes; record-separator is `\n` per FD plus blank-line block boundary. Write `FDLeakDetectorTests.swift` with 5+ fixture lsof outputs (happy path + each edge) before declaring the parser done.

### 4.4 Golden replay corpus committing (D-08 / D-09 / D-11)
**Risk:** MEDIUM (operator-discipline-dependent). RESEARCH §Common Pitfalls #1 (line 391): "Replay bit-rot after refactors. A refactor changes a deterministic field's format. Every recorded session's replay now fails the oracle, blocking shipping gate for reasons unrelated to regressions."
**Recommendation:** D-11 schema-version handshake is the load-bearing defense. `ReplayLog` writers (in P4) MUST emit `replaySchemaVersion` in the log header; `ReplayOracle` rejects older-version logs with a clear "re-record after refactor X" error rather than failing per session. P8 plan `08-01` adds the version check to ReplayRunner; any `replaySchemaVersion` bump in P4-P7 forces a re-record of `Corpora/replay-golden/`. The 5–10 hand-selected sessions live under `packages/Harness/Corpora/replay-golden/` plus a sidecar `meta.json` per session capturing `temperature`, `model`, `replaySchemaVersion` so DriftClassifier knows whether `nondeterministicUnderSampling` exclusions apply (per D-20).

### 4.5 `jarvis-eval` CLI (`main.swift`)
**Risk:** LOW. First executable target in the project, but swift-argument-parser is well-trodden.
**Recommendation:** Plan `08-01` Wave 1 task: scaffold the Package.swift `executableTarget` + a stub `JarvisEval` with one trivial subcommand (`jarvis-eval --help`) and verify `swift run jarvis-eval --help` works before authoring the eight real subcommands across `08-02` through `08-04`. This catches `Bundle.module`-in-executable-target gotchas (S-3 caveat) and SPM-resolves swift-argument-parser early.

---

## §5. Cross-Cutting Concerns (apply to ALL plans)

### 5.1 Read-only constraint
P8 must NOT modify `AgentOrchestrator`, MCPClient, VoiceController, MemoryStore, ReplayLog WRITER, DevOverlay, webview/HUD code. The single permitted seam is `TurnSource` + (per Strategy A) a new `SuppressionPolicy` struct + new `.replay` / `.eval` rawValues. Verify with `git diff --stat` at the end of each plan.

### 5.2 Live-mode discipline (D-04 / D-05 / D-06 / D-07)
- Default `scripts/shipping-gate.sh` runs every pillar fixture-only.
- `--live` requires `JARVIS_LIVE_EVAL=1` env var.
- Live Ollama preflights with `curl http://127.0.0.1:11434/api/tags`; fails LOUD if model missing. NEVER auto-pulls.
- Live Anthropic key sourcing: existing P1 `SystemKeychainStore`. Pre-commit hook greps `packages/Harness/Corpora/` for `sk-ant-`, `AKIA`, `ghp_`, `sk-` patterns and fails on hit.

### 5.3 Mechanization-type closed set (D-16)
Hand-rolled `Codable` enum with exhaustive switch + no `default` (S-1). Adding a new mechanization type must be a deliberate enum extension.

### 5.4 Visible degradation (D-14, D-17)
No silent skips. Any pillar that downgrades (e.g., audio-rebuild device-change → MANUAL, live-Ollama skipped) MUST emit a visible row in shipping-gate output (`SKIPPED — run with --live to include`). MANUAL items always print in CI output as warning rows.

### 5.5 Schema-version handshake (D-11)
Every replay-golden session SQLite carries a `replaySchemaVersion` row. ReplayOracle rejects older versions with `"re-record after refactor X"` instead of failing the gate.

---

## §6. Metadata

**Analog search scope:** `packages/{AgentCore,Replay,MCP,Voice,Memory,DevOverlay,Bus,Logging,Config,Keychain,Shell,Vision}/`, `App/`, `scripts/`.
**Files scanned:** ~80 source/test files + 18 check-*.sh scripts + 1 project.yml + 9 SSE fixtures + 6 NDJSON fixtures.
**Strongest cross-cutting analog packages:** `Memory` (multi-dep Package.swift, background actor driving orchestrator), `MCP` (Process spawn + FD discipline + crash-loop test), `Voice` (swift-testing 4-trigger matrix), `AnthropicProvider` (fixture-replay decode pattern).
**Highest-leverage existing assets to reuse:**
1. `MCPRestartTests.swift` 100-cycle crash loop → MCPCrashRunner
2. `TeardownTests.swift` 4-trigger matrix → AudioGraphRebuildRunner
3. `WakeWordHysteresisTests.swift` scripted-prob feeder → WakeHysteresisRunner
4. `FixtureReplayTests.swift` SSE-to-LLMEvent decoder → MockLLMProvider
5. `MemoryOrchestrator.swift` background-turn-driver → all Runners
6. 18 `scripts/check-*.sh` → checklist YAML `type: script` rows

**Pattern extraction date:** 2026-04-30
