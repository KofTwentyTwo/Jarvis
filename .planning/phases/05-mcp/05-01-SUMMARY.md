---
phase: 05-mcp
plan: 01
subsystem: mcp
tags: [mcp, swift-sdk, stdio-transport, child-spawn-gate, restart-mutex, fd-cloexec]
requirements-completed: [MCP-01, MCP-07, MCP-08]
dependency-graph:
  requires: []
  provides:
    - JarvisMCP.MCPClient
    - JarvisMCP.MCPServerHandle
    - JarvisMCP.ChildSpawnGate
    - JarvisMCP.JarvisMCPError
    - JarvisMCP.ToolMetadata
    - JarvisMCP.MCPLogChannel
  affects: []
tech-stack:
  added:
    - "modelcontextprotocol/swift-sdk @ exact 0.12.0"
    - "swift-system (transitive via swift-sdk; provides FileDescriptor)"
    - "swift-nio (transitive via swift-sdk)"
  patterns:
    - "Per-server restart mutex via Task<Void, Error>? slot on MCPServerHandle"
    - "ChildSpawnGate singleton with FD_CLOEXEC sweep + minimal env constant"
    - "FD_CLOEXEC at FD-creation time on parent-side Pipe ends"
key-files:
  created:
    - packages/MCP/Package.swift
    - packages/MCP/Sources/MCP/ChildSpawnGate.swift
    - packages/MCP/Sources/MCP/MCPClient.swift
    - packages/MCP/Sources/MCP/MCPError.swift
    - packages/MCP/Sources/MCP/MCPLogChannel.swift
    - packages/MCP/Sources/MCP/MCPServerHandle.swift
    - packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift
    - packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Package.swift
    - packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Sources/MockHelper/main.swift
    - packages/MCP/Tests/MCPTests/MCPClientHappyPathTests.swift
    - packages/MCP/Tests/MCPTests/MCPClientVersionTests.swift
    - packages/MCP/Tests/MCPTests/MCPRestartTests.swift
    - packages/MCP/Tests/MCPTests/MCPServerHandleStartTests.swift
    - packages/MCP/Tests/MCPTests/MockHelperBuilder.swift
  modified: []
decisions:
  - "Renamed library/target/module to JarvisMCP to avoid the SDK's MCP product name collision; mirrors the JarvisLogging convention."
  - "Renamed our error type to JarvisMCPError to disambiguate from the SDK's MCP.MCPError."
  - "Per-server restart mutex via MCPServerHandle.claimOrShareRestart: atomic claim-or-share runs entirely under the handle actor's isolation."
  - "ChildSpawnGate is the FD_CLOEXEC sweep + minimal-env contract holder; Process() is constructed by MCPServerHandle.start. Plan contract is 'every spawn routes through ChildSpawnGate.shared.prepare', satisfied by 3 grep matches."
  - "PID pin in process.terminationHandler: pinned PID at handler-wire time so a stale handler from a prior helper cannot flip isCrashed on the LIVE restarted process."
  - "FD_CLOEXEC retrofit at FD-creation time on the three parent-side Pipe ends in MCPServerHandle.start, immediately after Process.run."
  - "100-cycle FD-leak threshold: ±16. Empirical delta=0 against baseline=4."
metrics:
  duration: ~75min
  completed: 2026-04-25
  task-count: 3
  file-count: 14
  test-count: 16
  loc: 1447
---

# Phase 5 Plan 01: MCP Client + Stdio Transport — Summary

JarvisMCP package landed with the official modelcontextprotocol/swift-sdk v0.12.0 wired through a per-server MCPServerHandle actor and a ChildSpawnGate singleton enforcing FD_CLOEXEC + minimal environment on every spawn. Per-server restart mutex passes 8-way contention; the headline 100-cycle FD-leak stress test reports delta=0 against a baseline of 4 open FDs.

## Public surface (consumed by 05-02..05-05)

