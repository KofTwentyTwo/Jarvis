---
phase: 10-self-awareness-diagnostics
plan: 02b
subsystem: agent-core, mcp
tags: [substrate-fix, b-01, available-tools, tool-catalog, anthropic, mcp]

# Dependency graph
requires:
  - phase: 10-self-awareness-diagnostics (Plan 10-01)
    provides: "Four self-knowledge MCP tools registered into InProcessToolRegistry."
  - phase: 10-self-awareness-diagnostics (Plan 10-02)
    provides: "Self-aware system-prompt preamble naming the introspection tools."
  - phase: 5-mcp (Plans 05-01 .. 05-05)
    provides: "MCPClient + stdio helper registration (mcp-time / mcp-clipboard / mcp-applescript)."
  - phase: 7-memory-vision (Plan 07-06 / 07-03)
    provides: "InProcessToolRegistry actor + memory tools (search_memory / forget_fact / search_conversation)."
provides:
  - "InProcessTool.toolDescription protocol member surfaced to the model via tools[] payload."
  - "InProcessToolRegistry.toolSchemas() projection to ToolSchema for the catalog wiring."
  - "MCPClient.toolCatalog() projection of stdio helper tools to ToolSchema (retains Tool defs from listTools)."
  - "AgentOrchestrator.availableToolsResolver init param for late-bound catalogs."
  - "App/AppDelegate.swift:1274 sourcing availableTools from the runtime catalog (no more hardcoded [])."
affects: [Plan 10-02 AC-05 retroactive PASS, Plan 10-03 DevOverlay subscriber, Plan 10-04 Voice Log, Plan 10-05 diagnostic menu]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Lazy resolver closure for the orchestrator's tool catalog (resolver wins over static array; fires once per outer turn iteration, not per stream event)."
    - "Asymmetric module dep already established: JarvisMCP imports AgentCore for ToolSchema; AgentCore stays MCP-agnostic."
    - "Per-helper Tool definitions cached in MCPClient.toolDefinitions alongside toolToServer (lifecycle parity in shutdown())."

key-files:
  created:
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AvailableToolsWiringTests.swift — orchestrator → provider boundary regression coverage"
    - "packages/MCP/Tests/MCPTests/InProcessToolRegistrySchemasTests.swift — registry-level toolSchemas() coverage"
    - ".planning/phases/10-self-awareness-diagnostics/10-02b-PLAN.md — this file"
    - ".planning/phases/10-self-awareness-diagnostics/10-02b-SUMMARY.md — execution record"
  modified:
    - "packages/MCP/Sources/MCP/InProcess/InProcessTool.swift — added var toolDescription protocol member"
    - "packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift — added toolSchemas() projection (imports AgentCore)"
    - "packages/MCP/Sources/MCP/InProcess/ListAudioDevicesTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/GetActiveAudioRouteTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/GetSelfStateTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/ListCameraDevicesTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/ForgetFactTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/InProcess/SearchConversationTool.swift — toolDescription"
    - "packages/MCP/Sources/MCP/MCPClient.swift — toolDefinitions cache + toolCatalog() projection (imports AgentCore)"
    - "packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift — availableToolsResolver: init param + per-turn resolution"
    - "App/AppDelegate.swift — line 1274: availableTools sourced from MCPClient.toolCatalog() + InProcessToolRegistry.toolSchemas() via resolver closure"

key-decisions:
  - "D-B01-1: prefer a lazy resolver closure over reordering install tasks. The chain installMemory → installVision → installAgent → installVoice → installSelfKnowledgeTools is locked by check-install-order.sh; reordering risked breaking existing invariants. The resolver fires once per outer turn iteration in AgentOrchestrator.runTurnLoop, so by the time the user submits their first turn the catalog is fully populated even though installSelfKnowledgeTools runs AFTER installAgent constructs the orchestrator."
  - "D-B01-2: name the new InProcessTool member `toolDescription` (not `description`) to avoid colliding with CustomStringConvertible.description on conforming types — protocol-default descriptions on a value type would silently override the conformance and emit the type's String(describing:) form to the model."
  - "D-B01-3: comprehensive (not deferred) — both stdio (get_time/get_clipboard/run_applescript) and in-process (4 self-knowledge + 3 memory) tools wire through the same resolver. The MCPClient extension to retain Tool definitions adds ~20 lines and closes the catalog gap completely. Deferring stdio to a follow-up B-01b would have left the model still hallucinating get_time / get_clipboard / run_applescript JSON despite Plan 10-02b shipping."
  - "D-B01-4: degrade missing helper descriptions with a placeholder rather than dropping the tool from the catalog. If a stdio helper's tools/list response omits a description, MCPClient.toolCatalog() emits 'MCP tool '...' (no description provided by helper).' so dispatch still works; the model just loses the when-to-call signal for that one tool."

patterns-established:
  - "Lazy catalog resolver pattern (closure-based, actor-safe, per-turn refresh) — applicable to any future late-bound config that needs to flow into the orchestrator after construction."
  - "Production fixes must add a regression test at the boundary that contains the bug. The pre-existing in-process registry test asserted at the wrong layer (registry was correctly populated). The new AvailableToolsWiringTests asserts at the orchestrator → provider boundary where the bug actually lived."

requirements-completed: []  # B-01 is a substrate bug, not a SPEC requirement; AC-05 retroactive re-test happens under Plan 10-02 once the user re-verifies live.

# Metrics
duration: ~50min
completed: 2026-05-07
---

# Phase 10 Plan 02b: Substrate fix B-01 — wire availableTools from runtime catalog

## Goal

