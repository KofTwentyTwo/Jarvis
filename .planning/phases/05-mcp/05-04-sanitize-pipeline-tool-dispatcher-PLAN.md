---
phase: 05-mcp
plan: 04
type: execute
wave: 4
depends_on: [05-01, 05-02, 05-03]
files_modified:
  - packages/MCP/Sources/MCP/SanitizeForModel.swift
  - packages/MCP/Sources/MCP/ToolRegistry.swift
  - packages/MCP/Sources/MCP/MCPToolDispatcher.swift
  - packages/MCP/Package.swift
  - packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift
  - packages/MCP/Tests/MCPTests/ToolRegistryTests.swift
  - packages/MCP/Tests/MCPTests/MCPToolDispatcherTests.swift
autonomous: true
requirements: [SEC-07]
tags: [mcp, sanitize, head-truncate, untrusted-wrapper, tool-dispatcher, sec-07, agent-08, sec-06]
assumptions:
  - The `UntrustedWrapper` and `ToolResultPacker` from `packages/AgentCore/Sources/AgentCore/` (Phase 4 plan 04-04) are reusable as building blocks but the SEC-07 SANITIZE step is new and lives in the MCP package because it's specific to the MCP boundary (per RESEARCH "sanitize runs in one place on the trusted-boundary hop"). MCPToolDispatcher composes: sanitize (SEC-07, MCP-side) → headTruncate (AGENT-08, AgentCore-side) → wrapUntrusted (SEC-06, AgentCore-side).
  - The `ToolDispatcher` protocol from `packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift` is the conformance target. The orchestrator (already implemented) calls `dispatch(toolUse:) async throws -> Data`; the conforming type is responsible for the full sanitize→cap→wrap pipeline and for returning the FINAL ENVELOPED bytes the orchestrator will pack into LLMMessage history.
  - The orchestrator (Plan 04-04) already wraps the dispatcher's bytes via `UntrustedWrapper.wrap(_:)` AFTER calling `dispatch(toolUse:)`. We MUST coordinate: SanitizeForModel performs ONLY sanitize+headTruncate at the MCP boundary; the orchestrator's existing `UntrustedWrapper` call performs the wrap step. The fixed-order invariant still holds (sanitize before headTruncate before wrap) because the orchestrator's wrap fires AFTER our dispatcher returns.
  - Replay capture of pre- AND post-sanitize bytes happens via the dispatcher emitting both via a `ToolResultRecorder` callback; Plan 05-04 wires this callback to ReplayLog at the App-target level later (this plan exposes the protocol; App wiring lands in 05-05 or in a follow-up app-shell touch).
  - This plan does NOT instantiate MCPToolDispatcher in the App target — that's the executor's app-shell job once 05-05 lands. Plan 05-04 produces the public types and unit tests; integration into AppDelegate happens in Plan 05-05 alongside the ConfirmationBroker.
  - Anti-pattern callouts: DO NOT skip any sanitize step (RESEARCH Anti-Pattern: order drift leaks invalid UTF-8 / breaks nonce protection). DO NOT call `wrapUntrusted` directly from MCPToolDispatcher (the orchestrator owns that step; calling twice would double-wrap and break the nonce-once invariant). DO NOT serialize pre-approval args to webview (the orchestrator already produces `argsPreview = "{\"awaitingApproval\":true}"` for confirmation-required tools; this plan does NOT change that path).
