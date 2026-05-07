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
  - phase: 5-mcp (Plans 05-01..05-05)
    provides: "MCPClient + stdio helper registration."
  - phase: 7-memory-vision (Plans 07-03 / 07-06)
    provides: "InProcessToolRegistry actor + memory tools."
provides:
  - "Tool catalog wiring from runtime registry (stdio + in-process) into AgentOrchestrator → LLMProvider request body."
  - "Substrate that retroactively unblocks AC-05 of Plan 10-02 (live re-verification pending)."
affects: [10-02 AC-05 retroactive PASS, all future tool-call-dependent verification]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Lazy resolver closure (@Sendable () async -> [ToolSchema]) for the orchestrator's tool catalog — supersedes the static array on every outer turn iteration."
    - "MCPClient retains stdio Tool definitions in toolDefinitions: [String: Tool] alongside toolToServer (parity in shutdown())."
    - "Asymmetric module dep already in place: JarvisMCP imports AgentCore for ToolSchema; AgentCore stays MCP-agnostic."

key-files:
  created:
    - "packages/AgentCore/Tests/AgentOrchestratorTests/AvailableToolsWiringTests.swift — 3 test cases at the orchestrator → provider boundary"
    - "packages/MCP/Tests/MCPTests/InProcessToolRegistrySchemasTests.swift — 1 test case for registry projection"
    - ".planning/phases/10-self-awareness-diagnostics/10-02b-PLAN.md"
  modified:
    - "packages/MCP/Sources/MCP/InProcess/InProcessTool.swift — added var toolDescription { get } protocol member"
    - "packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift — added toolSchemas() (imports AgentCore)"
    - "packages/MCP/Sources/MCP/InProcess/{ListAudioDevicesTool,GetActiveAudioRouteTool,GetSelfStateTool,ListCameraDevicesTool,SearchMemoryTool,ForgetFactTool,SearchConversationTool}.swift — toolDescription values"
    - "packages/MCP/Sources/MCP/MCPClient.swift — toolDefinitions cache, toolCatalog() projection, shutdown() parity"
    - "packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift — availableToolsResolver: (@Sendable () async -> [ToolSchema])? init param + per-turn resolution"
    - "App/AppDelegate.swift — line 1274 no longer constructs with a stranded empty catalog; resolver wires both stdio + in-process catalogs"

key-decisions:
  - "D-B01-1: lazy resolver supersedes install-task reordering — the locked install order (installMemory → installVision → installAgent → installVoice → installSelfKnowledgeTools) places self-knowledge registration AFTER orchestrator construction; the resolver fires once per outer turn iteration so the catalog refreshes by the time the user submits."
  - "D-B01-2: protocol member named `toolDescription` (not `description`) to avoid CustomStringConvertible collision."
  - "D-B01-3: comprehensive — both stdio (get_time/get_clipboard/run_applescript) AND in-process (memory + self-knowledge) tools wire through the same resolver; deferring stdio would have left 3 tools still hallucinated."
  - "D-B01-4: missing helper descriptions degrade with placeholder rather than dropping the tool from the catalog."

requirements-completed: []  # B-01 is a substrate bug, not a SPEC requirement.

# Metrics
duration: ~50min
completed: 2026-05-07
---

# Phase 10 Plan 02b: Substrate fix B-01 — wire availableTools from runtime catalog

**One-liner:** AgentOrchestrator construction at AppDelegate.swift:1274 now sources its tools[] catalog from a runtime resolver reading both `MCPClient.toolCatalog()` (stdio helpers) and `InProcessToolRegistry.toolSchemas()` (memory + self-knowledge), unblocking every previously-silenced tool call.

## Performance

- **Duration:** ~50 min (test stub → protocol/registry → MCPClient catalog → orchestrator resolver → AppDelegate wiring → boundary gates → SUMMARY)
- **Started:** 2026-05-07T07:15Z
- **Completed:** 2026-05-07T08:05Z
- **Tasks:** 5 of 6 executed (Task 6 is the human-verify gate)
- **Files modified:** 12 (4 created, 8 edited) + 1 produced and 1 in-progress (.planning artifacts)

