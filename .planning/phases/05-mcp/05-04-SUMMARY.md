---
phase: 05-mcp
plan: 04
subsystem: mcp
tags: [mcp, sanitize, head-truncate, tool-dispatcher, sec-07, agent-08]
requirements-completed: [SEC-07]
dependency-graph:
  requires: [04-04, 05-01, 05-02, 05-03]
  provides:
    - SanitizeForModel.prepareForBoundary (sanitize → headTruncate canonical pipeline)
    - MCPToolDispatcher (conforms to AgentOrchestrator.ToolDispatcher)
    - ToolRegistry (value-type tool→server→requiresConfirmation lookup)
    - MCPClientCalling (test-friendly client surface)
    - ToolResultObserver (pre/post-sanitize replay-capture callback)
  affects:
    - packages/MCP/Package.swift (asymmetric dep on AgentCore added)
tech-stack:
  added: []
  patterns:
    - "Canonical pipeline composition via single-entry-point function (`prepareForBoundary`) to structurally enforce fixed step order."
    - "Value-type registry snapshot captured as `nonisolated let` inside an actor to satisfy a sync protocol method without an actor hop."
    - "Calling-side protocol extracted from a concrete actor (`MCPClientCalling` → `extension MCPClient: MCPClientCalling {}`) to enable in-process unit-test mocks without subprocesses."
key-files:
  created:
    - packages/MCP/Sources/MCP/SanitizeForModel.swift
    - packages/MCP/Sources/MCP/ToolRegistry.swift
    - packages/MCP/Sources/MCP/MCPToolDispatcher.swift
    - packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift
    - packages/MCP/Tests/MCPTests/ToolRegistryTests.swift
    - packages/MCP/Tests/MCPTests/MCPToolDispatcherTests.swift
  modified:
    - packages/MCP/Package.swift
decisions:
  - "Sanitize and head-truncate run at the MCP boundary (this plan); the SEC-06 wrap step stays with the orchestrator (Plan 04-04). MCPToolDispatcher.dispatch returns sanitized+truncated bytes; the orchestrator's existing `wrapper.wrap(packed.modelFacing)` call wraps them post-dispatch. No double-wrap."
  - "Pipeline order is structurally enforced by exposing only `SanitizeForModel.prepareForBoundary` as the canonical entry; `sanitize` and `headTruncate` are also public for tests but the dispatcher only ever calls `prepareForBoundary`. A dedicated test (10000→2500 byte distinguisher) catches reverse-order regressions."
  - "Per-line cap is 4096 UTF-8 bytes (with `…[line-truncated]` marker); boundary cap is 8192 UTF-8 bytes (with `…[tool-result-truncated at <N> bytes]` marker). Both ROADMAP-prescribed. Per-line cap fires first for any single line that exceeds it; boundary cap then fires on the joined result if the post-sanitize total still exceeds 8192."
  - "Asymmetric SPM dependency direction: MCP→AgentCore. AgentCore intentionally does NOT depend on MCP — the orchestrator stays provider-agnostic and only sees the `ToolDispatcher` protocol. This deviates from Plan 05-01's stated isolation; that deviation is the intentional bridge wired by this plan."
  - "Extract `MCPClientCalling` protocol on the dispatcher side (not in MCPClient.swift) so unit tests can mock the SDK boundary without spawning helper subprocesses. Production conformance is `extension MCPClient: MCPClientCalling {}` in MCPToolDispatcher.swift; MCPClient.swift was not modified."
  - "`ToolResultObserver` exposes pre-sanitize raw bytes AND post-sanitize prepared bytes for the SEC-07 audit trail. Per-turn nonce is intentionally absent from the callback signature — the nonce is the orchestrator's secret; observers see content only. Plan 05-05 will wire the callback to ReplayLog in AppDelegate."
  - "`MCPToolDispatcher.requiresConfirmation(toolName:)` is `nonisolated` and reads from a `nonisolated let registrySnapshot: ToolRegistry`. Value-type semantics make this safe under Swift 6 strict concurrency; the protocol's sync method is satisfied without coloring callers async."
metrics:
  duration: ~50 min
  completed: 2026-04-25
  loc: 770 (3 source files + 3 test files)
---

# Phase 5 Plan 04: Sanitize Pipeline + MCPToolDispatcher Summary

SEC-07 byte-stream sanitize pipeline + the concrete `MCPToolDispatcher` that conforms to Phase 4's `ToolDispatcher` protocol. Closes SEC-07; readies the dispatcher for Plan 05-05's ConfirmationBroker interposer + AppDelegate wiring.

## What landed

### `SanitizeForModel`

Three public functions, all pure and synchronous:

- `sanitize(_:)` — split-on-`\n`-first scrub. Each line:
  - C0 controls dropped except `\t` (`\n` survives via the split-first pattern)
  - DEL (U+007F) dropped
  - Bidi overrides (U+202A..E) and isolates (U+2066..9) dropped
  - Zero-width (U+200B..D, U+2060) and BOM (U+FEFF) dropped
  - Per-line UTF-8 byte cap at 4096 with `…[line-truncated]` marker