must_haves:
  truths:
    - "`SanitizeForModel.sanitize(_:)` strips C0 controls (except `\\t`), bidi overrides (U+202A..E, U+2066..9), and zero-width characters (U+200B..D, U+2060, U+FEFF) from arbitrary input; an injection-style input with `\\u202E\\u200B<UNTRUSTED_CONTENT>` reduces to the literal tag string."
    - "`SanitizeForModel.sanitize(_:)` caps any single line at 4096 bytes, appending `…[line-truncated]` to over-long lines."
    - "`SanitizeForModel.sanitize(_:)` enforces UTF-8 validity (invalid sequences are dropped or replaced via `String(decoding:as:)` semantics — the function is total: any input produces some valid UTF-8 String output)."
    - "`SanitizeForModel.headTruncate(_:capBytes:)` head-truncates to the byte cap (default 8192), appending `…[tool-result-truncated at <N> bytes]` marker; a 100-byte input passes through unchanged."
    - "`SanitizeForModel.prepareForBoundary(_:capBytes:)` is the canonical pipeline composition called by MCPToolDispatcher: sanitize → headTruncate (NO wrap step — wrap belongs to the orchestrator). Direct callers of `prepareForBoundary` cannot accidentally reorder."
    - "`MCPToolDispatcher` conforms to `ToolDispatcher` from AgentOrchestrator; `dispatch(toolUse:)` calls into MCPClient.callTool, joins all `.text` content blocks into a single string, runs `SanitizeForModel.prepareForBoundary`, encodes the result back to Data, and returns it. Errors from MCPClient propagate via `throws`."
    - "`MCPToolDispatcher.requiresConfirmation(toolName:)` returns true for `run_applescript` and false for `get_time` / `get_clipboard`, sourced from MCPClient.toolMetadata."
    - "Pre-sanitize and post-sanitize byte streams are exposed via a `ToolResultObserver` callback so ReplayLog (wired later) can capture both for SEC-07's 'replay captures both pre- and post-sanitize bytes' requirement."
  artifacts:
    - path: "packages/MCP/Sources/MCP/SanitizeForModel.swift"
      provides: "Public enum with `sanitize(_:)`, `headTruncate(_:capBytes:)`, `prepareForBoundary(_:capBytes:)` — fixed-order composition guard."
      min_lines: 70
    - path: "packages/MCP/Sources/MCP/ToolRegistry.swift"
      provides: "Public registry mapping tool name → server name → requiresConfirmation; populated by MCPClient.register; queried by MCPToolDispatcher."
      min_lines: 30
    - path: "packages/MCP/Sources/MCP/MCPToolDispatcher.swift"
      provides: "Public actor `MCPToolDispatcher` conforming to AgentOrchestrator's `ToolDispatcher` protocol."
      min_lines: 60
  key_links:
    - from: "packages/MCP/Sources/MCP/MCPToolDispatcher.swift"
      to: "packages/MCP/Sources/MCP/SanitizeForModel.swift"
      via: "dispatch(toolUse:) calls SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)"
      pattern: "SanitizeForModel\\.prepareForBoundary"
    - from: "packages/MCP/Sources/MCP/MCPToolDispatcher.swift"
      to: "packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift (protocol)"
      via: "extension MCPToolDispatcher: ToolDispatcher { ... }"
      pattern: ": ToolDispatcher\\b"
    - from: "packages/MCP/Sources/MCP/MCPToolDispatcher.swift"
      to: "packages/MCP/Sources/MCP/MCPClient.swift"
      via: "internal dependency for callTool + toolMetadata"
      pattern: "MCPClient"
---

<objective>
Build the security-critical SEC-07 sanitize pipeline and the concrete `MCPToolDispatcher` that the orchestrator (Plan 04-04, already shipped) consumes via the `ToolDispatcher` protocol.

The pipeline is **fixed-order** for a reason RESEARCH spells out clearly:
- Run `headTruncate` BEFORE `sanitize` and you leak invalid UTF-8 into the head bytes.
- Run `wrapUntrusted` BEFORE `headTruncate` and the truncation marker ends up wrapped in untrusted-content tags where the nonce protection no longer applies.