## Accomplishments

- **Bug B-01 root cause confirmed and fixed.** `App/AppDelegate.swift:1274` constructed `AgentOrchestrator(... availableTools: [])` with a hardcoded empty array. The model received the system-prompt preamble naming tools but had no schemas in the API `tools[]` payload, so it hallucinated JSON tool definitions into chat instead of dispatching real `tool_use` blocks. Same bug silenced every tool call across the agent: get_time, get_clipboard, run_applescript, search_memory, forget_fact, search_conversation, vision tools, and the four Phase 10-01 self-knowledge tools.

- **Substrate added at 4 layers:**
  1. `InProcessTool` protocol gains `var toolDescription: String { get }` so each in-process tool surfaces a one-line description to the model. All 7 production tools updated with calibrated descriptions that drive correct tool selection (e.g., `list_audio_devices`: "Lists every audio I/O device on the user's Mac (one entry per direction — inputs and outputs as separate rows). Each entry includes name, UID, sample rate, channel count, default-device flag, and active flag. Call this tool when the user asks about microphones, speakers, headphones, or audio devices in general — never speculate or tell them to open System Settings.").
  2. `InProcessToolRegistry.toolSchemas() -> [ToolSchema]` projects every registered in-process tool to the AgentCore ToolSchema shape, name-sorted for prompt-cache stability.
  3. `MCPClient` retains the full `Tool` definitions returned by each helper's `tools/list` response (previously only `toolToServer` survived). New `toolCatalog() -> [ToolSchema]` re-encodes `Tool.inputSchema: Value` (the SDK's JSON-encodable wrapper) to bytes; missing descriptions degrade to a placeholder rather than dropping the tool.
  4. `AgentOrchestrator` gains `availableToolsResolver: (@Sendable () async -> [ToolSchema])?` init param. When non-nil, supersedes the static `availableTools:` array on every outer-loop iteration of `runTurnLoop`. Static array remains for tests; production wires the resolver.

- **Production fix applied at App/AppDelegate.swift:1274.** The orchestrator now receives a resolver closure that reads from both `mcpRuntime.client.toolCatalog()` and `inProcessToolRegistry.toolSchemas()`, merging the catalogs at turn time. The locked install order (installMemory → installVision → installAgent → installVoice → installSelfKnowledgeTools) is preserved — the resolver pattern obsoletes the install-time coupling.

- **Regression coverage at the right layer.** The pre-existing `registersFourSelfKnowledgeTools` test asserted at the registry layer (which was always correct); it could not catch the bug because the bug lived two layers away at the orchestrator constructor's `availableTools:` argument. The new `AvailableToolsWiringTests` asserts at the orchestrator → provider boundary, including a resolver test that pins down per-turn refresh semantics.

## Task Commits

Each task committed atomically:

1. **Task 1 (RED): AvailableToolsWiringTests regression** — `260350b` (test)
2. **Task 2 (GREEN substrate): toolDescription + toolSchemas()** — `c5c5072` (feat)
3. **Task 3 (GREEN substrate): MCPClient toolCatalog()** — `043402c` (feat)
4. **Task 4 (GREEN substrate): availableToolsResolver init param** — `3eeb3c1` (feat)
5. **Task 5 (production fix): AppDelegate runtime-catalog wiring** — `e0c0310` (fix)
6. **Task 6 (HUMAN-VERIFY):** PENDING — see Live Verification section below.

**Plan metadata commit:** _to be created_ (this SUMMARY.md + 10-02b-PLAN.md).

## Files Created/Modified

### Created
- `packages/AgentCore/Tests/AgentOrchestratorTests/AvailableToolsWiringTests.swift` — 3 cases asserting orchestrator → provider boundary tool catalog flow.
- `packages/MCP/Tests/MCPTests/InProcessToolRegistrySchemasTests.swift` — 1 case asserting all 7 in-process tools project to non-empty ToolSchemas.
- `.planning/phases/10-self-awareness-diagnostics/10-02b-PLAN.md`

