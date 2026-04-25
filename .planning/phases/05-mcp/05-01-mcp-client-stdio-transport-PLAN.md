---
phase: 05-mcp
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - packages/MCP/Package.swift
  - packages/MCP/Sources/MCP/MCPClient.swift
  - packages/MCP/Sources/MCP/MCPServerHandle.swift
  - packages/MCP/Sources/MCP/ChildSpawnGate.swift
  - packages/MCP/Sources/MCP/MCPError.swift
  - packages/MCP/Sources/MCP/MCPLogChannel.swift
  - packages/MCP/Tests/MCPTests/MCPClientVersionTests.swift
  - packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift
  - packages/MCP/Tests/MCPTests/MCPRestartTests.swift
  - packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Package.swift
  - packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Sources/MockHelper/main.swift
autonomous: true
requirements: [MCP-01, MCP-07, MCP-08]
tags: [mcp, swift-sdk, stdio-transport, child-spawn-gate, restart-mutex, fd-cloexec]
assumptions:
  - Swift toolchain on the build host is >= 6.1 (RESEARCH Pitfall #2). Wave 1 Task 1 verifies via `swift --version` before SPM resolution.
  - `Foundation.Process` + `Pipe` + `FileDescriptor(rawValue:)` is the parent-side spawn recipe (RESEARCH Pattern 1; SF-0037 Subprocess is pre-1.0 through April 2026).
  - `getdtablesize()` returns ~256 on macOS by default; the FD sweep is cheap on the happy path (RESEARCH Assumption A2).
  - `Process.terminationHandler` fires on every exit path including SIGKILL (RESEARCH Assumption A3).
  - The MockHelper subprocess used by restart tests builds via `swift build` from its Fixtures path at test setup, before the 100-cycle FD-leak loop runs.
  - Anti-pattern callouts: DO NOT hand-roll NDJSON JSON-RPC framing (CLAUDE.md + SUMMARY supersede §7 of source-material). DO NOT inherit parent env into child (RESEARCH Anti-Pattern). DO NOT eagerly restart on EOF — restart is LAZY on next callTool (RESEARCH Anti-Pattern).
must_haves:
  truths:
    - "An `MCPClient` actor can spawn a fixture helper subprocess, complete the SDK initialize handshake, and return tool-call results without manual JSON-RPC framing in our tree."
    - "When the spawned helper crashes (SIGKILL), every in-flight `callTool` rejects with `MCPError.serverCrashed` rather than hanging forever."
    - "After a crash, the next `callTool` lazily restarts the helper; concurrent callers during one restart share the single restart task (per-server mutex holds)."
    - "100 sequential crash-and-restart cycles complete with the parent's open-FD count returning to within ±16 of the baseline measured before the loop."
    - "Every `Process().run()` in the MCP package routes through `ChildSpawnGate.shared.prepare(...)`; a non-CLOEXEC FD discovered during a Debug build's prepare() is a fatalError, not a silent retrofit."
    - "Spawned children see exactly `PATH=/usr/bin:/bin` and no other environment keys (no `HOME`, no `USER`, no `PWD`, no `ANTHROPIC_API_KEY` inheritance)."
    - "`Package.resolved` pins `modelcontextprotocol/swift-sdk` at exactly version `0.12.0` (no upper-bound float, no major-version range)."
  artifacts:
    - path: "packages/MCP/Package.swift"
      provides: "MCP SPM package; pins swift-sdk @ exact 0.12.0; library product `MCP` + test target `MCPTests`."
      contains: ".package(url: \"https://github.com/modelcontextprotocol/swift-sdk\", exact: \"0.12.0\")"
    - path: "packages/MCP/Sources/MCP/MCPClient.swift"
      provides: "Public `MCPClient` actor with `register(name:binaryURL:requiresConfirmation:)`, `callTool(name:arguments:)`, `shutdown()`, and the per-server restart mutex (Pattern 2)."
      min_lines: 100
    - path: "packages/MCP/Sources/MCP/MCPServerHandle.swift"
      provides: "Per-server actor wrapping `Process` + `Pipe` + SDK `Client` + `Task<Void, Error>?` restartTask slot."
      min_lines: 80
    - path: "packages/MCP/Sources/MCP/ChildSpawnGate.swift"
      provides: "Single `actor ChildSpawnGate` with `static let shared` enforcing FD_CLOEXEC sweep + minimal env construction (Pattern 3)."
      min_lines: 40
    - path: "packages/MCP/Sources/MCP/MCPError.swift"
      provides: "Error enum: `.helperMissing`, `.helperMissingToolsCapability`, `.startupTimeout`, `.serverCrashed`, `.spawnFailed(underlying:)`."
    - path: "packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Sources/MockHelper/main.swift"
      provides: "Standalone executable that uses the SDK `Server` + `StdioTransport` to expose a single `mock_echo` tool; reads `MOCK_HELPER_CRASH_AFTER` env to optionally raise SIGKILL after N calls (test-only)."
  key_links:
    - from: "packages/MCP/Sources/MCP/MCPServerHandle.swift"
      to: "modelcontextprotocol/swift-sdk Client + StdioTransport"
      via: "FileDescriptor(rawValue: childStdoutPipe.fileHandleForReading.fileDescriptor)"
      pattern: "StdioTransport\\(input:.*output:.*logger:"
    - from: "packages/MCP/Sources/MCP/MCPClient.swift"
      to: "MCPServerHandle.restartTask slot"
      via: "shared restart task awaited by concurrent callers"
      pattern: "restartTask"
    - from: "packages/MCP/Sources/MCP/MCPServerHandle.swift"
      to: "ChildSpawnGate.shared"
      via: "try await ChildSpawnGate.shared.prepare() BEFORE process.run()"
      pattern: "ChildSpawnGate\\.shared"
---

<objective>
Stand up the MCP package and its three foundational primitives so every later Phase 5 plan can register, call, and recover helpers without hand-rolling protocol bytes:

1. **MCP-01**: Vendor `modelcontextprotocol/swift-sdk` at exactly `0.12.0` and resolve it cleanly under our existing `swift-tools-version` 6.0 SPM tree (RESEARCH Pitfall #2 says SDK requires 6.1 toolchain to *parse* its Package.swift — verify host toolchain).
2. **MCP-07**: Implement the per-server restart mutex on top of `Foundation.Process` + `StdioTransport`. On helper EOF the SDK `Client.disconnect()` drains its pending map; we wrap that into `MCPError.serverCrashed` at our boundary. Restart is lazy on the next `callTool`; concurrent callers share one in-flight restart Task.
3. **MCP-08**: Funnel every `Process().run()` through a single `ChildSpawnGate.shared` choke point that (a) sweeps parent-held FDs and enforces `FD_CLOEXEC` and (b) constructs the minimal `["PATH": "/usr/bin:/bin"]` environment so no parent secrets, paths, or shell fingerprints inherit into the child.

Purpose: this plan is plumbing — no helper bundles ship here, no orchestrator wiring, no sanitize pipeline. It exists so 05-02 (helpers) and 05-04/05-05 (dispatcher + broker) have a stable, tested protocol+spawn layer to call into. Phase 4 left `ToolDispatcher` as a stub protocol; this plan builds the infrastructure 05-04 will wrap into the concrete dispatcher.

Output: a new SPM package at `packages/MCP/` with three source files, an error enum, a log channel, an XCTest target, and a fixture MockHelper subprocess used by the 100-cycle FD-leak test.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/05-mcp/05-RESEARCH.md
@.planning/research/RESEARCH-DELTAS.md
@.planning/phases/04-agent-core/04-04-SUMMARY.md
@.planning/phases/04-agent-core/04-05-SUMMARY.md
@.planning/phases/01-foundations/01-05-SUMMARY.md
@CLAUDE.md
@packages/AgentCore/Package.swift
@packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift
@packages/AgentCore/Sources/AgentCore/LLMEvent.swift

<interfaces>
<!--
  Contracts the executor needs. These are LITERAL signatures — do not improvise variants.
  Downstream plans (05-02, 05-03, 05-04, 05-05) consume these names.
-->

From `modelcontextprotocol/swift-sdk` v0.12.0 (verified against repo source @ 0.12.0):

```swift
// Pinned import name
import MCP
import System  // FileDescriptor

// Client side
public actor Client {
    public init(name: String, version: String, configuration: Configuration = .default)
    public func connect(transport: any Transport) async throws -> Initialize.Result
    public func disconnect() async
    public func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
    public func listTools() async throws -> ListTools.Result
}

// Stdio transport — IMPORTANT: default no-arg init is for SERVER (helper) side; reads stdin/stdout
// Parent-side MUST construct with explicit child-pipe FileDescriptors:
public final class StdioTransport: Transport {
    public init(input: FileDescriptor, output: FileDescriptor, logger: Logger? = nil)
    public init(logger: Logger? = nil)  // helper-side default
}

// Tool result content
public struct CallTool {
    public struct Result: Sendable {
        public let content: [Tool.Content]
        public let isError: Bool
    }
}
public enum Tool {
    public enum Content: Sendable {
        case text(text: String, annotations: Annotations?, _meta: Meta?)
        case image(data: String, mimeType: String, annotations: Annotations?, _meta: Meta?)
        // additional cases exist; we only consume `.text` in v1
    }
}
```

Public surface this plan provides (consumed by 05-02..05-05):

```swift
// packages/MCP/Sources/MCP/MCPError.swift
public enum MCPError: Error, Sendable, Equatable {
    case helperMissing(name: String)
    case helperMissingToolsCapability(name: String)
    case startupTimeout(name: String, seconds: Int)
    case serverCrashed(name: String)
    case spawnFailed(name: String, underlying: String)
}

// packages/MCP/Sources/MCP/ChildSpawnGate.swift
public actor ChildSpawnGate {
    public static let shared: ChildSpawnGate
    public func prepare() throws  // sweeps FDs, throws on prepare failure
    public static let minimalEnvironment: [String: String]  // ["PATH": "/usr/bin:/bin"]
}

// packages/MCP/Sources/MCP/MCPClient.swift
public actor MCPClient {
    public init(logger: Logger)
    public func register(name: String, binaryURL: URL, requiresConfirmation: Bool) async throws
    public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result
    public func toolMetadata(_ name: String) async -> ToolMetadata?
    public func shutdown() async
}

public struct ToolMetadata: Sendable, Equatable {
    public let name: String
    public let server: String
    public let requiresConfirmation: Bool
}
```

From AgentCore (already exists — DO NOT modify in this plan):

```swift
// packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift
public protocol ToolDispatcher: Sendable {
    func dispatch(toolUse: ToolUseRequest) async throws -> Data
    func requiresConfirmation(toolName: String) -> Bool
}
```

This plan does NOT make `MCPClient` conform to `ToolDispatcher`. Plan 05-04 wraps MCPClient into the conforming type with the sanitize pipeline.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: SPM package scaffold + SDK pin + version test + ChildSpawnGate primitive</name>
  <files>
    packages/MCP/Package.swift,
    packages/MCP/Sources/MCP/MCPError.swift,
    packages/MCP/Sources/MCP/MCPLogChannel.swift,
    packages/MCP/Sources/MCP/ChildSpawnGate.swift,
    packages/MCP/Tests/MCPTests/MCPClientVersionTests.swift,
    packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift
  </files>
  <behavior>
    - Test (RED first): `MCPClientVersionTests.test_resolvedSwiftSDKIsExactly_0_12_0` asserts `Package.resolved` (or the workspace state file) contains the SDK pin at version `0.12.0`. Reads from `${SRCROOT}/../../packages/MCP/Package.resolved` if available; falls back to grepping `Package.swift` for the literal `exact: "0.12.0"` substring (whichever is reachable from the test process).
    - Test: `MCPClientVersionTests.test_swiftToolsVersionAtLeast_6_1` asserts `swift --version` output's first line contains a numeric version >= 6.1. (Pitfall #2 — SDK requires 6.1 to parse its Package.swift even though we compile our targets at SWIFT_VERSION 6.0.)
    - Test: `ChildSpawnGateTests.test_minimalEnvironment_isPathOnly` asserts `ChildSpawnGate.minimalEnvironment == ["PATH": "/usr/bin:/bin"]` exactly (count == 1, no other keys).
    - Test: `ChildSpawnGateTests.test_prepare_succeedsOnHappyPath` calls `await ChildSpawnGate.shared.prepare()` and asserts no throw. (We can't easily induce a non-CLOEXEC FD inside the test process portably; the negative path is exercised by the 100-cycle restart test in Task 3 indirectly.)
    - Test: `ChildSpawnGateTests.test_spawnedChild_seesPathOnlyEnv` — uses `Process()` to launch `/usr/bin/env` with `environment = ChildSpawnGate.minimalEnvironment`; reads stdout; asserts the captured output is exactly `PATH=/usr/bin:/bin\n` (single line, no `HOME=`, no `USER=`, no `TERM=`).
  </behavior>
  <action>
    1. Create `packages/MCP/Package.swift` with:
       - `// swift-tools-version:6.0` (matches our other packages — Pitfall #2: 6.1 is for *parsing* the SDK's manifest, not for us)
       - `platforms: [.macOS(.v13)]`
       - dependencies:
         - `.package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0")` (per ASSUMPTION pin from RESEARCH Standard Stack — exact, NOT range)
         - `.package(path: "../Logging")` for `JarvisLogging`
       - library product `MCP` exposing target `MCP`
       - target `MCP` with `swiftSettings: [.swiftLanguageMode(.v6)]` (per D-04 strict concurrency)
       - testTarget `MCPTests` depending on `MCP`
       - **Do NOT** depend on AgentOrchestrator (Plan 05-04 wires that direction).

    2. Create `packages/MCP/Sources/MCP/MCPError.swift` exactly as in `<interfaces>`. Conform to `Error`, `Sendable`, `Equatable`, and `LocalizedError` (the `errorDescription` strings are read by the orchestrator translation in 05-04 — keep them human-readable, no leaked nonces).

    3. Create `packages/MCP/Sources/MCP/MCPLogChannel.swift` with a single public computed `Logger` factory:
       ```swift
       public enum MCPLogChannel {
           public static func logger(label: String) -> Logger {
               Logger(label: "jarvis.mcp.\(label)")
           }
       }
       ```
       Used by `MCPClient`, `ChildSpawnGate`, and (later) `MCPServerHandle`. Ensure import is `import Logging` from `JarvisLogging` product per Phase 1 patterns.

    4. Create `packages/MCP/Sources/MCP/ChildSpawnGate.swift` per RESEARCH Pattern 3:
       ```swift
       import Darwin
       import Foundation
       import struct Logging.Logger

       public actor ChildSpawnGate {
           public static let shared = ChildSpawnGate()
           public static let minimalEnvironment: [String: String] = ["PATH": "/usr/bin:/bin"]

           private let logger = MCPLogChannel.logger(label: "spawngate")

           private init() {}

           public func prepare() throws {
               let fdMax = getdtablesize()
               for fd in 3..<fdMax {
                   let flags = fcntl(fd, F_GETFD)
                   guard flags >= 0 else { continue }  // closed FD
                   if (flags & FD_CLOEXEC) == 0 {
                       #if DEBUG
                       fatalError("FD \(fd) is not FD_CLOEXEC; origin must be instrumented")
                       #else
                       _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                       logger.warning("FD \(fd) was not FD_CLOEXEC; retrofitted")
                       #endif
                   }
               }
           }
       }
       ```
       Key constraints:
       - `static let shared` — ALL spawns route through this single instance.
       - `prepare()` is async via the actor isolation, so callers must `try await ChildSpawnGate.shared.prepare()`.
       - The Debug `fatalError` is intentional — RESEARCH Pitfall #8 says retrofitting at sweep-time is belt-and-braces; the primary defense is `O_CLOEXEC` at FD-creation time. Debug fatalErrors surface where the retrofit is needed; Release retrofits silently with a warning so production stays alive.

    5. Create the test files described in `<behavior>`. The env-inspection test uses `Process()` directly (not `ChildSpawnGate.shared.prepare()` — Task 3 covers the gate's enforcement when wired with `MCPServerHandle`).

    Anti-pattern callouts to enforce:
    - DO NOT add a fallback range like `from: "0.12.0"` — the spec says exact, the SDK is pre-1.0 and might break compatibility on minor bumps.
    - DO NOT inherit `ProcessInfo.processInfo.environment` anywhere in this package — that leaks `ANTHROPIC_API_KEY`, `HOME`, `PWD`, etc.
  </action>
  <verify>
    <automated>cd packages/MCP && swift build 2>&1 | tee /tmp/mcp-build.log | grep -E "Build complete|error:" &amp;&amp; cd packages/MCP && swift test --filter MCPClientVersionTests 2>&amp;1 | tail -20 &amp;&amp; cd packages/MCP &amp;&amp; swift test --filter ChildSpawnGateTests 2>&amp;1 | tail -20 &amp;&amp; grep -c 'exact: "0.12.0"' packages/MCP/Package.swift</automated>
  </verify>
  <done>
    - `swift build --package-path packages/MCP` exits 0 (resolves `swift-sdk` 0.12.0 + Logging).
    - All five tests in `MCPClientVersionTests` and `ChildSpawnGateTests` pass.
    - `grep -c 'exact: "0.12.0"' packages/MCP/Package.swift` returns 1.
    - `grep -c 'static let shared' packages/MCP/Sources/MCP/ChildSpawnGate.swift` returns 1.
    - `grep -c '"PATH": "/usr/bin:/bin"' packages/MCP/Sources/MCP/ChildSpawnGate.swift` returns 1.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: MCPServerHandle spawn-and-wire + MCPClient register/callTool happy path</name>
  <files>
    packages/MCP/Sources/MCP/MCPServerHandle.swift,
    packages/MCP/Sources/MCP/MCPClient.swift,
    packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Package.swift,
    packages/MCP/Tests/MCPTests/Fixtures/MockHelper/Sources/MockHelper/main.swift
  </files>
  <behavior>
    - The MockHelper fixture exposes a single tool `mock_echo` taking `{"text": String}` and returning `.text(text: <input.text>)`. Used as the helper subprocess for ALL spawn-side tests in this plan.
    - Test (RED first): `MCPClientHappyPathTests.test_register_and_callTool_returnsEchoedText` registers MockHelper, calls `mock_echo` with `["text": "hello-mcp-01"]`, asserts the result content is exactly that string (one `.text` content, `isError == false`).
    - Test: `MCPClientHappyPathTests.test_register_failsWith_helperMissing_whenBinaryAbsent` — points `binaryURL` at a non-existent path, asserts the throw is `MCPError.spawnFailed` (not `.helperMissing` — `.helperMissing` is for the `callTool` path on an unregistered name; spawn failure is its own case).
    - Test: `MCPClientHappyPathTests.test_callTool_unregisteredName_throws_helperMissing` — calls a name not in the registry; asserts `MCPError.helperMissing`.
    - Test: `MCPServerHandleStartTests.test_StdioTransport_constructedWithExplicitFDs_notDefaults` — Pitfall #1 regression. Inspect `MCPServerHandle.start()` source to assert `StdioTransport(input:output:logger:)` is called with explicit `FileDescriptor(rawValue:)` arguments derived from pipe FDs (NOT the no-arg `StdioTransport()`). Implementation: grep the source file for `StdioTransport(input:` to confirm.
  </behavior>
  <action>
    1. Create the MockHelper fixture executable at `packages/MCP/Tests/MCPTests/Fixtures/MockHelper/`:
       - `Package.swift` (swift-tools-version:6.0) declaring an executable target `MockHelper` depending on `modelcontextprotocol/swift-sdk` exact 0.12.0 + `Logging`.
       - `Sources/MockHelper/main.swift`:
         ```swift
         import MCP
         import Foundation

         @main
         struct MockHelper {
             static func main() async throws {
                 // Optional crash-after-N-calls (used by Task 3 restart test).
                 var callCount = 0
                 let crashAfter: Int? = ProcessInfo.processInfo.environment["MOCK_HELPER_CRASH_AFTER"].flatMap(Int.init)

                 let server = Server(
                     name: "mock-helper",
                     version: "1.0.0",
                     capabilities: .init(tools: .init(listChanged: false))
                 )

                 await server.withMethodHandler(ListTools.self) { _ in
                     .init(tools: [
                         Tool(
                             name: "mock_echo",
                             description: "Echo input text.",
                             inputSchema: .object([
                                 "type": .string("object"),
                                 "properties": .object(["text": .object(["type": .string("string")])]),
                                 "required": .array([.string("text")])
                             ])
                         )
                     ])
                 }

                 await server.withMethodHandler(CallTool.self) { params in
                     callCount += 1
                     if let n = crashAfter, callCount > n {
                         // Force-crash: matches the SIGKILL-from-parent path used by restart tests.
                         exit(137)
                     }
                     guard params.name == "mock_echo",
                           let text = params.arguments?["text"]?.stringValue else {
                         return .init(content: [.text(text: "bad args", annotations: nil, _meta: nil)], isError: true)
                     }
                     return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
                 }

                 // Helpers MUST log to stderr only (Pitfall #4). Default Logger is fine; main app logs land on stderr.
                 let transport = StdioTransport(logger: Logger(label: "mock-helper"))
                 try await server.start(transport: transport)
                 await server.waitUntilCompleted()
             }
         }
         ```
       The fixture build is done at test setUp time (XCTestCase setUp class func) via `swift build -c release --package-path Fixtures/MockHelper`; resolved binary path is `Fixtures/MockHelper/.build/release/MockHelper`.

    2. Create `packages/MCP/Sources/MCP/MCPServerHandle.swift` per RESEARCH Pattern 1:
       - actor with: `name: String`, `binaryURL: URL`, `requiresConfirmation: Bool`, mutable `process: Process?`, `client: Client`, `stdinPipe: Pipe?`, `stdoutPipe: Pipe?`, `stderrPipe: Pipe?`, `restartTask: Task<Void, Error>?`, `isCrashed: Bool`.
       - `init(name:binaryURL:requiresConfirmation:)` stores the basics; sets up SDK `Client(name: "Jarvis", version: "1.0.0")`.
       - `start() async throws`:
         1. `try await ChildSpawnGate.shared.prepare()` (mandatory).
         2. Construct fresh `Process()`, `Pipe()` × 3.
         3. Set `process.executableURL = binaryURL`, `process.standardInput`, `.standardOutput`, `.standardError`.
         4. `process.environment = ChildSpawnGate.minimalEnvironment` (per MCP-08).
         5. Try `process.run()`; on throw, wrap in `MCPError.spawnFailed`.
         6. Build `StdioTransport(input: FileDescriptor(rawValue: stdoutPipe!.fileHandleForReading.fileDescriptor), output: FileDescriptor(rawValue: stdinPipe!.fileHandleForWriting.fileDescriptor), logger: MCPLogChannel.logger(label: "client.\(name)"))` — IMPORTANT: the input is the parent's READ end of the child's STDOUT (it's where bytes from child arrive); output is the parent's WRITE end of the child's STDIN.
         7. `let initResult = try await client.connect(transport: transport)`.
         8. Verify `initResult.capabilities.tools != nil`; throw `.helperMissingToolsCapability` if absent.
         9. Set `process.terminationHandler = { [weak self] _ in Task { await self?.handleTermination() } }`.
         10. Spawn a stderr-pump Task: read from `stderrPipe.fileHandleForReading.readabilityHandler` and forward each line to `MCPLogChannel.logger(label: "stderr.\(name)").info("\(line)")`. Pitfall #4: helper stdout is RPC; helper stderr is log freight.
         11. Set `isCrashed = false`.
       - `handleTermination() async`:
         1. `await client.disconnect()` (SDK drains its pending map with `.internalError("Client disconnected")`).
         2. `isCrashed = true`.
       - `setRestartTask(_ task: Task<Void, Error>?) async` — slot setter for the mutex.
       - `callTool(name:arguments:)` proxies through the SDK client; if the SDK throws, translate to `MCPError.serverCrashed` ONLY if `isCrashed == true`; otherwise rethrow.
       - `shutdown() async`:
         1. Close parent write-end of stdin (Pitfall #5 — sends EOF, helper exits naturally via SDK's read loop).
         2. Wait up to 2s for `process.terminationStatus`; if still alive, `kill(process.processIdentifier, SIGKILL)`.

    3. Create `packages/MCP/Sources/MCP/MCPClient.swift`:
       - `actor MCPClient` with `private var registry: [String: MCPServerHandle] = [:]` keyed by **server name** (e.g., `"mcp-time"`), and `private var toolToServer: [String: String] = [:]` keyed by **tool name** mapping to its owning server.
       - `init(logger: Logger)` stores the logger.
       - `register(name:binaryURL:requiresConfirmation:)`:
         1. Construct `MCPServerHandle(name:..., binaryURL:..., requiresConfirmation:...)`.
         2. `try await handle.start()`.
         3. Call `let listed = try await handle.client.listTools()`; for each tool in `listed.tools`, set `toolToServer[tool.name] = name`.
         4. `registry[name] = handle`.
       - `callTool(name:arguments:)`:
         1. Look up `serverName = toolToServer[name]`; if missing, throw `.helperMissing(name: name)`.
         2. Look up `handle = registry[serverName]`; if missing, throw `.helperMissing(name: name)`.
         3. (Restart-mutex logic added in Task 3 — for now, just `try await handle.callTool(name: name, arguments: arguments)`.)
       - `toolMetadata(_ name:) -> ToolMetadata?` returns `(name, server, requiresConfirmation)`.
       - `shutdown() async`: iterate registry, call `handle.shutdown()` on each.

    4. Add the `ToolMetadata` struct in `MCPClient.swift` (or a new `ToolRegistry.swift` if cleaner — Plan 05-04 expands this).

    Anti-patterns:
    - DO NOT use `StdioTransport()` no-arg init in MCPServerHandle (Pitfall #1: that's the helper-side default; we'd hang on the parent's own stdin/stdout). Always pass explicit `FileDescriptor(rawValue:)` args.
    - DO NOT log to stdout in the MockHelper or any future helper (Pitfall #4 corrupts the JSON-RPC stream). All helper logs go to stderr.
    - DO NOT eagerly restart on EOF — `handleTermination` only marks state. Restart is triggered lazily by the next `callTool` (Task 3).
  </action>
  <verify>
    <automated>cd packages/MCP/Tests/MCPTests/Fixtures/MockHelper &amp;&amp; swift build -c release 2>&amp;1 | tail -5 &amp;&amp; cd ../../../../.. &amp;&amp; swift test --package-path packages/MCP --filter MCPClientHappyPathTests 2>&amp;1 | tail -30 &amp;&amp; grep -c 'StdioTransport(input:' packages/MCP/Sources/MCP/MCPServerHandle.swift &amp;&amp; grep -c 'ChildSpawnGate.shared.prepare' packages/MCP/Sources/MCP/MCPServerHandle.swift</automated>
  </verify>
  <done>
    - MockHelper fixture builds cleanly.
    - All four happy-path tests pass; an `mcp_echo` round-trip returns the literal input string.
    - `grep -c 'StdioTransport(input:' MCPServerHandle.swift` returns >= 1 (Pitfall #1 regression guard).
    - `grep -c 'ChildSpawnGate.shared.prepare' MCPServerHandle.swift` returns >= 1.
    - `grep -c 'process.environment = ChildSpawnGate.minimalEnvironment' MCPServerHandle.swift` returns 1.
    - `grep -c '\\-\\-deep' packages/MCP/Sources/MCP/*.swift` returns 0 (anti-pattern guard, not a codesign concern but cheap regression).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Per-server restart mutex + 100-cycle FD-leak crash-injection test</name>
  <files>
    packages/MCP/Sources/MCP/MCPClient.swift,
    packages/MCP/Sources/MCP/MCPServerHandle.swift,
    packages/MCP/Tests/MCPTests/MCPRestartTests.swift
  </files>
  <behavior>
    - Test (RED first): `MCPRestartTests.test_singleCrash_followedBy_callTool_succeedsAfterRestart` — register MockHelper with `MOCK_HELPER_CRASH_AFTER=1`. Call `mock_echo` once (succeeds). Wait for crash propagation (handle goes into `isCrashed = true`). Call again — assert it succeeds (lazy restart kicks in).
    - Test: `MCPRestartTests.test_concurrentCallsDuringRestart_shareOneRestart` — pre-crash the helper, then issue 8 concurrent `callTool` invocations via `withTaskGroup`. Assert: all 8 succeed AND the helper's `Process` was launched exactly twice across the test (initial + ONE restart). Verified by counting `MOCK_HELPER_RESTART_COUNT` writes to a temp file the MockHelper appends to at startup (env-controlled side channel).
    - Test: `MCPRestartTests.test_inFlightCallTool_duringCrash_throws_serverCrashed` — start a `mock_echo` call that's deliberately slow (MockHelper handles a `mock_slow` tool that sleeps 2s; add this tool to MockHelper). Mid-sleep, `process.terminate()` from outside. Assert the awaiting caller receives `MCPError.serverCrashed` (NOT a hang, NOT a different error).
    - Test (the headline): `MCPRestartTests.test_100_crashCycles_noFDLeak` — record `lsof -p $(getpid)` open FD count baseline. Loop 100 times: `register` → call `mock_echo` once → SIGKILL → next callTool triggers restart → call succeeds → record FD count delta. Assert `final_fds - baseline_fds <= 16` (per RESEARCH Validation row "no FD leaks across 100 restart cycles").
  </behavior>
  <action>
    1. Extend `MCPServerHandle`:
       - Add `mock_slow` handler in MockHelper main.swift (1.5s `Task.sleep`, then echo). This is a fixture-only addition.
       - In `MCPServerHandle.callTool`, ensure that when the SDK client throws AND `isCrashed == true`, the wrapped error is `MCPError.serverCrashed(name: self.name)`. Pre-crash exceptions pass through.

    2. Implement the per-server restart mutex in `MCPClient.callTool` per RESEARCH Pattern 2:
       ```swift
       public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
           guard let serverName = toolToServer[name] else { throw MCPError.helperMissing(name: name) }
           guard let handle = registry[serverName] else { throw MCPError.helperMissing(name: name) }

           // 1. If a restart is in flight for this handle, wait for it.
           if let task = await handle.restartTask {
               try await task.value
           }

           // 2. If crashed and no restart in flight, start ONE.
           if await handle.isCrashed, await handle.restartTask == nil {
               let task = Task<Void, Error> { try await handle.start() }
               await handle.setRestartTask(task)
               do {
                   try await task.value
                   await handle.setRestartTask(nil)
               } catch {
                   await handle.setRestartTask(nil)
                   throw error
               }
           }

           // 3. Dispatch.
           return try await handle.callTool(name: name, arguments: arguments)
       }
       ```
       Critical: the `setRestartTask(nil)` MUST happen on both success and failure paths so a future call after a failed restart can attempt again.

    3. The 100-cycle test:
       - Before the loop: `let baseline = countOpenFDs()` where `countOpenFDs()` reads `/dev/fd/` via `FileManager.default.contentsOfDirectory(atPath: "/dev/fd")`.count (POSIX-portable on macOS).
       - In each iteration:
         - Register a fresh `MCPClient` with the MockHelper.
         - Call `mock_echo`.
         - Reach into the handle (test-only `internal` accessor — add `internal func _testProcessIdentifier() -> Int32` on `MCPServerHandle` behind `#if DEBUG`) and `kill(pid, SIGKILL)`.
         - Call again — should succeed via restart.
         - `await client.shutdown()`.
       - After the loop: `let final = countOpenFDs()`. Assert `final - baseline <= 16`. (16 chosen per RESEARCH validation row "±16" tolerance for transient FDs from XCTest infrastructure.)
       - Run as `XCTestCase` not `async`-only — the FD count read MUST happen on the test thread, not inside a Task that might be on a different thread queue with its own FD reservations.

    Anti-patterns / gotchas:
    - DO NOT spin-wait on `isCrashed` — use the SDK's natural error propagation. If the SDK's `Client.disconnect()` correctly drains the pending map (RESEARCH cites Client.swift verbatim), in-flight callers will receive their cancellation organically.
    - DO NOT make `isCrashed` a `@Published` or KVO-style observable — actor isolation handles it. Plain `var isCrashed: Bool` on the actor is correct.
    - DO NOT remove the `setRestartTask(nil)` in the catch branch — without it, a failed restart strands the handle forever in "restart in flight" state.
    - DO NOT add backoff/retry inside `MCPClient.callTool`. RESEARCH Assumption A5: the per-server restart mutex is 1-bounded; if restart itself fails, the error propagates and the helper is permanently degraded until next app restart. Backoff belongs in a future hardening plan, not here.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter MCPRestartTests 2>&amp;1 | tail -40 &amp;&amp; swift test --package-path packages/MCP 2>&amp;1 | tail -10</automated>
  </verify>
  <done>
    - All four restart tests pass, including the 100-cycle FD-leak test landing within ±16 of baseline.
    - `grep -c 'restartTask' packages/MCP/Sources/MCP/MCPClient.swift` returns >= 3 (await + setRestart + setNil).
    - `grep -c 'MCPError.serverCrashed' packages/MCP/Sources/MCP/MCPServerHandle.swift` returns >= 1.
    - `swift build --package-path packages/MCP` exits 0.
    - Full MCP test suite green: `swift test --package-path packages/MCP` reports 0 failures.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Parent process → helper child | Untrusted helper output crosses the stdio JSON-RPC boundary. Helper itself is locally-built code, not network-sourced — but its output may be coerced via tool results from web fetches, files, or pasteboard contents that the model interpolates into a future tool argument. |
| Parent process → spawned environment | The child inherits exactly what we hand it. Anything we leak in env or open FDs becomes the helper's attack surface. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-01-01 | Information Disclosure | `MCPServerHandle.start()` parent env | mitigate | Hard-set `process.environment = ChildSpawnGate.minimalEnvironment` (only `PATH=/usr/bin:/bin`). Test `ChildSpawnGateTests.test_spawnedChild_seesPathOnlyEnv` asserts the child sees no `HOME`, `USER`, `ANTHROPIC_API_KEY`, etc. |
| T-05-01-02 | Information Disclosure | Parent FDs (Replay SQLite WAL, log files) | mitigate | `ChildSpawnGate.shared.prepare()` sweeps FDs and either fatalErrors (Debug) or retrofits `FD_CLOEXEC` (Release) BEFORE `process.run()`. The 100-cycle test confirms no FD leak across crash-restart loops, exercising the steady-state path. |
| T-05-01-03 | Denial of Service | Helper hangs in-flight callers after crash | mitigate | SDK `Client.disconnect()` drains its own pending-request map with `.internalError("Client disconnected")` on EOF; we wrap into `MCPError.serverCrashed` at our boundary. Per-server restart mutex prevents infinite respawn under a flapping helper — failed restart marks degraded and propagates. |
| T-05-01-04 | Denial of Service | Concurrent callers race to restart | mitigate | Per-server `restartTask: Task<Void, Error>?` slot; concurrent callers `await task.value`; only one restart runs. Test `test_concurrentCallsDuringRestart_shareOneRestart` exercises 8-way contention. |
| T-05-01-05 | Tampering | SDK version drift to a malicious tag | accept | We pin `exact: "0.12.0"` (not a range). A future SDK bump is a manual decision, not a `swift package update` accident. Personal-use threat model — no supply-chain attacker scenario. |
| T-05-01-06 | Tampering | StdioTransport default-init silent hang | mitigate | Pitfall #1 regression test greps `MCPServerHandle.swift` for `StdioTransport(input:` (explicit FDs); zero matches fails the test. Defends against a future contributor "simplifying" the helper-side default into the parent path. |
| T-05-01-07 | Repudiation | Helper crashes silently | mitigate | `process.terminationHandler` ALWAYS routes through `handleTermination`; `MCPLogChannel.logger(label: "stderr.\(name)").info(...)` records every stderr line. The 05-04 plan extends this with replay-log integration. |
</threat_model>

<verification>
Phase-level checks for this plan (run before merging into wave-2 plans):

1. `swift build --package-path packages/MCP` exits 0; `Package.resolved` lists `swift-sdk` at `0.12.0` exactly.
2. Full `swift test --package-path packages/MCP` reports 0 failures across `MCPClientVersionTests`, `ChildSpawnGateTests`, `MCPClientHappyPathTests`, `MCPServerHandleStartTests`, `MCPRestartTests`.
3. The 100-cycle FD-leak test lands within ±16 FDs.
4. Grep gates pass:
   - `grep -c 'StdioTransport(input:' packages/MCP/Sources/MCP/MCPServerHandle.swift` >= 1
   - `grep -c '"PATH": "/usr/bin:/bin"' packages/MCP/Sources/MCP/ChildSpawnGate.swift` == 1
   - `grep -c 'static let shared' packages/MCP/Sources/MCP/ChildSpawnGate.swift` == 1
   - `grep -c 'exact: "0.12.0"' packages/MCP/Package.swift` == 1
   - `grep -c 'ProcessInfo.processInfo.environment' packages/MCP/Sources/MCP/*.swift` == 0 (no parent-env inheritance)
   - `grep -rn '\\-\\-deep' packages/MCP/Sources/MCP/*.swift` returns 0 matches.
</verification>

<success_criteria>
- The MCP package compiles, all tests pass, and the SPM dep graph stays acyclic (`MCP` depends only on `swift-sdk` + `Logging`, not on AgentCore/AgentOrchestrator/Replay).
- A consumer (Plan 05-02 helpers, Plan 05-04 dispatcher) can `import MCP` and call `MCPClient.register(...)` + `callTool(...)` against a live helper subprocess with no JSON-RPC code in our tree.
- A helper crash is recoverable: 100 SIGKILL cycles complete with no FD leak and no stranded continuations.
- The host-side environment hardening is enforced at a single choke point (`ChildSpawnGate.shared`) and provable by a grep gate (no `ProcessInfo.processInfo.environment` reads inside `Sources/MCP/`).
</success_criteria>

<output>
After completion, write `.planning/phases/05-mcp/05-01-SUMMARY.md` per the standard template. Highlights to include:
- SPM dependency added: `modelcontextprotocol/swift-sdk @ exact 0.12.0`.
- Public types provided to downstream plans: `MCPClient`, `MCPServerHandle`, `ChildSpawnGate`, `MCPError`, `ToolMetadata`, `MCPLogChannel`.
- The MockHelper fixture is internal-only (under `Tests/MCPTests/Fixtures/`); 05-02..05-05 should NOT depend on it.
- 100-cycle FD-leak test result: record the actual baseline → final delta for future regressions.
- Any deviations encountered (per Rule 1/2/3) — especially around `StdioTransport` FD plumbing or `Process.terminationHandler` semantics.
</output>
