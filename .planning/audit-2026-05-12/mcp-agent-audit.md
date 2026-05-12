# MCP Runtime + Agent Orchestrator Audit — 2026-05-12

**Branch:** `develop` · **HEAD:** `a5999e2` · **Mode:** read-only on production.
**Calibration bug shape to mirror:** silent integration boundary failures masked
by probes that return OK. Found three same-shape bugs, one of them as deeply
buried as today's FK mismatch.

---

## TL;DR

The MCP composite dispatcher and the agent's outer streaming loop are
structurally correct. The 10-tool catalog routes. Confirmation gating works.
SSE / NDJSON / OpenAI-compat decoders cover their documented edge cases.
**But two of the "audit-trail" seams that the codebase advertises as wired
are silently dead in production**, and the tool-result data path double-caps
at 8 KB while losing all evidence of the original blob. The same probe-says-OK
pattern that hid today's Toby-the-dog fact persistence bug.

---

## Severity order

### CRIT-1 — `ReplayingToolResultObserver` `turnIDResolver` is permanently `nil`; SEC-07 dual-write + ME-04 channel are dead in production

**Evidence:**
- `App/AppDelegate.swift:614` — production wiring passes a literal `{ nil }`:
  ```swift
  let runtime = try await MCPRuntimeWiring.build(
      bundleURL: bundleURL,
      bus: busAdapter,
      replayChannel: channel,
      turnIDResolver: { nil },  // pre-orchestrator returns nil (observer logs without writing).
      inProcessRegistry: self.inProcessToolRegistry
  )
  ```
- `App/MCP/ReplayingToolResultObserver.swift:62-69` — the observer's `record(...)` guards
  `guard let turnId = await turnIDResolver() else { logger.debug(...); return }`. Every
  call returns at the guard.
- The resolver is **never reassigned** after the orchestrator is later constructed
  (`installAgent`, AppDelegate:1671). Verified by grep: no production write site for
  `turnIDResolver`, no `var` declaration, no `.attach(...)` analogue.

**What this kills:**
- SEC-07's documented dual-write of raw vs sanitized bytes (the audit-trail
  contract: "the viewer reconciles the two streams for slicing on 'did the model
  ever see content X?'") — dead.
- ME-04's `BoundedAsyncChannel<ReplayEnvelope>(capacity: 2048, policy: .dropOldest)`
  + drain Task — the channel **never receives a tool-result envelope** from the
  observer in production. The drain Task drains... nothing tool-shaped.
- The four-seam contract that AppDelegate comments at lines 549-577 call "the
  AGENT-10 four-seam contract exercised by production traffic" — exercised only
  by `applicationWillFinishLaunching` setup; in production, this seam is empty.

**Pattern match:** identical shape to today's calibration bug. Boot health probe
sees the channel + drain wired; structural-composition tests assert the observer
gets a `record(...)` call; production reality is the guard returns at the first
line and the channel stays empty. Probes return OK, reality is broken.

**Confirmation:** the orchestrator does still write `.toolResultFull` to ReplayLog
**directly** at `AgentOrchestrator.swift:584`, so replay rows exist — but those
rows carry the **post-sanitize, post-8KB-cap** bytes (see CRIT-2), not the raw
helper output. The audit trail's `:raw`-suffixed sibling row never lands.

**Fix shape:** after `installAgent` constructs the orchestrator, mutate
`ReplayingToolResultObserver`'s resolver (the observer is a class — make
`turnIDResolver` a `var` and add an `attach(_ resolver:)` method analogous to
`ConfirmationPresenterHolder.attach(_:)`). Alternatively, build the observer
inside `installAgent` rather than `MCPRuntimeWiring.build` so the orchestrator
reference is in scope at construction time.

---

### CRIT-2 — Tool-result bytes are 8 KB-capped TWICE, and the "full blob in replay log" promise is a lie