### Modified
- `packages/MCP/Sources/MCP/InProcess/InProcessTool.swift` — added `var toolDescription: String { get }`.
- `packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift` — added `toolSchemas() -> [ToolSchema]`; imports AgentCore.
- `packages/MCP/Sources/MCP/InProcess/ListAudioDevicesTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/GetActiveAudioRouteTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/GetSelfStateTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/ListCameraDevicesTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/ForgetFactTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/InProcess/SearchConversationTool.swift` — `toolDescription`.
- `packages/MCP/Sources/MCP/MCPClient.swift` — `toolDefinitions` cache, `toolCatalog()`, `shutdown()` parity, AgentCore import.
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` — `availableToolsResolver:` init param + per-turn resolution at runTurnLoop:351.
- `App/AppDelegate.swift` — line 1274: orchestrator constructed with `availableToolsResolver: toolCatalogResolver` reading from both `MCPClient.toolCatalog()` and `InProcessToolRegistry.toolSchemas()`.

## Decisions Made

- **D-B01-1 (resolver over reorder):** Preferred a lazy resolver closure over reordering install tasks. The chain `installMemory → installVision → installAgent → installVoice → installSelfKnowledgeTools` is locked by `scripts/check-install-order.sh`, and reordering would risk breaking the orchestrator-needs-visionRouter / voice-needs-orchestrator dependencies. The resolver fires once per outer-loop iteration in `AgentOrchestrator.runTurnLoop`, so by the time the user submits the catalog is fully populated even though `installSelfKnowledgeTools` runs AFTER the orchestrator constructor.
- **D-B01-2 (toolDescription not description):** Named the new `InProcessTool` protocol member `toolDescription` (not `description`) to avoid colliding with `CustomStringConvertible.description`. A protocol-default `description` requirement on a value type would silently override the conformance and feed the model the type's `String(describing:)` form instead.
- **D-B01-3 (comprehensive — both stdio and in-process):** Wired both stdio helpers (`get_time` / `get_clipboard` / `run_applescript`) AND in-process tools (memory + self-knowledge) through the same resolver. Deferring stdio to a follow-up B-01b would have shipped the fix with 3 of the user's most-used tools still hallucinated.
- **D-B01-4 (placeholder over drop):** Missing stdio-helper descriptions degrade with `"MCP tool '<name>' (no description provided by helper)."` rather than getting dropped from the catalog. Dispatch still works; the model just loses the when-to-call signal for that one tool.

## Deviations from Plan

### Auto-fixed Issues

None. The plan was a single surgical fix authored by the executor; no upstream-plan deviations applicable. The four substrate-layer changes (protocol member, registry projection, MCPClient catalog, orchestrator resolver) were each scoped to enable the production fix without touching unrelated code.

**Total deviations:** 0.
**Impact on plan:** No scope creep; B-02..B-05 explicitly out of scope and untouched.

## Issues Encountered

- None at the code level. The 222-test AgentCore suite + 86-test MCP suite both pass after the substrate changes.
- One test of B-01-resolver case used a `var schemas` captured by `@Sendable` closure pattern that would fail Swift 6 strict-concurrency; refactored to an `actor CatalogHolder` so the resolver closure captures only the actor reference. (Caught at code-write time, not at compile time — fixed before the first test invocation.)

## Threat Mitigation

- **T-B01-PROMPT-CACHE:** mitigated. The resolver returns name-sorted catalogs (both `MCPClient.toolCatalog()` and `InProcessToolRegistry.toolSchemas()` sort by name internally). Stable ordering matters because Anthropic's prompt cache hashes the encoded request body; an unstable tools-array order would invalidate cached system prompts on every turn. The resolver does NOT mutate tool order across turns at runtime — registration order on the registry is reflected in the sort, but new registrations between turns simply add to the sorted output deterministically.
- **T-B01-EMPTY-CATALOG-REGRESSION:** mitigated. The new `AvailableToolsWiringTests` asserts at the orchestrator → provider boundary that schemas reach the provider's `stream(... tools:)` call. Any future regression that strands the orchestrator with an empty catalog (e.g. someone "improving" the AppDelegate construction site again) will be caught at the layer that contains the bug, not at a registry-internal layer. The pre-existing `registersFourSelfKnowledgeTools` test was at the wrong layer; B-01 escaped because the registry was correctly populated.
- **T-B01-DESCRIPTION-DRIFT:** partially mitigated. `InProcessToolRegistrySchemasTests` asserts all 7 in-process tools have non-empty descriptions. There is no equivalent gate forcing description quality (e.g., "must mention when to call"); that quality control is implicit in the descriptions checked into the source files and reviewed at write time. A future Plan 10-x could add a description-style linter if the model selection reliability requires it.

## Live Verification (D-26 / SPEC AC-13)

> **Status: PENDING — checkpoint awaiting human verification.** Substrate changes (Tasks 1-5) are committed; commits `260350b`, `c5c5072`, `043402c`, `3eeb3c1`, `e0c0310` are present in `git log`. Live re-test of AC-05 requires a human at the keyboard.

### Pre-checks (executor-verified)

- [x] `swift test --package-path packages/AgentCore` PASS (222 tests, 1 pre-existing skipped)
- [x] `swift test --package-path packages/MCP` PASS (86 tests)
- [x] `bash scripts/check-app-builds.sh` PASS at HEAD `e0c0310`
- [x] All 16 standalone boundary gates exit 0 at HEAD (`check-bus-harness-parity.sh`, `check-bus-protocol-version.sh`, `check-corpus-secrets.sh`, `check-embedding-dim-literal.sh`, `check-install-order.sh`, `check-no-evaluate-javascript.sh`, `check-no-leftover-stubs.sh`, `check-no-modal-presentation.sh`, `check-no-null-voice-adapters.sh`, `check-orchestrator-events-single-consumer.sh`, `check-presence-bus-no-tts-orchestrator.sh`, `check-presence-vision-isolation.sh`, `check-single-memory-mutated-emit.sh`, `check-single-memory-used-emit.sh`, `check-single-writer-hudstate.sh`, `check-vision-isolation.sh`)

### Reset (D-28)

**N/A — Plan 10-02b modifies orchestrator wiring + tool-catalog plumbing only; no hardware capture surface touched.** Per D-28 guidance, no `tccutil reset` required. Existing Microphone / Camera / Screen Recording grants carry forward unchanged.

### Relaunch (HUMAN STEP)

```bash
cd /Users/james.maes/Git.Local/Kof22/Jarvis
bash scripts/check-app-builds.sh && open build/Build/Products/Debug/Jarvis.app
```

- **Build artifact:** `build/Build/Products/Debug/Jarvis.app` from commit `e0c0310`.
- **Tail the log channel** in a second terminal so we can see tool calls land:
  ```bash
  log stream --predicate 'subsystem == "com.koftwentytwo.jarvis"' --style compact \
    | grep -E "(tool_use|tool_result|get_active_audio_route|get_self_state|list_audio_devices|list_camera_devices|get_time|get_clipboard|search_memory|installSelfKnowledgeTools|installAgent: deps not ready|MCPRuntime built)"
  ```

### Live model behavior tests (HUMAN STEPS)

Once Jarvis is up and the HUD is responsive, type into the chat panel:

#### Test 1 (AC-05 retroactive): "What microphone are you using?"

- **Type verbatim:** `What microphone are you using?`
- **Expected behavior A — tool call:** Within ~500 ms the log tail shows a `tool_use` entry naming `get_active_audio_route` (the model may also call `list_audio_devices` first to enumerate, then `get_active_audio_route`, depending on its prompt-strategy choice — both are correct). NO JSON-blob hallucination should appear in the chat panel.
- **Expected behavior B — answer content:** The reply names the actual device returned by the tool (e.g., `MacBook Pro Microphone`, your headset name, etc.). Cross-check against `system_profiler SPAudioDataType | grep -A2 "Default Input Device:"` — the tool reads the live AudioGraph route, which may differ from the system default if you've explicitly bound a different device in Voice settings.
- **NOT acceptable:**
  - `I'll check that for you. {"name": "get_active_audio_route", "arguments": {}}` (the pre-fix B-01 hallucination)
  - "Open System Settings to see your microphone"
  - "I don't have access to your hardware"
  - "I'm a text-based assistant"