Fix B-01: `App/AppDelegate.swift:1274` constructed `AgentOrchestrator(... availableTools: [], ...)` with a hardcoded empty array. The model saw the system-prompt preamble naming tools but had no schemas in the API `tools[]` array, so it hallucinated JSON tool definitions into chat instead of dispatching real `tool_use` blocks. This silenced ALL tool calls across the agent — every Phase 5 stdio helper tool, every Phase 7 memory tool, every Phase 10-01 self-knowledge tool, and Phase 9-01's vision tools.

This is a single-task surgical fix between Plans 10-02 and 10-03.

## Tasks (executed)

### Task 1 — RED: AvailableToolsWiringTests regression
- Add `packages/AgentCore/Tests/AgentOrchestratorTests/AvailableToolsWiringTests.swift`.
- Two cases (third added during Task 4):
  - `test_availableToolsReachProviderFirstCall` — schemas passed to AgentOrchestrator(availableTools:) MUST reach LLMProvider.stream(... tools:) on the first turn.
  - `test_defaultAvailableToolsYieldsEmptyToolsAtProvider` — pin the default-init contract.
- Both pass at HEAD because the orchestrator's wiring is sound; the bug is at the AppDelegate construction site, not inside the orchestrator. The tests act as regression guards.
- **Done:** test file lands and passes.

### Task 2 — Substrate: InProcessTool.toolDescription + toolSchemas()
- Extend `InProcessTool` with `var toolDescription: String { get }` (named `toolDescription` not `description` to avoid CustomStringConvertible collision).
- Add `toolDescription` to all 7 production implementations:
  - `list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices` (Phase 10-01 self-knowledge)
  - `search_memory`, `forget_fact`, `search_conversation` (Phase 7 memory)
- Add `InProcessToolRegistry.toolSchemas() -> [ToolSchema]` returning name-sorted projection.
- Add `InProcessToolRegistrySchemasTests.test_toolSchemas_projectsAllRegisteredTools`.
- **Done:** all 86 MCP tests pass.

### Task 3 — Substrate: MCPClient stdio Tool retention + toolCatalog()
- Extend `MCPClient` with `private var toolDefinitions: [String: Tool]` populated from each helper's `tools/list` response.
- Add `MCPClient.toolCatalog() -> [ToolSchema]` re-encoding `Tool.inputSchema: Value` to bytes; degrade missing descriptions with placeholder.
- Update `shutdown()` to clear `toolDefinitions` (lifecycle parity).
- Import `AgentCore` for `ToolSchema` (asymmetric dep already declared in Package.swift).
- **Done:** MCP package builds; all 86 tests pass.

### Task 4 — Substrate: AgentOrchestrator.availableToolsResolver
- Add `availableToolsResolver: (@Sendable () async -> [ToolSchema])?` init param to `AgentOrchestrator`.
- When non-nil, supersedes the static `availableTools:` array on every outer-loop iteration of `runTurnLoop`.
- Static array remains the default for tests; production wires the resolver.
- Add `test_availableToolsResolver_supersedesStaticArrayPerTurn` to AvailableToolsWiringTests.
- **Done:** all 222 AgentCore tests pass.

### Task 5 — Production fix: AppDelegate.swift:1274
- Build a `toolCatalogResolver` closure that reads from BOTH:
  - `mcpRuntime.client.toolCatalog()` (stdio helpers)
  - `inProcessToolRegistry.toolSchemas()` (memory + self-knowledge tools)
- Pass to AgentOrchestrator as `availableToolsResolver:`. Keep `availableTools: []` (the bug-flagged literal) so the parameter is still explicit at the call site, but it's superseded by the resolver per turn.
- **Done:** `bash scripts/check-app-builds.sh` PASS; all 16 standalone boundary gates PASS.

### Task 6 — Live verification (HUMAN)
- See Live Verification section in `10-02b-SUMMARY.md`. Cannot be executed by the agent because the user is at the keyboard and must type "What microphone are you using?" / "What's your build SHA?" and observe the live model response + log lines.
- **Pending:** awaits user re-verification.

## Out of scope (explicit)

- B-02: conversation continuity broken across turns. Separate diagnosis.
- B-03: HUD camera button click delivers nothing. Separate diagnosis.
- B-04: Voice input dead. Separate diagnosis.
- B-05: TTS silent. Separate diagnosis.
- Plans 10-03, 10-04, 10-05 work.
- Reordering install tasks (the resolver pattern obsoletes the need).

## Verification gates

- [x] InProcessTool protocol extended with `toolDescription`
- [x] All 7 InProcessTool implementations updated with descriptions
- [x] `InProcessToolRegistry.toolSchemas()` added
- [x] `MCPClient.toolCatalog()` added (stdio path, comprehensive)
- [x] `AgentOrchestrator.availableToolsResolver` init param added
- [x] `App/AppDelegate.swift:1274` no longer constructs the orchestrator with a stranded empty catalog
- [x] Regression test asserts the tool array reaches the provider
- [x] `swift test --package-path packages/MCP` PASS (86/86)
- [x] `swift test --package-path packages/AgentCore` PASS (222/222, 1 skipped pre-existing)
- [x] `bash scripts/check-app-builds.sh` PASS
- [x] All 16 standalone boundary gates PASS
- [x] `10-02b-PLAN.md` and `10-02b-SUMMARY.md` written
- [x] All commits atomic and conventional-commit-style (no `--no-verify`)
- [ ] **HUMAN:** Live re-verification of AC-05 ("What microphone are you using?")

## Dependencies on follow-up

After live verification confirms the fix:
1. Update `.planning/phases/10-self-awareness-diagnostics/10-02-SUMMARY.md` AC-05 from FAIL → PASS retroactively.
2. Re-evaluate Plans 10-03/04/05 sequence in light of the substrate now actually producing tool calls.
