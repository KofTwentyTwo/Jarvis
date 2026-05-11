# Handoff — Rounds 2 & 3 (Boot Health + Status Menu)

**Session date written:** 2026-05-11
**Last commit:** `8d0a959` (qwen3.6 extractor + q8_0 agent-loop split)
**Branch:** `develop`, pushed
**Context this session ran low; Rounds 2 & 3 deferred to a fresh session.**

---

## What landed today (do not redo)

- **`cb584a2` feat(d5d6)** — `jkrukowski/SQLiteVec` SPM dep adopted; sqlite-vec v0.1.6 statically linked via `CSQLiteVec.core_vec_init()` auto-extension; `MemoryStore.init` is now load-bearing; `installMemory` hard-fails at boot via `TCCAlertService.presentHardBlock` + `NSApp.terminate`; new `get_memory_stats` in-process MCP tool registered alongside the other Self-knowledge tools.
- **`8d0a959` feat(model)** — Memory extractor default flipped to `qwen3.6:latest`; agent-loop Ollama fallback is now `qwen2.5-coder:32b-instruct-q8_0`. Both models already on the user's machine — no pulls required.
- **Live verification** — fresh launch with empty jarvis.db creates schema; B-02 multi-turn context works ("what breed is toby?" → "Golden Retriever"); `get_memory_stats` returns real counts; vec_version `v0.1.6`, sqlite_version `3.51.0`.

## Why Rounds 2 & 3 exist

The user's exact ask (verbatim): *"we need a startup log / phase that ensure that all of these systems are coming online and working. and a 'status' dialog in the menu that shows the status of all subsystems (NOT FAKED 0 100% real only)"*

Core ethos to honor: **every status value must be a live probe, never a cached flag.** The user has been burned by silent failures masquerading as "ok" — same anti-silent-failure thesis as the 2026-05-07 API-first pivot. If a probe can't execute, say `unknown`, never `ok`.

---

## Round 2 — Boot-phase health check (~1.5 hours focused)

### Goal
After all `installX()` Tasks settle, run a live probe per subsystem. Log structured PASS/FAIL/UNKNOWN with evidence + latency. Surface failures via the existing `HUDBannerCoordinator` (the non-modal hard-block UX already used for entitlement / config failures — see `App/AppDelegate.swift:438` for the pattern). Stash the result as a `BootHealthSnapshot` that Round 3's Status menu reads.

### Subsystems + their live probes

| Subsystem | Probe | Notes |
|---|---|---|
| **Memory** | `MemoryStatsStoreAdapter.getMemoryStats()` round-trip | Already exists — wired in `installSelfKnowledgeTools`. Reuse. |
| **Anthropic** | 1-token-budget request with stored API key (`messages.create(max_tokens:1)`) | Skip if provider not configured Anthropic. ~200ms. |
| **Ollama** | GET `/api/tags`, assert every configured model name is present | Check both `ModelID.qwen36` (extractor) and `ModelID.qwen25coder32b` (agent fallback) plus `nomic-embed-text` (embedder). |
| **Voice** | `AudioGraphOwner.state` query + microphone TCC status | Documented dormant if voice install short-circuited. |
| **Vision** | `AVCaptureDevice.authorizationStatus(for: .video)` + camera count from `AVCaptureDeviceListAdapter` | Pure live probe, no async. |
| **MCP runtime** | `mcpClient.toolCatalog().count` + helper-app heartbeat | Should match the expected helper count (≥3 for stdio + N in-process). |
| **Replay** | Small SQLite probe insert + rollback on `replay.sqlite` | Catches WAL or disk issues. |
| **Webview** | Bus `helloAck` received with matching protocol version | Already checked at handshake — surface that flag. |

### Suggested file layout

- `packages/AgentCore/Sources/AgentCore/BootHealth.swift` — new module:
  - `BootHealthSnapshot` (Codable, Sendable struct) with per-subsystem `SubsystemHealth { name, state: .ok | .degraded(reason) | .failed(reason) | .unknown, lastProbedAt: Date, latencyMs: Int? }`
  - `BootHealthProbe` protocol — `func probe() async -> SubsystemHealth`
  - `BootHealthOrchestrator` actor — owns the snapshot, accepts probe registrations, runs them in parallel, emits the snapshot
- `App/Boot/BootHealthProbes.swift` — concrete probes per subsystem (each wraps the existing adapter / actor and translates results to `SubsystemHealth`).
- `App/AppDelegate.swift` — call `bootHealth.runAll()` AFTER all `installX` Tasks join; surface any `.failed` via `HUDBannerCoordinator.enqueue`; log structured result to system log.