```swift
import JarvisMCP

public actor MCPClient {
    public init(logger: Logger = MCPLogChannel.logger(label: "client"))
    public func register(name: String, binaryURL: URL, requiresConfirmation: Bool) async throws
    public func register(name: String, binaryURL: URL, requiresConfirmation: Bool, extraEnvironment: [String: String]) async throws
    public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result
    public func toolMetadata(_ name: String) -> ToolMetadata?
    public func registeredServerNames() -> [String]
    public func registeredToolNames() -> [String]
    public func shutdown() async
}

public actor MCPServerHandle {
    public nonisolated let name: String
    public nonisolated let binaryURL: URL
    public nonisolated let requiresConfirmation: Bool
    public func start() async throws
    public func shutdown() async
    public func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
    public func listTools() async throws -> (tools: [Tool], nextCursor: String?)
    public func setRestartTask(_ task: Task<Void, Error>?)
    public func claimOrShareRestart(_ buildTask: () -> Task<Void, Error>) -> (claimed: Bool, task: Task<Void, Error>?)
    public private(set) var restartTask: Task<Void, Error>?
    public private(set) var isCrashed: Bool
}

public actor ChildSpawnGate {
    public static let shared: ChildSpawnGate
    public static let minimalEnvironment: [String: String]   // ["PATH": "/usr/bin:/bin"]
    public func prepare() throws
}

public enum JarvisMCPError: Error, Sendable, Equatable, LocalizedError {
    case helperMissing(name: String)
    case helperMissingToolsCapability(name: String)
    case startupTimeout(name: String, seconds: Int)
    case serverCrashed(name: String)
    case spawnFailed(name: String, underlying: String)
}

public struct ToolMetadata: Sendable, Equatable {
    public let name: String
    public let server: String
    public let requiresConfirmation: Bool
}

public enum MCPLogChannel {
    public static func logger(label: String) -> Logger
}
```

## Verification results

| Gate                                          | Expected | Actual         |
| --------------------------------------------- | -------- | -------------- |
| swift build (debug)                           | exit 0   | OK             |
| swift build -c release                        | exit 0   | OK (29.0s)     |
| swift test (full)                             | 0 fail   | 16 / 16 pass   |
| 100-cycle FD-leak (baseline -> final, <=16)   | <=16     | delta=0 (4->4) |
| AgentCore regression                          | 134/134  | 134 / 134      |
| Replay regression                             | 27/27    | 27 / 27        |
| Bus regression                                | 47/47    | 47 / 47        |
| grep `exact: "0.12.0"` in Package.swift       | 1        | 1              |
| grep `"PATH": "/usr/bin:/bin"` in gate        | 1        | 1              |
| grep `static let shared` in gate              | 1        | 1              |
| grep `StdioTransport(input:` in handle        | >=1      | 2              |
| grep `ChildSpawnGate.shared.prepare` in handle| >=1      | 3              |
| grep `ProcessInfo.processInfo.environment`    | 0        | 0              |
| grep `--deep` in Sources                      | 0        | 0              |

## Test inventory

```
JarvisMCPPackageTests (16 tests, ~32s total)

ChildSpawnGateTests (3)
- test_minimalEnvironment_isPathOnly
- test_prepare_succeedsOnHappyPath
- test_spawnedChild_seesPathOnlyEnv

MCPClientVersionTests (2)
- test_resolvedSwiftSDKIsExactly_0_12_0
- test_swiftToolsVersionAtLeast_6_1_runtimeCheck

MCPClientHappyPathTests (4)
- test_register_and_callTool_returnsEchoedText
- test_register_failsWith_spawnFailed_whenBinaryAbsent
- test_callTool_unregisteredName_throws_helperMissing
- test_toolMetadata_returnsServerName_andRequiresConfirmation

MCPServerHandleStartTests (3) — source-level Pitfall #1 regression
- test_StdioTransport_constructedWithExplicitFDs_notDefaults
- test_ChildSpawnGate_called_before_processRun
- test_minimalEnvironment_isSetOnProcess

MCPRestartTests (4)
- test_singleCrash_followedBy_callTool_succeedsAfterRestart
- test_concurrentCallsDuringRestart_shareOneRestart      (8-way contention; tally side-channel verifies exactly 2 starts)
- test_inFlightCallTool_duringCrash_throws_serverCrashed (mock_slow SIGKILL'd mid-flight)
- test_100_crashCycles_noFDLeak                          (baseline=4, final=4, delta=0)
```

