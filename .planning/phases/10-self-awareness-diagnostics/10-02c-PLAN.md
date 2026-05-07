---
phase: 10-self-awareness-diagnostics
plan: 02c
subsystem: mcp, agent-core
type: surgical-fix
autonomous: true
wave: substrate-fix
depends_on: [10-02b]
tags: [substrate-fix, b-01b, dispatch-routing, in-process-tools, mcp]

# Dependency graph
requires:
  - phase: 10-self-awareness-diagnostics (Plan 10-02b)
    provides: "Tool catalog ENUMERATION wired (model receives schemas for both stdio and in-process tools)."
  - phase: 7-memory-vision (Plan 07-06)
    provides: "InProcessToolRegistry actor + memory tools."
  - phase: 5-mcp (Plan 05-04 / 05-05)
    provides: "MCPToolDispatcher (inner) + ConfirmingToolDispatcher (outer) chain."
provides:
  - "Dispatch ROUTING for in-process tool calls — when the model emits tool_use for `get_active_audio_route` etc, dispatch routes through InProcessToolRegistry.dispatch instead of failing 'tool unknown'."
  - "InProcessAwareToolDispatcher composite that fronts MCPToolDispatcher with an in-process check; preserves ConfirmingToolDispatcher's confirmation-gate, observer, sanitizer."
affects: [B-01 actually closes; AC-05 retroactive PASS once relaunched]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Composite/router dispatcher: name lookup via in-process registry first, fallthrough to stdio. Single ConfirmingToolDispatcher continues to wrap the composite — confirmation gating preserved on both paths."
    - "Sync confirmation gate via OSAllocatedUnfairLock<Set<String>>: registry mutations update the lock-protected set so the dispatcher's nonisolated requiresConfirmation(toolName:) stays sync-accessible without an actor hop."
    - "Observer parity: in-process result bytes flow through the same SanitizeForModel.prepareForBoundary + ToolResultObserver pipeline as stdio results."

key-files:
  created:
    - "packages/MCP/Sources/MCP/InProcess/InProcessAwareToolDispatcher.swift — composite dispatcher routing in-process vs stdio."
    - "packages/MCP/Tests/MCPTests/InProcessAwareDispatchRoutingTests.swift — regression coverage."
    - ".planning/phases/10-self-awareness-diagnostics/10-02c-PLAN.md"
    - ".planning/phases/10-self-awareness-diagnostics/10-02c-SUMMARY.md"
  modified:
    - "packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift — confirmationCache hook on register so dispatcher can read sync."
    - "packages/MCP/Sources/MCP/MCPRuntimeWiring.swift — overload that takes an inProcessRegistryResolver and wires the composite dispatcher inside the ConfirmingToolDispatcher."
    - "App/AppDelegate.swift — pass inProcessToolRegistry resolver into MCPRuntimeWiring.build (or post-construction wire)."

key-decisions:
  - "D-B01b-1: composite at the INNER layer — keep ConfirmingToolDispatcher as the SINGLE outer wrapper so confirmation, bus emission, and observer fire identically for in-process and stdio tools. forget_fact (the only requiresConfirmation:true in-process tool today) routes through the same broker as run_applescript."
  - "D-B01b-2: registry mutations update a sync-accessible confirmation cache (OSAllocatedUnfairLock<Set<String>>). The composite dispatcher's nonisolated requiresConfirmation(toolName:) reads from this cache without an async hop, satisfying the ToolDispatcher protocol's sync requirement and preserving the ConfirmingToolDispatcher's existing call shape."
  - "D-B01b-3: registry passed by reference (actor reference is shareable). Tools registered AFTER MCPRuntimeWiring.build (i.e. in installSelfKnowledgeTools) are routable because the composite holds the same actor reference and looks up by name on every dispatch."
  - "D-B01b-4: live verification deferred to user (B-01b is a plumbing fix; the regression test catches the routing bug at the boundary, but the user is the one who originally hit the failure mode and should re-run the same prompts)."

requirements-completed: []  # B-01b is a substrate bug, not a SPEC requirement.

# Metrics
duration: TBD
completed: 2026-05-07
---

# Phase 10 Plan 02c: Substrate fix B-01b — wire in-process dispatch routing