### Acceptance criteria

- Cold boot logs one line per subsystem `subsystem=memory state=ok latencyMs=12 evidence="6 turns, vec_version=v0.1.6"`.
- Any `.failed` subsystem triggers a banner enqueue (non-modal, matches existing hard-block-banner UX).
- The snapshot is reachable from the menu bar layer (stored on `AppDelegate` or via a shared actor).
- **No fakes**: e.g. if Anthropic check is skipped because the key isn't stored, state is `.unknown` not `.ok`.
- A live-network test of Anthropic / Ollama lives behind the existing `JARVIS_REAL_MODELS=1` env-flag pattern so unit tests stay deterministic.

### Risks

- **Boot-time latency**: probes shouldn't block app startup. Run in parallel after install Tasks join, then update the snapshot. The HUD comes up before probes complete; banner appears when a failure lands.
- **Anthropic probe cost**: 1 token is essentially free, but still a paid call. Consider caching for 60s so menu re-probes don't spam the API.

---

## Round 3 — Status menu dialog (~2 hours focused)

### Goal
A "Status..." item in the menu bar's menu that opens a non-modal AppKit panel showing the current `BootHealthSnapshot`. **Always re-probes on open** (per "NOT FAKED" — show live state, not the boot snapshot). "Re-probe all" button forces a fresh sweep. "Copy report" copies the snapshot as JSON.

### Suggested file layout

- `App/MenuBar/StatusPanel.swift` — `NSPanel` subclass + SwiftUI body for the table layout sketched in the proposal.
- `App/MenuBar/MenuBarContextMenu.swift` — add a `"Status..."` `NSMenuItem` between existing items; target opens the panel.

### Layout (from the proposal in conversation)

```
┌─ Jarvis Status ──────────────────────┐
│ ▲ Memory     ✓  6 turns, 0 facts     │
│              vec_version v0.1.6      │
│              probed: 12ms ago        │
│ ▲ Anthropic  ✓  reachable (240ms)    │
│              model claude-opus-4-7   │
│ ▲ Ollama     ⚠ qwen3.6 ✓ (extractor) │
│              nomic-embed-text ✗      │
│              ! pull nomic-embed-text │
│ ▲ Voice      ✓ AudioGraph running    │
│              48kHz Sennheiser SDW 5  │
│ ▲ Vision     ✗ Camera TCC denied     │
│ [Re-probe all]  [Copy report]        │
└──────────────────────────────────────┘
```

### Acceptance criteria

- Menu item exists; clicking opens panel; closing window keeps app running.
- Re-probe button replaces displayed values with fresh probes; latency shown updates.
- Each row's "evidence" line is concrete (e.g. mic name, model name, file size) — never a generic "ok".
- Copy-report writes JSON to NSPasteboard.
- Panel is **non-modal** (project rule: `scripts/check-no-modal-presentation.sh`).

### Don't forget

- The webview HUD is the wrong place for this — it's an operator/dev tool, not a user-facing surface. AppKit panel keeps it out of the HUD's R3F pipeline.
- Codesigning: new NSPanel doesn't need new entitlements.

---

## After Rounds 2 & 3 — outstanding D-7 piece

Still required for memory **fact extraction** (separate from B-02 history threading, which is already working):

```bash
ollama pull nomic-embed-text   # ~270 MB; embedder for the facts_vec column
```

Without this, the embedder fails on first extraction attempt and no rows land in `facts`. Surface in Round 2's Ollama probe so the user knows immediately. (qwen3.6 + qwen2.5-coder are both present — no pull needed for those.)

## Suggested execution order (next session)

1. Read this file + `docs/SESSION-STATE.md` + `docs/TODO.md`.
2. Run `git log --oneline -5` to confirm `8d0a959` is at HEAD.
3. Run `swift test --package-path packages/Memory` to confirm 91/0/10 tests baseline.
4. Build Round 2: BootHealth types + probes + orchestrator + install-time integration. Commit.
5. Dogfood Round 2 — confirm system log shows the structured per-subsystem lines, banner appears when something fails.
6. Build Round 3: StatusPanel + menu item. Commit.
7. Dogfood Round 3 — open menu, see live state, re-probe, copy report.

Both rounds are independently shippable. Round 2 has value even without Round 3 (logs alone catch silent failures).