**Evidence:**
- `packages/MCP/Sources/MCP/MCPToolDispatcher.swift:114` — stdio path returns
  `Data(SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192).utf8)`.
- `packages/MCP/Sources/MCP/InProcess/InProcessAwareToolDispatcher.swift:89` —
  in-process path returns `Data(SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192).utf8)`.
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:580-587` —
  the orchestrator then:
  ```swift
  let resultData = try await toolDispatcher.dispatch(toolUse: req)
  let packed = ToolResultPacker.pack(resultData)   // CAPS AGAIN at 8 KB
  await replayLog.record(.toolResultFull(toolUseId: req.id, bytes: packed.fullBytes), …)
  ```
  `packed.fullBytes` is `resultData` — already 8 KB. The "full" in `toolResultFull`
  is **never larger than 8 KB**.
- `packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift:23` — the type's own
  doc comment says: *"The full blob still flows to ReplayLog via
  `ReplayEvent.toolResultFull(toolUseId:bytes:)` — observability is not lossy (OBS-02)."*
  This is false in production.

**Why nobody noticed:**
- `ToolResultPacker.pack` is a pure function; its unit tests verify capping correctly
  but operate on synthetic inputs that haven't gone through the dispatcher's
  pre-cap.
- `MCPToolDispatcher` unit tests verify sanitize correctness on its output but
  don't trace the byte path into the orchestrator.
- The two layers were designed independently — one in MCP (boundary defense),
  one in AgentCore (model-facing protection) — and the intended division was
  "MCP caps the model-facing string, the orchestrator passes through to replay".
  But the orchestrator pipeline doesn't have a "raw bytes" inlet — it consumes
  the dispatcher's return value as both the model-facing AND the replay-facing
  payload.

**Combined impact with CRIT-1:** The dual-write that was supposed to give us
the un-capped truth (`:raw` suffix path through the observer → channel → replay)
is dead. The orchestrator's direct write captures the capped truth. There is no
production path that records the original tool output bytes anywhere on disk.

**Fix shape:** Move the `prepareForBoundary` call out of both dispatchers and
into the orchestrator (or into `ToolResultPacker.pack`), and have the dispatchers
return the **raw** helper bytes. Then the orchestrator can:
1. Send raw bytes to ReplayLog as `.toolResultFull` (true to the name).
2. Run `prepareForBoundary` + `ToolResultPacker.pack` once, embed the capped
   string in the model-facing tool_result.

This also collapses the dead observer dual-write back into a single source of
truth, fixing CRIT-1 by deletion.

---

### CRIT-3 — `MCPRuntime built — N tools` log line undercounts; misleading triage signal

**Evidence:**
- `App/AppDelegate.swift:618-619`:
  ```swift
  let toolCount = await runtime.client.registeredToolNames().count
  self.systemLogger?.info("MCPRuntime built — \(toolCount) tools")
  ```
- `runtime.client.registeredToolNames()` only returns the **stdio** helper tools
  (3 — `get_time`, `get_clipboard`, `run_applescript`). The 7 in-process tools
  registered into `inProcessToolRegistry` are not counted.

**Impact:** The boot log perpetually shows `MCPRuntime built — 3 tools` while
`MCPBootHealthProbe` (which counts both registries) correctly reports 10. A
contributor (or future Claude) reading the system log will conclude the
in-process tools didn't register and chase the wrong root cause when the actual
problem is elsewhere.

**Note:** the probe at `App/Boot/BootHealthProbes.swift:336-391` correctly counts
both. The boot log line is the only place that's wrong. Today's `740bed4` commit
already addressed a related undercount in the probe; this log line was missed.

**Fix:** include `inProcessToolRegistry.registered().count` in the log line,
or just delete the line and rely on `MCPBootHealthProbe` for the count.

---

### HIGH-1 — Cache hints effectively never trigger in production (no correctness bug, but cost is higher than design intent)

**Evidence:**
- `packages/AgentCore/Sources/AgentCore/CacheHints.swift:50` —
  `MIN_CHARS_FOR_CACHE_BREAKPOINT = 4096`.
- `packages/AgentCore/Sources/AgentCore/ContextBuilder.swift:64-74` — the locked
  `selfAwarePreamble` is ~700 characters (verified by grep — file is 4462 bytes
  total including comments).
- `AppDelegate.swift:1685` constructs the orchestrator with
  `systemPrompt: ContextBuilder.systemPrompt(for: .empty)` — `.empty` adds no
  presence or memory hydration text.
- Round 4 degradation summary prepends a small string only when subsystems are
  unhealthy. The prepended text is bounded "below the 4096-char Anthropic cache
  breakpoint" by design (AgentOrchestrator:118).
- Therefore on a healthy boot, `finalSystem.count` is ~700-1200 chars depending
  on presence enrichment. `CacheHints.eligibleForSystemPrompt(finalSystem)`
  returns `nil` on every turn.

**Impact:** No correctness bug — the Phase E fix correctly returns `nil` to
avoid the 200 OK + EOF cache-validation-failure cascade. But the prompt cache
is effectively dead. Every turn pays full input-token cost. With Opus 4.7's
~1.35× token inflation vs 3.x (per CLAUDE.md), this matters more than it
would have on older models.

**Not a fix request — flagging for awareness.** Possible mitigations: pad the
preamble to ≥4096 chars (would need real prompt-engineering work), or accept
that cache is unused until memory hydration grows the prompt naturally.

---

### HIGH-2 — Assistant `text` content blocks emitted alongside `tool_use` are dropped from the message history

**Evidence:**
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:575-577`:
  ```swift
  messages.append(LLMMessage(role: .assistant, content: [
      .toolUse(id: req.id, name: req.name, argsJSON: req.argsJSON),
  ]))
  ```