> **Capture:** paste the verbatim user question, the verbatim model response, AND the matching log line(s) into the **Observed** block below.

#### Test 2 (sanity): "What time is it?"

- **Type verbatim:** `What time is it?`
- **Expected behavior — tool call:** log shows `tool_use` for `get_time` (a stdio helper that ALSO went silent under B-01). Reply contains the current time.
- **NOT acceptable:** Reply with the model's training-time stale "current time" or any `{"name": "get_time", ...}` JSON blob in the chat.

> **Capture:** verbatim question + reply + log line.

#### Test 3 (sanity): "What model are you running?"

- **Type verbatim:** `What model are you running?`
- **Expected behavior — tool call:** log shows `tool_use` for `get_self_state`. Reply names `claude-opus-4-7` (or `qwen2.5-coder:32b` if you've toggled to Ollama provider) along with provider, build mode, and uptime.
- **NOT acceptable:** A speculative answer that doesn't call `get_self_state`.

> **Capture:** verbatim question + reply + log line.

### Observed (HUMAN FILLS)

```
<HH:MM:SS>  USER:    What microphone are you using?
<HH:MM:SS>  TOOLUSE: get_active_audio_route { ... }       <-- log line proving tool call
<HH:MM:SS>  JARVIS:  <verbatim response — should name the device>

<HH:MM:SS>  USER:    What time is it?
<HH:MM:SS>  TOOLUSE: get_time { ... }
<HH:MM:SS>  JARVIS:  <verbatim response>

<HH:MM:SS>  USER:    What model are you running?
<HH:MM:SS>  TOOLUSE: get_self_state { ... }
<HH:MM:SS>  JARVIS:  <verbatim response — should name claude-opus-4-7>
```

### Acceptance match

- **AC-05 (Plan 10-02 retroactive):** PENDING. After Test 1 PASSes, edit `.planning/phases/10-self-awareness-diagnostics/10-02-SUMMARY.md` to flip AC-05 from FAIL → PASS, citing this 10-02b commit chain as the unblocking substrate fix.
- **B-01:** PENDING live verification. Code-level fix complete; awaits human re-test.

### Carry-forward bugs (NOT Plan 10-02b scope)

- **B-02** Conversation continuity broken — separate diagnosis still required.
- **B-03** HUD camera button click delivers nothing — separate diagnosis.
- **B-04** Voice input dead — separate diagnosis.
- **B-05** TTS silent — separate diagnosis.

These remain on the punch list. Plan 10-02b deliberately scoped to B-01 only.

## Self-Check: PASSED

- File `.planning/phases/10-self-awareness-diagnostics/10-02b-PLAN.md` exists.
- File `.planning/phases/10-self-awareness-diagnostics/10-02b-SUMMARY.md` exists.
- File `packages/AgentCore/Tests/AgentOrchestratorTests/AvailableToolsWiringTests.swift` exists.
- File `packages/MCP/Tests/MCPTests/InProcessToolRegistrySchemasTests.swift` exists.
- Commit `260350b` (Task 1 RED test) present in `git log`.
- Commit `c5c5072` (Task 2 protocol + registry) present in `git log`.
- Commit `043402c` (Task 3 MCPClient catalog) present in `git log`.
- Commit `3eeb3c1` (Task 4 orchestrator resolver) present in `git log`.
- Commit `e0c0310` (Task 5 AppDelegate fix) present in `git log`.
- Task 6 (Live Verification) intentionally PENDING per checkpoint protocol.

---
*Phase: 10-self-awareness-diagnostics*
*Plan: 10-02b (substrate fix B-01 — availableTools wiring)*
*Completed: 2026-05-07 (pending human verification on Task 6)*