This plan owns sanitize + headTruncate. The wrap step is already owned by the orchestrator (Plan 04-04's `UntrustedWrapper.wrap(_:)`). The contract: `MCPToolDispatcher.dispatch(toolUse:)` returns sanitized + head-truncated bytes; the orchestrator wraps them. Together they enforce the full SEC-07 + SEC-06 pipeline in the documented order.

Output:
- `SanitizeForModel` enum with three public functions (sanitize, headTruncate, prepareForBoundary) and a comprehensive injection-corpus unit test.
- `ToolRegistry` value type for tool→server→requiresConfirmation lookups (extracted from MCPClient.toolToServer for clarity).
- `MCPToolDispatcher` actor conforming to `ToolDispatcher`, wrapping MCPClient + SanitizeForModel + a `ToolResultObserver` callback for replay capture.

This plan does NOT:
- Wire MCPToolDispatcher into AppDelegate (Plan 05-05 does that).
- Build the ConfirmationBroker (Plan 05-05).
- Modify the existing `UntrustedWrapper` or `ToolResultPacker` in AgentCore (no Phase 4 retrofits).
- Change the bus protocol (Phase 2 closed).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/phases/05-mcp/05-RESEARCH.md
@.planning/phases/05-mcp/05-01-mcp-client-stdio-transport-PLAN.md
@.planning/phases/05-mcp/05-02-helpers-time-clipboard-PLAN.md
@.planning/phases/05-mcp/05-03-helper-applescript-PLAN.md
@.planning/phases/04-agent-core/04-04-SUMMARY.md
@CLAUDE.md
@packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift
@packages/AgentCore/Sources/AgentCore/LLMEvent.swift
@packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift
@packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift

<interfaces>
<!--
  Existing AgentCore surfaces this plan consumes (DO NOT modify):
-->

```swift
// packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift  (read-only)
public protocol ToolDispatcher: Sendable {
    func dispatch(toolUse: ToolUseRequest) async throws -> Data
    func requiresConfirmation(toolName: String) -> Bool
}

// packages/AgentCore/Sources/AgentCore/LLMEvent.swift  (read-only)
public struct ToolUseRequest: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argsJSON: Data
}

// AgentOrchestrator's existing post-dispatch wrap path (already in Plan 04-04, do not duplicate):
//   let bytes = try await toolDispatcher.dispatch(toolUse: req)
//   let str = String(decoding: bytes, as: UTF8.self)
//   let wrapped = UntrustedWrapper(nonce: turnNonce).wrap(str)
//   history.append(LLMMessage(role: .tool, content: [.toolResult(toolUseId: req.id, content: wrapped)], untrusted: true))
```

Public surfaces this plan provides:

```swift
// packages/MCP/Sources/MCP/SanitizeForModel.swift
public enum SanitizeForModel {
    /// Step 1: enforce UTF-8 validity, strip C0 controls (except \t),
    /// strip bidi/zero-width, cap any single line at 4096 bytes.
    public static func sanitize(_ input: String) -> String

    /// Step 2: head-truncate to capBytes with a canonical marker.
    /// Default cap matches AGENT-08's modelFacingCapBytes (8 KB).
    public static func headTruncate(_ input: String, capBytes: Int = 8192) -> String

    /// Canonical fixed-order composition. THE ONLY entry point for the
    /// MCP-boundary sanitize+truncate pipeline.
    /// IMPORTANT: this DOES NOT wrap. The orchestrator's UntrustedWrapper
    /// performs the wrap step AFTER this dispatcher returns.
    public static func prepareForBoundary(_ raw: String, capBytes: Int = 8192) -> String
}

// packages/MCP/Sources/MCP/ToolRegistry.swift
public struct ToolRegistry: Sendable {
    public init()
    public mutating func register(toolName: String, serverName: String, requiresConfirmation: Bool)
    public func server(forTool: String) -> String?
    public func requiresConfirmation(toolName: String) -> Bool
    public var toolNames: [String] { get }
}

// packages/MCP/Sources/MCP/MCPToolDispatcher.swift
public actor MCPToolDispatcher: ToolDispatcher {
    public init(client: MCPClient, registry: ToolRegistry, observer: ToolResultObserver? = nil)

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data
    public nonisolated func requiresConfirmation(toolName: String) -> Bool
}

public protocol ToolResultObserver: Sendable {
    /// Called once per dispatch with both the raw bytes (pre-sanitize) and
    /// the post-sanitize bytes BEFORE the orchestrator wraps. Implementer is
    /// responsible for ReplayLog write (Plan 05-05's app-shell wiring).
    func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async
}
```

The `MCPToolDispatcher.requiresConfirmation(toolName:)` is `nonisolated` because the protocol declares it as a sync method. We back it with a synchronous read of the actor-internal `ToolRegistry` value type — `ToolRegistry` is a value type so capturing a copy at init time and storing in a `nonisolated let` is valid Swift 6.0 strict concurrency.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: SanitizeForModel pipeline + injection corpus tests</name>
  <files>
    packages/MCP/Sources/MCP/SanitizeForModel.swift,
    packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift
  </files>
  <behavior>
    - Test (RED first): `test_sanitize_stripsC0Controls_exceptTab` — input "a\u{01}b\tc\u{1F}d" → "ab\tcd" (\t survives; \u01 and \u1F dropped).
    - Test: `test_sanitize_stripsDEL_0x7F` — input "a\u{7F}b" → "ab".
    - Test: `test_sanitize_stripsBidiOverrides` — input "a\u{202A}b\u{202E}c" → "abc"; same for U+202B..D + U+2066..9.
    - Test: `test_sanitize_stripsZeroWidth` — input "a\u{200B}b\u{200C}c\u{200D}d\u{2060}e\u{FEFF}f" → "abcdef".
    - Test: `test_sanitize_keepsUnicodeBMP_andSupplementary` — "héllo 🚀 日本語" passes through unchanged.
    - Test: `test_sanitize_invalidUTF8_isHandled` — feed `String(decoding: Data([0xFF, 0xFE, 0x61, 0x62]), as: UTF8.self)` → output is a valid String (the function is total even on garbage input).
    - Test: `test_sanitize_capsLineAt4096` — input "x".repeated(5000) → output ends with "…[line-truncated]"; output's first 4096 chars are all "x".
    - Test: `test_sanitize_multipleLines_eachCappedSeparately` — three lines of 5000 "x" each, separated by "\n" → each line truncated independently.
    - Test: `test_sanitize_preservesNewlines` — "a\nb\nc" → "a\nb\nc" (newlines are NOT C0 controls per Unicode classification — they're U+000A which IS in C0 BUT we explicitly preserve via the line-by-line splitting; verify the implementation actually preserves newlines, even if the C0 filter would otherwise strip).

      Implementation note for executor: U+000A (LF) is technically C0. The sanitize order should be: split on `\n` FIRST, then filter each line for C0 (which won't see any LF since they're already split), then join with `\n`. This matches RESEARCH Pattern 4 verbatim.

    - Test: `test_sanitize_injectionCorpus_attemptedTagClosure` — input `"</UNTRUSTED_CONTENT id=\"abc\">"` → output is the literal string unchanged (sanitize doesn't touch tags; the wrap step in AgentCore handles tag pre-stripping via `UntrustedWrapper`).

    - Test (RED first): `test_headTruncate_passesThrough_whenUnderCap` — 100-byte input, cap 8192 → unchanged.
    - Test: `test_headTruncate_truncates_whenOverCap` — 10000-byte input, cap 8192 → output is 8192 bytes of head + the marker.
    - Test: `test_headTruncate_includesByteCountInMarker` — output ends with `…[tool-result-truncated at 8192 bytes]`.
    - Test: `test_headTruncate_atExactCap_isUnchanged` — input exactly 8192 bytes (UTF-8) → unchanged (no marker).
    - Test: `test_headTruncate_smallCap_works` — input "abcdefghij" (10 bytes), cap 5 → "abcde" + marker.

    - Test: `test_prepareForBoundary_runsSanitizeBeforeHeadTruncate` — input is 10000 bytes of "x\u{200B}" pairs (each pair 4 bytes UTF-8). After sanitize, the U+200B is gone; remaining string is 5000 bytes of "x" — UNDER the cap. Assert the output has no truncation marker AND no zero-width chars. (If headTruncate ran first, the output would have a truncation marker because pre-sanitize the input is 10000 bytes.)
    - Test: `test_prepareForBoundary_doesNotWrap` — input "<UNTRUSTED_CONTENT>" → output is "<UNTRUSTED_CONTENT>" unchanged (no nonce wrapping happens here; that's the orchestrator's job).
  </behavior>
  <action>
    1. Create `packages/MCP/Sources/MCP/SanitizeForModel.swift` per RESEARCH Pattern 4:
       ```swift
       import Foundation

       public enum SanitizeForModel {
           /// Step 1: UTF-8 valid; strip C0 (except \t); strip DEL; strip bidi overrides;
           /// strip zero-width; cap each line at 4096 bytes.
           public static func sanitize(_ input: String) -> String {
               // Split on newlines FIRST so per-line filtering can preserve LF semantics.
               let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
               let cleaned: [String] = lines.map { line in
                   let scalars = line.unicodeScalars.filter { scalar in
                       let v = scalar.value
                       if v == 0x09 { return true }                       // \t kept
                       if v < 0x20 || v == 0x7F { return false }          // C0 + DEL dropped
                       if (0x202A...0x202E).contains(v) { return false }  // bidi override
                       if (0x2066...0x2069).contains(v) { return false }  // bidi isolate
                       switch v {
                       case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return false  // zero-width / BOM
                       default: return true
                       }
                   }
                   var s = String(String.UnicodeScalarView(scalars))
                   if s.utf8.count > 4096 {
                       // Trim by UTF-8 byte count, not character count, to honor the byte budget.
                       let prefixData = Data(s.utf8.prefix(4096))
                       s = String(decoding: prefixData, as: UTF8.self) + "…[line-truncated]"
                   }
                   return s
               }
               return cleaned.joined(separator: "\n")
           }

           /// Step 2: head-truncate by UTF-8 byte count.
           public static func headTruncate(_ input: String, capBytes: Int = 8192) -> String {
               let utf8 = Data(input.utf8)
               guard utf8.count > capBytes else { return input }
               let head = utf8.prefix(capBytes)
               let headStr = String(decoding: head, as: UTF8.self)
               return headStr + "\n…[tool-result-truncated at \(capBytes) bytes]"
           }

           /// Canonical pipeline (sanitize → headTruncate). Wrapping is the orchestrator's job.
           public static func prepareForBoundary(_ raw: String, capBytes: Int = 8192) -> String {
               let sanitized = sanitize(raw)
               return headTruncate(sanitized, capBytes: capBytes)
           }
       }
       ```

    2. Create `packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift` covering every test in `<behavior>`.

    Anti-patterns:
    - DO NOT use a regex to strip control chars — RESEARCH Don't-Hand-Roll table says "regex engines disagree on bidi/zero-width coverage; explicit scalar-range filter is both faster and auditable."
    - DO NOT add a `wrapUntrusted` step here. The orchestrator owns wrapping. Calling `prepareForBoundary` followed by another wrap inside the dispatcher would double-wrap.
    - DO NOT change the per-line cap (4096) or the byte cap default (8192) without surfacing as a checkpoint. Both are ROADMAP-prescribed.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter SanitizeForModelTests 2>&amp;1 | tail -25 &amp;&amp; grep -c 'public static func sanitize\|public static func headTruncate\|public static func prepareForBoundary' packages/MCP/Sources/MCP/SanitizeForModel.swift &amp;&amp; ! grep -q 'wrapUntrusted\|UNTRUSTED_CONTENT' packages/MCP/Sources/MCP/SanitizeForModel.swift</automated>
  </verify>
  <done>
    - All ~14 SanitizeForModel tests pass.
    - The file exposes exactly the three public functions; no wrap step exists in this file.
    - Order test (`test_prepareForBoundary_runsSanitizeBeforeHeadTruncate`) explicitly demonstrates sanitize-before-truncate ordering.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: ToolRegistry value type + tests</name>
  <files>
    packages/MCP/Sources/MCP/ToolRegistry.swift,
    packages/MCP/Tests/MCPTests/ToolRegistryTests.swift
  </files>
  <behavior>
    - Test (RED first): `test_register_storesToolToServerMapping` — `registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)`; `registry.server(forTool: "get_time")` returns `"mcp-time"`.
    - Test: `test_unknownTool_returnsNil` — empty registry; `server(forTool: "anything")` returns nil; `requiresConfirmation(toolName: "anything")` returns false.
    - Test: `test_requiresConfirmation_returnsCorrectFlag` — register get_time (false) and run_applescript (true); query both.
    - Test: `test_toolNames_listsAllRegistered` — register 3 tools; `toolNames` returns a sorted array of all 3.
    - Test: `test_register_overwritesExisting` — register get_time twice with different server names; the second registration wins (last-write semantics, no error).
  </behavior>
  <action>
    1. Create `packages/MCP/Sources/MCP/ToolRegistry.swift`:
       ```swift
       import Foundation

       public struct ToolRegistry: Sendable {
           private struct Entry: Sendable {
               let serverName: String
               let requiresConfirmation: Bool
           }
           private var entries: [String: Entry] = [:]

           public init() {}

           public mutating func register(toolName: String, serverName: String, requiresConfirmation: Bool) {
               entries[toolName] = Entry(serverName: serverName, requiresConfirmation: requiresConfirmation)
           }

           public func server(forTool toolName: String) -> String? {
               entries[toolName]?.serverName
           }

           public func requiresConfirmation(toolName: String) -> Bool {
               entries[toolName]?.requiresConfirmation ?? false
           }

           public var toolNames: [String] {
               Array(entries.keys).sorted()
           }
       }
       ```

    2. Tests as in `<behavior>`.

    Anti-patterns:
    - DO NOT make `ToolRegistry` an actor — it's a value type that gets snapshotted into MCPToolDispatcher's nonisolated let so the protocol's sync `requiresConfirmation` works without an actor hop.
    - DO NOT add a "remove" or "deregister" path — we don't unregister tools at runtime in v1.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter ToolRegistryTests 2>&amp;1 | tail -10</automated>
  </verify>
  <done>
    - All 5 ToolRegistry tests pass.
    - `grep -c 'public struct ToolRegistry: Sendable' packages/MCP/Sources/MCP/ToolRegistry.swift` returns 1.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: MCPToolDispatcher conforms to ToolDispatcher + dispatch happy/error paths + observer callback</name>
  <files>
    packages/MCP/Sources/MCP/MCPToolDispatcher.swift,
    packages/MCP/Package.swift,
    packages/MCP/Tests/MCPTests/MCPToolDispatcherTests.swift
  </files>
  <behavior>
    - Test (RED first): `test_dispatch_callsClientThenSanitizes` — wire a mock `MCPClient`-shaped wrapper that returns `CallTool.Result` with `.text("hello\u{200B}\u{202E}world")`; call `dispatch(toolUse: ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data()))`. Assert returned Data, when decoded as UTF-8, equals `"helloworld"` (zero-width + bidi stripped, no truncation marker, no wrap envelope).
    - Test: `test_dispatch_concatenatesMultipleTextContent` — mock returns 2 `.text` blocks; expect output to be the joined string sanitized.
    - Test: `test_dispatch_underTruncationCap_doesNotTruncate` — small input passes through unchanged.
    - Test: `test_dispatch_overTruncationCap_addsMarker` — pass a 20000-byte input; assert output ends with `…[tool-result-truncated at 8192 bytes]`.
    - Test: `test_dispatch_propagatesMCPError` — mock client raises `MCPError.serverCrashed(name: "mcp-time")`; dispatcher rethrows verbatim.
    - Test: `test_requiresConfirmation_readsRegistry_synchronously` — registry has run_applescript=true, get_time=false; call `dispatcher.requiresConfirmation(toolName: "run_applescript")` (synchronously, not awaited); assert true. Same for get_time → false.
    - Test: `test_observer_receivesPreAndPostSanitizeBytes` — install a recording observer; dispatch with input `"x\u{200B}y"`. Assert observer was called once with `rawBytes` decoding to `"x\u{200B}y"` AND `sanitizedBytes` decoding to `"xy"`.
    - Test: `test_observer_isNotCalled_onError` — when MCPClient throws, observer is NOT invoked (errors don't have post-sanitize bytes to record).
  </behavior>
  <action>
    1. Update `packages/MCP/Package.swift` to add a dependency on AgentCore so the `MCP` target can `import AgentOrchestrator` for the `ToolDispatcher` protocol AND `import AgentCore` for `ToolUseRequest`:
       ```swift
       dependencies: [
           .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
           .package(path: "../Logging"),
           .package(path: "../AgentCore"),  // NEW — for ToolDispatcher + ToolUseRequest
       ],
       targets: [
           .target(
               name: "MCP",
               dependencies: [
                   .product(name: "MCP", package: "swift-sdk"),
                   .product(name: "JarvisLogging", package: "Logging"),
                   .product(name: "AgentCore", package: "AgentCore"),
                   .product(name: "AgentOrchestrator", package: "AgentCore"),
               ],
               swiftSettings: [.swiftLanguageMode(.v6)]
           ),
           // ... testTarget unchanged ...
       ]
       ```
       Critical: this introduces an ASYMMETRIC dependency — `MCP` depends on `AgentCore`, but `AgentCore` does NOT depend on `MCP`. The orchestrator instantiates `MCPToolDispatcher` in App-target wiring later, so the App target imports both. No cycle.

       Note on Plan 05-01's stated assumption ("MCP does not depend on AgentCore"): that was correct for 05-01 in isolation. This plan introduces the dependency intentionally as the bridge between the two packages. Update 05-01's SUMMARY in this plan's SUMMARY if needed.

    2. Create `packages/MCP/Sources/MCP/MCPToolDispatcher.swift`:
       ```swift
       import Foundation
       import AgentCore
       import AgentOrchestrator
       import struct MCP.Value
       import struct MCP.Tool

       public protocol ToolResultObserver: Sendable {
           func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async
       }

       public actor MCPToolDispatcher: ToolDispatcher {
           private let client: MCPClient
           private nonisolated let registrySnapshot: ToolRegistry
           private let observer: (any ToolResultObserver)?

           public init(client: MCPClient, registry: ToolRegistry, observer: (any ToolResultObserver)? = nil) {
               self.client = client
               self.registrySnapshot = registry  // value-type snapshot; nonisolated read is safe
               self.observer = observer
           }

           public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
               // Decode args from raw JSON bytes into [String: MCP.Value] for the SDK.
               let arguments: [String: Value]
               if toolUse.argsJSON.isEmpty {
                   arguments = [:]
               } else {
                   guard let json = try JSONSerialization.jsonObject(with: toolUse.argsJSON) as? [String: Any] else {
                       arguments = [:]
                       // Tolerate empty/malformed args — fall back to empty. The helper will return an error if it requires args.
                       return Data("Invalid tool arguments JSON.".utf8)
                   }
                   arguments = MCPToolDispatcher.toMCPValueDict(json)
               }

               // Call the SDK client.
               let result = try await client.callTool(name: toolUse.name, arguments: arguments)

               // Concatenate all .text content blocks (the SDK supports image too in v1+, we only handle .text).
               let rawText = result.content.compactMap { content -> String? in
                   if case let .text(text, _, _) = content { return text }
                   return nil
               }.joined(separator: "\n")

               // SEC-07 step 1+2: sanitize → headTruncate. Wrap step is the orchestrator's job.
               let prepared = SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)

               // Observer callback for replay capture (raw + sanitized bytes).
               if let observer = observer {
                   let rawBytes = Data(rawText.utf8)
                   let preparedBytes = Data(prepared.utf8)
                   await observer.record(
                       toolUseId: toolUse.id,
                       toolName: toolUse.name,
                       rawBytes: rawBytes,
                       sanitizedBytes: preparedBytes
                   )
               }

               return Data(prepared.utf8)
           }

           public nonisolated func requiresConfirmation(toolName: String) -> Bool {
               registrySnapshot.requiresConfirmation(toolName: toolName)
           }

           // MARK: - Helpers

           private static func toMCPValueDict(_ json: [String: Any]) -> [String: Value] {
               var out: [String: Value] = [:]
               for (k, v) in json {
                   out[k] = toMCPValue(v)
               }
               return out
           }

           private static func toMCPValue(_ v: Any) -> Value {
               if let s = v as? String { return .string(s) }
               if let n = v as? Int { return .int(n) }
               if let n = v as? Double { return .double(n) }
               if let b = v as? Bool { return .bool(b) }
               if let arr = v as? [Any] { return .array(arr.map(toMCPValue)) }
               if let dict = v as? [String: Any] { return .object(toMCPValueDict(dict)) }
               return .string(String(describing: v))
           }
       }
       ```

    3. Tests as in `<behavior>`. The mock-MCPClient strategy: since `MCPClient` is a concrete actor (not a protocol), use a real MCPClient with the MockHelper fixture from Plan 05-01 for happy-path tests, and for error-injection tests use a MockHelper that returns `isError: true` or that crashes mid-call. Alternatively: factor out a `MCPClientCalling` protocol on MCPClient and have MCPToolDispatcher take `any MCPClientCalling`. Pick whichever is cleaner — preference is for the protocol abstraction since it makes unit-testing the dispatcher in isolation cleaner.

       If extracting a protocol: add to `MCPClient.swift`:
       ```swift
       public protocol MCPClientCalling: Sendable {
           func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result
           func toolMetadata(_ name: String) async -> ToolMetadata?
       }

       extension MCPClient: MCPClientCalling {}
       ```
       And change MCPToolDispatcher's init to take `any MCPClientCalling` instead of `MCPClient`. This keeps Plan 05-01 unchanged in surface but adds an extension here.

    Anti-patterns:
    - DO NOT call `UntrustedWrapper.wrap(_:)` from the dispatcher. The orchestrator (Plan 04-04) calls it AFTER `dispatch(...)` returns. Calling here would double-wrap and corrupt the nonce-once invariant.
    - DO NOT serialize raw `argsJSON` into the result for diagnostic purposes — args from the model can themselves be untrusted. Args go to ReplayLog separately via the orchestrator's existing path.
    - DO NOT include the helper bundle path or the helper's stderr output in the dispatch result — those go to MCPLogChannel separately.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter MCPToolDispatcherTests 2>&amp;1 | tail -25 &amp;&amp; swift test --package-path packages/MCP 2>&amp;1 | tail -10 &amp;&amp; swift build --package-path packages/MCP 2>&amp;1 | tail -3 &amp;&amp; ! grep -q 'UntrustedWrapper\|wrapUntrusted' packages/MCP/Sources/MCP/MCPToolDispatcher.swift &amp;&amp; grep -c ': ToolDispatcher' packages/MCP/Sources/MCP/MCPToolDispatcher.swift &amp;&amp; grep -c 'SanitizeForModel.prepareForBoundary' packages/MCP/Sources/MCP/MCPToolDispatcher.swift</automated>
  </verify>
  <done>
    - All 8 MCPToolDispatcher tests pass.
    - The dispatcher conforms to AgentOrchestrator's `ToolDispatcher` protocol (grep verifies).
    - The dispatcher does NOT reference `UntrustedWrapper` (anti-pattern guard).
    - `swift build --package-path packages/MCP` exits 0 even with the new AgentCore dependency.
    - Full MCP test suite green (this plan + plans 05-01 still pass).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Helper subprocess → MCPToolDispatcher | Bytes from helper stdout cross from untrusted-content territory into the orchestrator's history. Sanitize+headTruncate runs at this hop. |
| MCPToolDispatcher → orchestrator-provided ToolUseRequest | The `argsJSON` came from the model; the dispatcher decodes and forwards but does NOT validate beyond "is it valid JSON?" The helper's `inputSchema` is the second-level validation. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-04-01 | Tampering | Sanitize order drift (headTruncate before sanitize OR wrap before truncate) | mitigate | `prepareForBoundary` is the SOLE entry point for the pipeline; tests assert sanitize-before-truncate ordering. The wrap step explicitly does NOT exist in this file (grep guard `! grep -q 'wrapUntrusted'`). |
| T-05-04-02 | Tampering | Bidi-override / zero-width characters in tool output silently re-render under different visual order in the model's prompt | mitigate | `sanitize(_:)` strips U+202A..E, U+2066..9 (bidi) and U+200B..D, U+2060, U+FEFF (zero-width). 4 dedicated tests cover each character class. |
| T-05-04-03 | Tampering | Tag-closure injection ("</UNTRUSTED_CONTENT>" inside tool output forging the wrap close) | mitigate (deferred to Plan 04-04) | The orchestrator's `UntrustedWrapper.wrap(_:)` already pre-strips tag-like substrings BEFORE wrapping. This plan explicitly does NOT call wrap, so tag-strip is the orchestrator's responsibility (already unit-tested in Plan 04-04). The order is: sanitize (here) → truncate (here) → wrap+tag-strip (orchestrator). |
| T-05-04-04 | Information Disclosure | Tool result content leaking >8KB into model context (Opus 4.7 ~1.35x tokenizer inflation drives unintended cost + crowds out cache) | mitigate | `headTruncate` defaults to 8192 bytes (matches AGENT-08's `ToolResultPacker.modelFacingCapBytes`); marker explicitly states `at 8192 bytes`. |
| T-05-04-05 | Tampering | Future contributor calling `UntrustedWrapper.wrap` from the dispatcher (double-wrap) | mitigate | Inline anti-pattern note + grep gate `! grep -q 'wrapUntrusted\|UntrustedWrapper' packages/MCP/Sources/MCP/MCPToolDispatcher.swift`. |
| T-05-04-06 | Information Disclosure | Observer callback leaking nonce into a downstream consumer (e.g., HUD bus) | mitigate | The `ToolResultObserver` protocol's `record(...)` signature has NO nonce parameter. The nonce is the orchestrator's secret. The observer receives raw bytes + sanitized bytes only — both are content, neither is nonce. SEC-06 invariant preserved. |
| T-05-04-07 | Denial of Service | Sanitize hot path on a 100MB tool result (CPU starvation) | accept (helper-side cap) | Helpers should return reasonable result sizes; if a future helper produces megabytes, the head-truncate-to-8KB step bounds memory immediately after sanitize. Sanitize itself is O(n) on the input scalars; 100MB of raw bytes is ~25M scalars, which on Apple Silicon takes ~50-100ms — a one-time cost, not a sustained DoS vector. |
</threat_model>

<verification>
1. `swift build --package-path packages/MCP` exits 0 with the new AgentCore dep resolved.
2. `swift test --package-path packages/MCP` runs ALL plans 05-01..05-04 tests; 0 failures.
3. Grep gates:
   - `grep -c 'public static func sanitize\|public static func headTruncate\|public static func prepareForBoundary' packages/MCP/Sources/MCP/SanitizeForModel.swift` returns 3.
   - `! grep -q 'wrapUntrusted\|UntrustedWrapper' packages/MCP/Sources/MCP/MCPToolDispatcher.swift` (no wrap in dispatcher).
   - `! grep -q 'wrapUntrusted\|UntrustedWrapper\|UNTRUSTED_CONTENT' packages/MCP/Sources/MCP/SanitizeForModel.swift` (sanitize doesn't wrap).
   - `grep -c ': ToolDispatcher\b' packages/MCP/Sources/MCP/MCPToolDispatcher.swift` returns 1 (protocol conformance).
   - `grep -c 'SanitizeForModel.prepareForBoundary' packages/MCP/Sources/MCP/MCPToolDispatcher.swift` returns 1 (canonical pipeline call site).
   - `grep -c '0x200B\|0x202A\|0x2060\|0xFEFF' packages/MCP/Sources/MCP/SanitizeForModel.swift` returns >= 4 (bidi + zero-width literal coverage).
4. Phase 4's AgentCore tests still pass: `swift test --package-path packages/AgentCore` reports 0 failures (no regression).
</verification>

<success_criteria>
- The SEC-07 sanitize pipeline is implemented at a single canonical call site (`SanitizeForModel.prepareForBoundary`); fixed-order is structurally enforced.
- `MCPToolDispatcher` conforms to the existing `ToolDispatcher` protocol from Phase 4; the orchestrator can swap from `StubToolDispatcher` to `MCPToolDispatcher` with no orchestrator changes.
- The observer callback exposes pre- and post-sanitize byte streams for replay capture (consumed in Plan 05-05's app-shell wiring).
- Sanitize order is verified by a dedicated test (`test_prepareForBoundary_runsSanitizeBeforeHeadTruncate`); future contributors who reorder will get a test failure.
- The double-wrap anti-pattern is regression-guarded by inline grep gates.
</success_criteria>

<output>
Write `.planning/phases/05-mcp/05-04-SUMMARY.md`. Highlights:
- New AgentCore dependency added to `packages/MCP/Package.swift` — flag this as the deviation from Plan 05-01's "MCP depends only on swift-sdk + Logging" assumption. The dependency is asymmetric (MCP→AgentCore, never the reverse), so no cycle. Update Plan 05-01's SUMMARY note to reflect.
- `SanitizeForModel` is the canonical pipeline; document the order rationale verbatim from RESEARCH (truncate-before-sanitize leaks invalid UTF-8; wrap-before-truncate breaks the nonce envelope on the truncation marker).
- Document the `MCPClientCalling` protocol extraction (if performed) and the rationale (clean unit tests; production conformance is just `extension MCPClient: MCPClientCalling {}`).
- Confirm Phase 4 tests still pass with no AgentCore-side changes.
- Note that Plan 05-05 will instantiate MCPToolDispatcher in AppDelegate alongside the ConfirmationBroker. The dispatcher is "ready to wire" from this plan's perspective.
</output>