**One-liner:** The B-01 fix wired tool catalog ENUMERATION (model receives schemas for in-process tools); B-01b wires DISPATCH so when the model actually calls `get_active_audio_route`, the call routes through `InProcessToolRegistry.dispatch` instead of failing with "tool unknown" because `MCPToolDispatcher` only knows about stdio tools.

## Objective

Live evidence (2026-05-07): user asked "what mic are you using?", model emitted a real `tool_use` block (catalog enumeration is now correct, validating B-01 fix), dispatch failed because the inner `MCPToolDispatcher` only knows the 3 stdio tool names. The model returned the failure as visible chat text ("the audio route tools are erroring out on this end"), masquerading the routing bug as model confusion.

Fix: introduce a composite `InProcessAwareToolDispatcher` that holds a reference to `InProcessToolRegistry` and routes by name lookup before falling through to `MCPToolDispatcher`. Wrap the composite with the existing `ConfirmingToolDispatcher` so both routing branches honor confirmation gating, bus emission, and the replay observer.

## Tasks

### Task 1 (RED): InProcessAwareDispatchRoutingTests
**type=auto, tdd=true**

Write a new test file `packages/MCP/Tests/MCPTests/InProcessAwareDispatchRoutingTests.swift` with cases:

- `routesInProcessToolToRegistry` — composite holds an in-process registry containing a canned tool `canned_in_process_tool`; dispatch by name calls `tool.call(args:)` and returns its bytes.
- `routesUnknownToInnerStdioPath` — composite's in-process registry is empty; dispatch by name `get_time` falls through to the inner stdio mock dispatcher.
- `confirmationGatePreservedOnInProcessPath` — wrap the composite with `ConfirmingToolDispatcher`; register an in-process tool with `requiresConfirmation: true` (e.g. a fake `forget_fact`); dispatch waits on broker; auto-approve via broker outcome; assert the in-process tool was called.
- `toolsRegisteredAfterDispatcherBuiltAreRoutable` — build composite with empty registry; register tool AFTER construction; dispatch by the new tool's name routes correctly. (The timing-wrinkle case that the AppDelegate install order causes.)
- `inProcessResultFlowsThroughObserver` — assert the same `ToolResultObserver.record(...)` callback fires for in-process results as for stdio (raw + sanitized bytes).

All tests use `MockClient` + `RecordingObserver` patterns from `MCPToolDispatcherTests.swift`.