## Deviations from Plan

### Auto-fixed (Rule 3 — blocking compile issues)

**D1. [Rule 3] Renamed library/target/module to JarvisMCP.**
- Found during: Task 1, before first `swift build` resolution.
- Issue: SDK at modelcontextprotocol/swift-sdk v0.12.0 already declares a public library product named `MCP`. Two products named `MCP` in the same dep graph and two modules named `MCP` at import sites is uncompilable.
- Fix: package + library + target + module renamed to `JarvisMCP`; SPM `path: "Sources/MCP"` keeps the file layout the plan's files_modified block specifies. Test target renamed to `JarvisMCPTests`. Mirrors the JarvisLogging convention from packages/Logging/Package.swift.
- Impact for downstream plans (05-02..05-05): change `import MCP` to `import JarvisMCP` for our facade. SDK types (`Value`, `Tool.Content`, `CallTool.Result`, `Initialize.Result`) still require `import MCP`.

**D2. [Rule 3] Renamed our error type to JarvisMCPError.**
- Found during: Task 1, alongside D1.
- Issue: SDK ships a public MCPError enum (in Sources/MCP/Base/Error.swift); our same-named type at module scope would force `JarvisMCP.MCPError` qualifications throughout our own source files (which import the SDK's MCP).
- Fix: type renamed to `JarvisMCPError` with the same case set the plan's interfaces block specified. LocalizedError conformance retained.
- Impact: plan 05-04's translation layer keys off JarvisMCPError instead of MCPError.

### Auto-fixed (Rule 1 — bugs found during tests)

**D3. [Rule 1] PID-pin terminationHandler.**
- Found during: Task 3, restart-mutex test debugging.
- Issue: process.terminationHandler from a PRE-restart helper would fire late and call handleTermination on the actor — flipping isCrashed=true on the LIVE restarted process.
- Fix: capture pinnedPID = process.processIdentifier at handler-wire time; handleTermination(forPID:) early-returns when self.process.processIdentifier != pid.

**D4. [Rule 1] FD_CLOEXEC retrofit on parent-side Pipe ends.**
- Found during: Task 3, full-suite run after individual tests passed.
- Issue: Foundation's Pipe creates FDs without O_CLOEXEC. The first ChildSpawnGate sweep (Debug build) ran clean. After our FIRST Process.run, the parent-side pipe ends we kept (stdoutRead, stdinWrite, stderrRead) were not CLOEXEC. The gate's NEXT sweep (the second spawn cycle) found them and fatalErrored on FD 7. Caught only when running the full suite (test 1's Pipes lingered into test 2's gate sweep).
- Fix: added MCPServerHandle.setCloexec(_) static helper; called on the three parent-retained pipe FDs immediately after process.run. Aligns with RESEARCH Pitfall #8: O_CLOEXEC at FD-creation time is the primary defense; the gate's sweep is belt-and-braces.
- Effect on FD-leak test: baseline=4 final=4 delta=0 across 100 cycles.

### Test-fixture deviation

**D5. [Rule 1] Concurrent-restart test crashes via SIGKILL, not MOCK_HELPER_CRASH_AFTER.**
- Found during: Task 3, while investigating a 0/8 success rate.
- Issue: My initial test used MOCK_HELPER_CRASH_AFTER=1 to crash the helper. But extraEnvironment carries through to the RESTARTED helper — so the restarted helper also exited after one call, and the 8 concurrent callers (after the restart) only got one success before the second-restart crash cascade.
- Fix: removed MOCK_HELPER_CRASH_AFTER from the concurrent test; force-crashed the initial helper via kill(pid, SIGKILL) directly. The restarted helper has no crash trigger and survives 8 concurrent calls cleanly. Tally side-channel still verifies the two-start contract (initial + 1 restart) holds.

## Known stubs / future work

- Real MCP servers don't exist yet. Plan 05-02 brings up mcp-time + mcp-clipboard helpers; Plan 05-03 brings up mcp-applescript. Spawn-side tests in this plan use MockHelper (echo + sleep) under Tests/MCPTests/Fixtures/. Downstream plans must NOT depend on the fixture — it's deliberately scoped to the test target.
- No backoff / retry on failed restart. RESEARCH Assumption A5: per-server restart mutex is 1-bounded; failed restart propagates and the helper is permanently degraded until next app restart. A future hardening plan (Phase 8) can layer N-bounded backoff if data shows we need it.
- No SSE/HTTP transports wired. Plan 05-01 is stdio-only by design. SDK includes HTTPClientTransport and StatefulHTTPServerTransport but those land later (or never — personal-use scope).
- No DevOverlay surfacing yet. MCPLogChannel.logger(label: "client.<name>") and stderr.<name> log lines hit Swift Logging's stderr default; Phase 8 wires structured-log capture into the existing dev overlay pipeline.

## Phase 5 Wave 2 readiness

Plan 05-02 (helpers: mcp-time + mcp-clipboard) is unblocked. Concrete consumption pattern:

```swift
let client = MCPClient(logger: MCPLogChannel.logger(label: "client"))
try await client.register(
    name: "mcp-time",
    binaryURL: helperBundleURL("mcp-time"),
    requiresConfirmation: false
)
let result = try await client.callTool(name: "get_time", arguments: [:])
```

Plan 05-03 (mcp-applescript) is unblocked, but: it must `requiresConfirmation: true` and Plan 05-04/05-05 wire that flag into the confirmation broker before the helper actually runs an AppleScript.

Plan 05-04 (sanitize pipeline + ToolDispatcher) is unblocked — it wraps MCPClient.callTool in a ToolDispatcher-conforming type, applies the sanitize-then-truncate-then-wrap pipeline (Pattern 4 in 05-RESEARCH), and translates JarvisMCPError cases into the dispatcher error surface.

Plan 05-05 (confirmation broker presenter wiring) is unblocked — ToolMetadata.requiresConfirmation is the input gate.

## Self-Check: PASSED

- packages/MCP/Package.swift — FOUND
- packages/MCP/Sources/MCP/ChildSpawnGate.swift — FOUND
- packages/MCP/Sources/MCP/MCPClient.swift — FOUND
- packages/MCP/Sources/MCP/MCPError.swift — FOUND
- packages/MCP/Sources/MCP/MCPLogChannel.swift — FOUND
- packages/MCP/Sources/MCP/MCPServerHandle.swift — FOUND
- packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift — FOUND
- packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Package.swift — FOUND
- packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Sources/MockHelper/main.swift — FOUND
- packages/MCP/Tests/MCPTests/MCPClientHappyPathTests.swift — FOUND
- packages/MCP/Tests/MCPTests/MCPClientVersionTests.swift — FOUND
- packages/MCP/Tests/MCPTests/MCPRestartTests.swift — FOUND
- packages/MCP/Tests/MCPTests/MCPServerHandleStartTests.swift — FOUND
- packages/MCP/Tests/MCPTests/MockHelperBuilder.swift — FOUND
- Commit 896d7fb (Task 1) — FOUND
- Commit 8dbd6f0 (Task 2) — FOUND
- Commit 5fee406 (Task 3) — FOUND