- `headTruncate(_:capBytes:)` — UTF-8 byte-count truncation with explicit `\n…[tool-result-truncated at <N> bytes]` marker. Default cap 8192 matches AGENT-08's `ToolResultPacker.modelFacingCapBytes`.
- `prepareForBoundary(_:capBytes:)` — canonical fixed-order composition (`sanitize` → `headTruncate`). The SOLE entry point from `MCPToolDispatcher`. The wrap step is intentionally absent — it lives in `AgentCore`'s nonce-gated wrapper, called by the orchestrator AFTER `dispatch(toolUse:)` returns.

### `ToolRegistry`

`Sendable` value type with `register(toolName:serverName:requiresConfirmation:)`, `server(forTool:)`, `requiresConfirmation(toolName:)`, `toolNames` (sorted). Last-write-wins on duplicate register. Captured by `MCPToolDispatcher` as a `nonisolated let` snapshot at init.

### `MCPToolDispatcher`

Public actor conforming to `ToolDispatcher`:

```swift
public init(
    client: any MCPClientCalling,
    registry: ToolRegistry,
    observer: (any ToolResultObserver)? = nil
)

public func dispatch(toolUse: ToolUseRequest) async throws -> Data
public nonisolated func requiresConfirmation(toolName: String) -> Bool
```

`dispatch(toolUse:)` flow:
1. Decode `argsJSON` → `[String: MCP.Value]` (tolerant of empty/malformed input).
2. Forward to `client.callTool(name:arguments:)`. Errors propagate verbatim.
3. Concatenate all `.text` content blocks into a single string.
4. Run `SanitizeForModel.prepareForBoundary` (sanitize → headTruncate, cap 8192).
5. Fire `ToolResultObserver.record(...)` with both `rawBytes` and `sanitizedBytes`.
6. Return `Data(prepared.utf8)`.

`requiresConfirmation(toolName:)` is sync — backed by the value-type registry snapshot. No actor hop.

### `MCPClientCalling`

```swift
public protocol MCPClientCalling: Sendable {
    func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result
}
extension MCPClient: MCPClientCalling {}
```

Extracted at the dispatcher layer (not in `MCPClient.swift`) to keep production code path identical while letting unit tests mock the SDK boundary without spawning subprocesses.

### `ToolResultObserver`

Pre/post-sanitize replay-capture protocol. Plan 05-05 wires the actual `ReplayLog` writer in AppDelegate.

## SPM dependency direction

This plan adds an **asymmetric** dependency in `packages/MCP/Package.swift`:

```diff
+ .package(path: "../AgentCore"),
```

with the `JarvisMCP` target importing both `AgentCore` (for `ToolUseRequest`) and `AgentOrchestrator` (for `ToolDispatcher`). `AgentCore` does **not** depend on `MCP` — the orchestrator stays provider-agnostic and only sees the protocol. No cycle.

This deviates from Plan 05-01's stated isolation note ("MCP depends only on swift-sdk + Logging"). The deviation is intentional and is the bridge between the two packages; if Plan 05-01's SUMMARY is updated to reflect this, the note is "extended in 05-04 with the asymmetric AgentCore dep".

## Verification

| Check | Result |
|-------|--------|
| `swift test --package-path packages/MCP` | **49 / 49** (was 18 baseline; +31 new) |
| `swift build --package-path packages/MCP -c release` | exit 0 (33 s) |
| `swift test --package-path packages/AgentCore` | **134 / 134** (no regression) |
| `swift test --package-path packages/Replay` | **27 / 27** (no regression) |
| `swift test --package-path packages/Bus` | **47 / 47** (no regression) |
| `swift test --package-path mcp-servers/mcp-clipboard` | **6 / 6** (no regression) |
| `swift test --package-path mcp-servers/mcp-applescript` | **4 / 4** (no regression) |

Grep gates (verbatim from plan):

| Gate | Result |
|------|--------|
| `grep -c 'public static func sanitize\|... headTruncate\|... prepareForBoundary' SanitizeForModel.swift` | 3 ✓ |
| `! grep -q 'wrapUntrusted\|UntrustedWrapper' MCPToolDispatcher.swift` | exit 1 ✓ |
| `! grep -q 'wrapUntrusted\|UntrustedWrapper\|UNTRUSTED_CONTENT' SanitizeForModel.swift` | exit 1 ✓ |
| `grep -c ': ToolDispatcher\b' MCPToolDispatcher.swift` | 2 (1 conformance + 1 MARK label) ✓ |
| `grep -c 'SanitizeForModel.prepareForBoundary' MCPToolDispatcher.swift` | 1 ✓ |
| `grep -oE '0x200B\|0x202A\|0x2060\|0xFEFF' SanitizeForModel.swift \| wc -l` | 4 ✓ |

Pipeline-order test (`test_prepareForBoundary_runsSanitizeBeforeHeadTruncate`) explicitly demonstrates that reversed order (head-truncate before sanitize) would leak a truncation marker into output that, after the correct order, is well under the cap. Ran with the canonical implementation: passes; mentally simulated with reversed order: would fail. Not a tautology.

## Deviations from Plan

### Auto-fixed Issues