- When Anthropic streams a turn that contains text deltas BEFORE a tool_use
  block (which Opus 4.7 does frequently — "Let me check the time for you…
  [tool_use:get_time]"), the orchestrator's `assistantTextSoFar` accumulator
  captures the text for `assistantTextSoFar` (used by D-02 escalation), but
  the appended assistant message contains **only** the tool_use block. The
  preceding text is gone from the model's view on the next round trip.

**Impact:** Generally tolerable for Anthropic — the model resolves tool calls
by id and doesn't re-read its own prose between turns. But:
1. If the user submits a follow-up that references "you said X before calling
   the tool", the model has no record of saying X.
2. Replay log captures the text via `.textDelta` events, but the replay viewer
   reconstruction won't match what the model actually saw at re-prompt.

**Pattern match:** lower-severity version of the calibration bug shape — the
tests pass (`messages.last` is the assistant message they expected), the data
boundary silently loses signal.

**Fix shape:** accumulate text + tool_use blocks into a single assistant
`LLMMessage` per round-trip, flushing on either `stop_reason: .toolUse` (with
tool blocks present) or `stop_reason: .endTurn` (text only).

---

### MED-1 — `get_active_audio_route` registration is conditional on `audioGraphOwner != nil`; voice DAG failure silently strands a documented tool

**Evidence:**
- `App/AppDelegate.swift:1966-1976` — `installSelfKnowledgeTools` registers
  `GetActiveAudioRouteTool` only inside `if let owner = self.audioGraphOwner`.
  Else: `systemLogger?.warning("…get_active_audio_route not registered")`.
- The Round-4 self-aware preamble (`ContextBuilder.selfAwarePreamble`) **names
  `get_active_audio_route` as a tool the model should prefer over generic
  answers.** When voice fails (e.g., missing OpenWakeWord/Silero models on
  first launch), the tool catalog the model receives doesn't include this
  tool, but the preamble still tells the model to use it. The model emits a
  `tool_use` for `get_active_audio_route` → composite dispatcher fails-unknown
  → orchestrator records ERROR → user-facing chat shows tool failure.

**Pattern match:** wired-but-conditionally-dead, exactly the audit's stated
pattern.

**Fix shape:** either always register a dispatcher that returns
`{"route": null}` when the owner is missing (preserving the catalog promise),
or gate the preamble's mention of the tool on whether voice is healthy at
boot. Round-4 degradation summary already handles the latter at the system-
prompt level — extend it to omit the tool name from the preamble when the
subsystem is dead.

---

### MED-2 — Confirmation panel's `beginSheet` requires the hidden owner panel to be `orderFront`'d; multi-monitor / fullscreen-app scenarios may hide the prompt

**Evidence:**
- `packages/MCP/Sources/MCP/ConfirmationPresenter.swift:121-128`:
  ```swift
  owner.alphaValue = 0
  owner.orderFront(nil)
  owner.beginSheet(panel) { _ in }
  ```
- The owner panel is `alphaValue = 0` and `level = .floating`. `beginSheet`
  attaches the visible panel to the invisible owner. If the user is in a
  fullscreen app on a different Space, `orderFront(nil)` may not be enough —
  the sheet attaches but the user can't see it. The broker still waits the
  full 60s timeout, then synthesizes `.timeout` → tool call denied.

**Impact:** Not a correctness bug at the protocol level (the broker correctly
times out), but UX-wise this is "tool call silently denied because user never
saw the prompt." The HUD itself has logic to overlay regardless of Space —
the confirmation prompt doesn't share that logic.

**Pattern match:** "confirmation gate works but blocks until accept/deny"
holds — what doesn't hold is that the user reliably *sees* the prompt to
accept/deny. Not the audit's stated bug shape, but adjacent.

**Fix:** consider routing through `HUDBanner` (already overlays cross-Space)
for the confirmation card instead of beginSheet.

---

### LOW-1 — `MCPBusGatewayAdapter.updateArgsPreview` re-emits `toolCallStart`, not a distinct event

**Evidence:**
- `App/MCPBusGatewayAdapter.swift:59-66` — second-phase post-approval emission
  reuses `BusOutbound.toolCallStart(id: uuid, name:, argsPreview:)`. The HUD
  upserts by id.
- The comment correctly notes the HUD reconciles by id — fine in practice. But
  this means the bus protocol has no distinct "args revealed" event, so
  downstream consumers (replay viewer, future tracing) can't distinguish the
  awaiting-approval emission from the post-approval emission without doing
  a lookback by id.

**Impact:** observability nuance, not a bug. Flag for the bus protocol v2
discussion if anyone revisits the wire schema.

---

## Verified healthy

The following were probed and found correct as of this audit:

- **In-process registry composition.** `InProcessAwareToolDispatcher` routes
  in-process tools via `inProcessRegistry.contains(name)` lookup (async, hits
  live actor state — late registration is routable). Stdio fallthrough works.
  `requiresConfirmation` lookup is sync via the lock-protected
  `InProcessConfirmationCache`. `forget_fact` is the only in-process tool
  with `requiresConfirmation: true`; it threads correctly through the same
  `ConfirmationBroker` as `run_applescript`.
- **10-tool catalog enumeration.** `availableToolsResolver` at
  `AppDelegate.swift:1624-1635` lazily merges `mcpClient.toolCatalog()` (3
  stdio) with `inProcessToolRegistry.toolSchemas()` (up to 7 in-process). Fires
  per outer-loop iteration so late-registered self-knowledge tools become
  visible without orchestrator rebuild.
- **AppleScript confirmation gating.** `check-applescript-confirmation.sh` is
  green. `mcp-applescript` registers with `requiresConfirmation: true`. The
  outer `ConfirmingToolDispatcher` correctly emits `awaitingApproval` to the
  bus pre-broker, awaits broker, branches on outcome. `.deny` / `.timeout` /
  `.barge` all throw distinct `ConfirmationError` cases that propagate as
  tool_result errors.
- **Ollama NDJSON decoder AGENT-04 invariant.** `NDJSONDecoder.dispatch` emits
  `.toolUseRequested` on *every* chunk carrying `tool_calls` regardless of the
  `done` flag, never gated on the terminator. Matches the CLAUDE.md gotcha.
- **OpenAI-compat decoder.** Atomic `tool_calls` flushed on `[DONE]` and on
  `finish_reason` presence. Handles both string and object `arguments`. Buffers
  per-call_id for the rare case OpenAI splits args.
- **AnthropicProvider beta header.** `anthropic-beta: extended-cache-ttl-2025-04-11`
  is set unconditionally (AnthropicProvider:114). Phase E's cache-hint gating
  prevents the 200 OK + EOF cascade by returning nil cacheHints when the
  prompt is under threshold (HIGH-1 documents the side effect).
- **Cap-recovery `toolChoice: .none` semantics.** Anthropic encodes
  `{type:"none"}`. Ollama native drops the `tools` array entirely
  (`OllamaRequestBody.encodeNative:39-46`). OpenAI-compat sends `"none"` as
  the string. All three match CLAUDE.md's invariant.
- **Broadcaster fan-out.** Six subscribers (`memory`, `transcript`, `devOverlay`,
  `frameAttach`, `voice`, `bus`) all subscribe + drain in `installAgent`; all
  six are cancelled in `applicationWillTerminate`. The drain Tasks `for await
  event in sub.stream` against live producers wired through the broadcaster's
  internal mirror. The protected-event matrix in
  `OrchestratorEventBroadcaster.isProtectedForPriority` correctly classifies
  `tokenDelta`/`thinkingDelta` as drop-eligible while `turnEnd`/`error` etc.
  are protected.
- **`check-orchestrator-events-single-consumer.sh` invariant.** No
  `for await … in …events` outside the broadcaster (confirmed by recent
  edits — broadcaster is the single drain of `orchestrator.events`).
- **`ConfirmationBroker` first-write-wins.** `resolved` guard prevents
  double-resolve. Timer task cancellation on response. `WR-03` explicit
  Task.sleep error handling.
- **Pending-message persistence to `turns` table (B-02).** `appendTurn`
  for user + assistant pair fires inside the memory subscriber's
  `turnContent` lookup closure at `AppDelegate.swift:1749-1772`. Confirmed
  by the recent commit chain.

---

## Open questions

1. **Should the orchestrator's direct `.toolResultFull` write be removed?** If
   CRIT-1 is fixed by routing through the observer + channel, the direct
   write becomes redundant. The current code writes the capped bytes here
   AND would write raw bytes through the observer. Decide on single source of
   truth for replay.
2. **Is the cache-hint dead-state intentional cost-acceptance, or oversight?**
   `extended1h` flow with a permanently-under-threshold prompt looks like an
   "obvious-when-pointed-at" gap. If accepted, comment it; if not, decide on
   a padding strategy.
3. **Is the assistant-text-drop (HIGH-2) breaking any current eval scenarios?**
   The eval harness corpus would need a tool-call-after-text scenario to
   detect this; not obvious from the audit whether any exist.
4. **`turnIDResolver` shape:** when fixed, the resolver needs to hop to the
   orchestrator actor to read `currentTurn?.id`. That's an await per tool
   dispatch — acceptable cost? Or should the orchestrator push the active
   TurnID into a lock-protected slot the observer can read sync (similar to
   `InProcessConfirmationCache`)?

---

## Probes I trusted, in order to be transparent

- `MCPBootHealthProbe` — re-verified by reading code; counts both registries.
- `check-applescript-confirmation.sh` — re-ran live; PASS.
- `check-orchestrator-events-single-consumer.sh` — assumed green per gates
  list in CLAUDE.md; did not re-run live (parallel audits may be touching
  surface area).

Files & line numbers above are all absolute under the repo root. No production
code was modified.