**Verification:** `swift test --package-path packages/MCP --filter InProcessAwareDispatchRoutingTests` — all FAIL (composite type doesn't exist yet).

**Commit:** `test(10-02c): add InProcessAwareDispatchRoutingTests for B-01b regression coverage`

### Task 2 (GREEN substrate): sync confirmation cache on InProcessToolRegistry
**type=auto**

Add a sync-accessible confirmation gate to `InProcessToolRegistry` so the composite dispatcher's `nonisolated func requiresConfirmation(toolName:) -> Bool` can read without an actor hop:

```swift
import os.lock

public final class InProcessConfirmationCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Set<String>())
    public init() {}
    public func insert(_ name: String, requiresConfirmation: Bool) {
        lock.withLock { state in
            if requiresConfirmation { state.insert(name) }
            else { state.remove(name) }
        }
    }
    public func contains(_ name: String) -> Bool {
        lock.withLock { state in state.contains(name) }
    }
    public func names() -> Set<String> {
        lock.withLock { $0 }
    }
}
```

Modify `InProcessToolRegistry`:
- Add `public let confirmationCache: InProcessConfirmationCache` (default-init in `init`).
- In `register(_ tool:)`, call `confirmationCache.insert(tool.name, requiresConfirmation: tool.requiresConfirmation)`.

**Verification:** `swift test --package-path packages/MCP --filter InProcessToolRegistry` — existing tests pass; new cache state asserted via the routing tests.

**Commit:** `feat(10-02c): add InProcessConfirmationCache for sync confirmation lookup`

### Task 3 (GREEN substrate): InProcessAwareToolDispatcher composite
**type=auto**

Create `packages/MCP/Sources/MCP/InProcess/InProcessAwareToolDispatcher.swift`:

```swift
import Foundation
import AgentCore
import AgentOrchestrator

/// Composite ToolDispatcher: name-lookup routes either to InProcessToolRegistry
/// or to a fallback (typically MCPToolDispatcher backed by MCPClient).
///
/// Inserted INSIDE the ConfirmingToolDispatcher chain — the outer
/// ConfirmingToolDispatcher's confirmation gate, bus emission, and observer
/// hooks are unchanged; this composite is the new "inner" dispatcher.
public actor InProcessAwareToolDispatcher: ToolDispatcher {
    private let inProcessRegistry: InProcessToolRegistry
    private let confirmationCache: InProcessConfirmationCache  // sync mirror of registry's confirmation flags
    private let inner: any ToolDispatcher                       // stdio fallback (typically MCPToolDispatcher)
    private let observer: (any ToolResultObserver)?             // shared with stdio path

    public init(
        inProcessRegistry: InProcessToolRegistry,
        confirmationCache: InProcessConfirmationCache,
        inner: any ToolDispatcher,
        observer: (any ToolResultObserver)? = nil
    ) {
        self.inProcessRegistry = inProcessRegistry
        self.confirmationCache = confirmationCache
        self.inner = inner
        self.observer = observer
    }

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        if await inProcessRegistry.contains(toolUse.name) {
            // Route to in-process registry.
            let rawBytes = try await inProcessRegistry.dispatch(toolUse.name, args: toolUse.argsJSON)
            // Same sanitize pipeline as stdio path.
            let rawText = String(data: rawBytes, encoding: .utf8) ?? ""
            let prepared = SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)
            if let observer = observer {
                await observer.record(
                    toolUseId: toolUse.id,
                    toolName: toolUse.name,
                    rawBytes: Data(rawText.utf8),
                    sanitizedBytes: Data(prepared.utf8)
                )
            }
            return Data(prepared.utf8)
        }
        return try await inner.dispatch(toolUse: toolUse)
    }

    public nonisolated func requiresConfirmation(toolName: String) -> Bool {
        // sync read from the confirmation cache; falls through to inner if not in-process
        if confirmationCache.contains(toolName) {
            return true
        }
        return inner.requiresConfirmation(toolName: toolName)
    }
}
```

Note: `confirmationCache.contains` returns whether the in-process tool exists with `requiresConfirmation:true`. For in-process tools with `requiresConfirmation:false`, it returns false; we still fall through to `inner.requiresConfirmation` which won't know the name and will return false — correct outcome. For a name not in the in-process registry at all, the fall-through path queries `inner.requiresConfirmation` (the stdio registry) which is the correct semantic.

**Verification:** Tests from Task 1 now PASS.

**Commit:** `feat(10-02c): add InProcessAwareToolDispatcher composite for B-01b dispatch routing`

### Task 4 (production wiring): MCPRuntimeWiring + AppDelegate
**type=auto**

Modify `MCPRuntimeWiring.build` to accept an optional `inProcessRegistry: InProcessToolRegistry?` parameter. When provided, wrap the inner `MCPToolDispatcher` with `InProcessAwareToolDispatcher` BEFORE feeding it to `ConfirmingToolDispatcher`. When nil, behavior is unchanged (back-compat for existing tests).

But — there's a timing wrinkle. `installMCP` runs BEFORE `installMemory` (per the install order: `mcpInstallTask` is task 10, `memoryInstallTask` is task 11). So at the moment `MCPRuntimeWiring.build` runs, `inProcessToolRegistry` is nil.

**Two options to resolve:**

**Option A (preferred — minimal install-order change):** `MCPRuntimeWiring.build` constructs an empty `InProcessToolRegistry` UPFRONT, threads it through the composite, returns it on `MCPRuntime`. AppDelegate then USES this same registry (instead of constructing its own in `buildInProcessToolRegistry`). Registrations from `installMemory` and `installSelfKnowledgeTools` land in the same registry the composite holds.

**Option B (resolver pattern):** Composite holds a `@Sendable () async -> InProcessToolRegistry?` resolver closure. AppDelegate provides a closure that returns `self.inProcessToolRegistry`. On every dispatch, composite resolves and dispatches via the live registry. Slower per-call but no install-order coupling.

Choose **Option A** for simplicity:
1. `InProcessToolRegistry` is constructed in `MCPRuntimeWiring.build` (empty), exposed on `MCPRuntime.inProcessToolRegistry`.
2. AppDelegate stores `self.inProcessToolRegistry = mcpRuntime.inProcessToolRegistry` after MCP install completes.
3. `installMemory` / `installSelfKnowledgeTools` register against the same registry.
4. The composite holds the registry reference; lookups + dispatches see the latest registrations.

**Note:** Option A requires reordering AppDelegate slightly: assign `self.inProcessToolRegistry` right after `MCPRuntimeWiring.build` completes, BEFORE `installMemory` runs. Since `agentInstallTask` already awaits `mcpInstallTask`, and `installMemory` is independent, we add the same await on `mcpInstallTask` to the memory task too.

Actually, simpler: `installMemory` already runs concurrently with `installMCP`; if we make `installMemory` await `mcpInstallTask` first (before constructing dispatchers), the registry assignment is in place before memory tools register. Add `await self?.mcpInstallTask?.value` to the head of `installMemory`.

**Verification:** `bash scripts/check-app-builds.sh` PASS; existing `MemoryInstallWiringTests` still PASS (registry actor reference is shareable); `swift test --package-path packages/MCP` PASS; `swift test --package-path packages/AgentCore` PASS.

**Commit:** `fix(10-02c): route in-process tool calls through composite dispatcher (B-01b)`

### Task 5 (verify gates)
**type=auto**

Run all 18 boundary gates and assert exit 0:

- `bash scripts/check-app-builds.sh`
- `bash scripts/check-bus-harness-parity.sh`
- `bash scripts/check-bus-protocol-version.sh`
- `bash scripts/check-corpus-secrets.sh`
- `bash scripts/check-embedding-dim-literal.sh`
- `bash scripts/check-install-order.sh`
- `bash scripts/check-no-evaluate-javascript.sh`
- `bash scripts/check-no-leftover-stubs.sh`
- `bash scripts/check-no-modal-presentation.sh`
- `bash scripts/check-no-null-voice-adapters.sh`
- `bash scripts/check-orchestrator-events-single-consumer.sh`
- `bash scripts/check-presence-bus-no-tts-orchestrator.sh`
- `bash scripts/check-presence-vision-isolation.sh`
- `bash scripts/check-single-memory-mutated-emit.sh`
- `bash scripts/check-single-memory-used-emit.sh`
- `bash scripts/check-single-writer-hudstate.sh`
- `bash scripts/check-vision-isolation.sh`

(Plus `verify-codesign-settings.sh` and `verify-entitlements.sh` are codesign-gated, not source gates.)

### Task 6 (HUMAN-VERIFY checkpoint): live relaunch
**type=checkpoint:human-verify**

Same three prompts as Plan 10-02b's verification, now expected to succeed without the dispatch failure:

1. "What microphone are you using?" — log shows `tool_use` for `get_active_audio_route` (or `list_audio_devices` first, then `get_active_audio_route`). Reply names the live mic device.
2. "What time is it?" — log shows `tool_use` for `get_time`. Reply contains current time.
3. "What model are you running?" — log shows `tool_use` for `get_self_state`. Reply names `claude-opus-4-7`.

NOT acceptable: "the audio route tools are erroring out on this end" (the B-01b symptom), JSON-blob hallucination (the B-01 symptom).

## Success Criteria

- [ ] In-process tool calls now route to InProcessToolRegistry.dispatch
- [ ] Stdio tool calls still route to MCPClient/MCPToolDispatcher
- [ ] Confirmation gating preserved on both paths (forget_fact still hits the broker)
- [ ] Tools registered AFTER dispatcher construction still routable (the install-order wrinkle)
- [ ] `swift test --package-path packages/MCP` PASS
- [ ] `swift test --package-path packages/AgentCore` PASS
- [ ] `bash scripts/check-app-builds.sh` PASS
- [ ] All 17 source-level boundary gates green
- [ ] Atomic conventional commits

## Out of Scope

- B-02 (history continuity) — separate diagnosis pending.
- B-03 (camera button click delivers nothing) — separate diagnosis pending.
- B-04 (voice input dead) — separate diagnosis pending.
- B-05 (TTS silent) — separate diagnosis pending.

These remain on the punch list. Plan 10-02c is scoped to B-01b only.