**1. [Plan path adjustment] Library name is `JarvisMCP`, not `MCP`**
- **Found during:** Task 1 (writing SanitizeForModel.swift).
- **Issue:** The plan's frontmatter `files_modified` says `packages/MCP/Sources/MCP/SanitizeForModel.swift` and the test imports use `@testable import JarvisMCP`. Source path is correct; module/import name is `JarvisMCP` per the existing `Package.swift` (Plan 05-01's "avoid name collision with the SDK's `MCP` library product" decision).
- **Fix:** Use `@testable import JarvisMCP` in tests (matches existing files) and import `MCP` (the SDK) for `Tool`, `Value`, `CallTool` types. No file paths or symbols renamed.
- **Files modified:** test files (used correct module name).

**2. [Doc-comment cleanup for grep gate]**
- **Found during:** Task 1 self-check.
- **Issue:** Initial `SanitizeForModel.swift` doc comments referenced `wrapUntrusted` and `UntrustedWrapper` literally (in narrative explaining the order). The plan's grep gate `! grep -q 'wrapUntrusted\|UntrustedWrapper\|UNTRUSTED_CONTENT' SanitizeForModel.swift` would fail on those literals.
- **Fix:** Reworded comments to "the SEC-06 wrap step (Plan 04-04)" / "the orchestrator's nonce-gated wrap step" without using the literal symbol names.
- **Files modified:** `packages/MCP/Sources/MCP/SanitizeForModel.swift`.

### Architectural changes

None. The asymmetric `MCP→AgentCore` SPM dep was prescribed by the plan and only superficially deviates from Plan 05-01's earlier note.

## Authentication gates

None.

## Threat surface scan

No new attack surface beyond what the plan's `<threat_model>` already enumerates. Stride matches: T-05-04-01 (order drift) mitigated by single-entry-point composition + ordering test; T-05-04-02 (bidi/zero-width) mitigated by scalar-range filter + 4 dedicated tests; T-05-04-03 (tag-closure injection) deferred to AgentCore's existing wrap step (untouched by this plan); T-05-04-04 (>8KB leak) mitigated by 8192-byte head-truncate; T-05-04-05 (double-wrap) mitigated by inline anti-pattern note + grep gate; T-05-04-06 (nonce leak via observer) mitigated by `ToolResultObserver` signature explicitly omitting the nonce; T-05-04-07 (DoS on huge results) accepted (helper-side responsibility).

## Known stubs (deferred to Plan 05-05)

- **`MCPToolDispatcher` is not yet instantiated in the App target.** Plan 05-05 will wire it into `AppDelegate` alongside the `ConfirmationBroker`. The dispatcher is "ready to wire" from this plan's perspective.
- **`ToolResultObserver` callback is exposed but no production observer is registered.** Plan 05-05 will provide the AppDelegate-level observer that calls `ReplayLog.record(.toolResultFull(...))` and `.toolResultSanitized(...)` (or whichever naming Plan 05-05 settles on). ME-04 (orchestrator→replay 2048-cap channel live wiring) is also a Plan 05-05 concern.
- **Confirmation gating is NOT in this dispatcher.** Plan 05-05 introduces a `ConfirmingToolDispatcher` that interposes on top of `MCPToolDispatcher`. The interposer reads `requiresConfirmation(toolName:)` from us and consults the HUD broker before forwarding.

## Phase 5 Wave 5 readiness

- ✅ `MCPToolDispatcher.dispatch(toolUse:) -> Data` returns sanitized+truncated bytes ready for `ToolResultPacker.pack` + `UntrustedWrapper.wrap` in the orchestrator.
- ✅ `requiresConfirmation(toolName:)` is sync and ready for the confirmation interposer.
- ✅ `ToolResultObserver` is the integration point for Plan 05-05's app-shell ReplayLog wiring + ME-04 closure.
- ✅ `ToolRegistry` is populated by the App target at boot from `MCPClient.toolMetadata` queries (or whichever path 05-05 picks).
- ✅ All Phase 4 contracts intact (134/134 AgentCore + 27/27 Replay still green).

## Self-Check: PASSED

All claimed files exist:
- ✓ `packages/MCP/Sources/MCP/SanitizeForModel.swift`
- ✓ `packages/MCP/Sources/MCP/ToolRegistry.swift`
- ✓ `packages/MCP/Sources/MCP/MCPToolDispatcher.swift`
- ✓ `packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift`
- ✓ `packages/MCP/Tests/MCPTests/ToolRegistryTests.swift`
- ✓ `packages/MCP/Tests/MCPTests/MCPToolDispatcherTests.swift`

All claimed commits exist on develop:
- ✓ `6be0561` test(05-04): RED — SanitizeForModelTests
- ✓ `55b40c1` feat(05-04): GREEN — SanitizeForModel pipeline
- ✓ `2648a24` test(05-04): RED — ToolRegistryTests
- ✓ `497fd1b` feat(05-04): GREEN — ToolRegistry
- ✓ `a48c7f7` test(05-04): RED — MCPToolDispatcherTests + AgentCore SPM dep
- ✓ `fbe6c6c` feat(05-04): GREEN — MCPToolDispatcher
