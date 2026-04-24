---
phase: 03-hud
plan: 04
subsystem: ui
tags: [typescript, react19, zustand, chat, tool-calls, streaming, accessibility]

# Dependency graph
requires:
  - phase: 02-bus
    provides: "BusOutbound schema (turnStarted/Ended, tokenDelta, toolCallStart/End, hudState, hello, audioLevel)"
  - phase: 03-hud/03-02
    provides: "Zustand store scaffold (chatEvents, pushEvent, appendTokenToLastText, upsertToolCall); bus client no-op dispatcher"
  - phase: 03-hud/03-03
    provides: "ParticleRing + LoadingFallbacks (ChatPanel composes as sibling beneath)"
provides:
  - "ChatPanel + ChatEventRouter + TextPart + ToolCallCard + ErrorPart React components"
  - "Extended Zustand store: currentTurnId, activeTextPartId, beginTurn, endTurn"
  - "Real bus dispatcher — routes every Phase-2 BusOutbound variant into store mutations"
  - "Synthesized client-side text-part lifecycle (plan 03-04 derives textStart from first tokenDelta after turnStarted)"
  - "Pre-approval args-hidden defense-in-depth guard in ToolCallCard"
  - "Canonical 20-message replay fixture + chronology test proving byte-content equivalence"
affects: [03-05, 04-agent-core, 05-mcp]

# Tech tracking
tech-stack:
  added: []  # No new deps; uses existing React 19, Zustand 5, @testing-library/react 16
  patterns:
    - "Synthesized text-part id scheme: turn:{turnId}:assistant[:n] — forward-compatible with Phase 4 explicit chat/textStart"
    - "Defense-in-depth: card hides args whenever sentinel present OR status==='awaiting-approval' (Phase 5 MCP-04 is authoritative but webview refuses to render non-sentinel args pre-approval)"
    - "Chronology rule: non-tokenDelta event on active turn nulls activeTextPartId → next tokenDelta opens a fresh text-part"
    - "role='log' + aria-live='polite' for screen-reader announcement of streamed content"

key-files:
  created:
    - "webview/packages/hud/src/chat/ChatPanel.tsx"
    - "webview/packages/hud/src/chat/ChatEventRouter.tsx"
    - "webview/packages/hud/src/chat/TextPart.tsx"
    - "webview/packages/hud/src/chat/ToolCallCard.tsx"
    - "webview/packages/hud/src/chat/ErrorPart.tsx"
    - "webview/packages/hud/src/chat/chat-panel.css"
    - "webview/packages/hud/tests/ChatPanel.test.tsx"
    - "webview/packages/hud/tests/ToolCallCard.test.tsx"
    - "webview/packages/hud/tests/streaming.test.tsx"
    - "webview/packages/hud/tests/chronology.test.tsx"
    - "webview/packages/hud/tests/fixtures/streaming-fixture.json"
  modified:
    - "webview/packages/hud/src/store/index.ts"
    - "webview/packages/hud/src/bus/client.ts"
    - "webview/packages/hud/src/App.tsx"

key-decisions:
  - "Synthesized text-part id scheme turn:{id}:assistant[:n] chosen for determinism + replay idempotency (I1 passes); forward-compatible with Phase 4 explicit chat/textStart"
  - "Derive awaiting-approval from argsPreview === '{\"awaitingApproval\":true}' sentinel (literal string equality); Phase 4 will emit richer state transitions"
  - "Defense-in-depth: ToolCallCard hides args if sentinel OR status==='awaiting-approval'; Phase 5 MCP-04 remains authoritative enforcer"
  - "Ch2 assertion normalizes whitespace (\\s+ → single space) and asserts DOM content + structure rather than byte-identical HTML — tolerates React minor-version whitespace differences without weakening the chronology contract"
  - "upsertToolCall signature was (id, patch) in 03-02; dispatcher adapted to call-site rather than changing store signature"
  - "Non-tokenDelta events (toolCallStart/End) on active turn null activeTextPartId — enforces chronological inlining without adding a bus schema field"

patterns-established:
  - "Pattern: ChatEvent discriminator router with _exhaustive: never sentinel — compile-time exhaustiveness"
  - "Pattern: synthesized turn-scoped ids for client-derived lifecycle state (survives idempotent replay)"
  - "Pattern: defense-in-depth UI guards that don't override but reinforce server-side security"
  - "Pattern: whitespace-normalized DOM content assertions over byte-identical HTML snapshots (React-version tolerant)"

requirements-completed: [HUD-07, TEXT-02]

# Metrics
duration: ~45min
completed: 2026-04-24
---

# Phase 3 Plan 04: Chat Panel + Streaming Dispatcher Summary

**Streaming chat panel with inline tool-call cards, full Phase-2 BusOutbound dispatcher wiring, and 20-message fixture replay proving chronological text/tool-call interleaving.**

## Performance

- **Duration:** ~45 min
- **Completed:** 2026-04-24
- **Tasks:** 2 (both TDD: RED → GREEN for each)
- **Files created:** 11
- **Files modified:** 3

## Accomplishments

- ChatPanel renders an ordered `role="log" aria-live="polite"` list of ChatEvents; stable React keys (`event.id`) let streaming text updates reuse DOM nodes without flicker.
- Full Phase-2 BusOutbound dispatcher: every variant (`hello`, `hudState`, `tokenDelta`, `audioLevel`, `toolCallStart`, `toolCallEnd`, `turnStarted`, `turnEnded`) is handled; default branch holds a `_exhaustive: never` compile-time sentinel.
- Deterministic text-part id synthesis (`turn:{id}:assistant[:n]`) makes the 20-message fixture replay idempotent (I1 passes).
- Tool-call cards render all 5 lifecycle states (pending, running, awaiting-approval, completed, failed) with icon + label; expand/collapse via accessible `aria-expanded` button.
- Pre-approval args hidden defense-in-depth — card refuses to render args whenever `{awaitingApproval: true}` sentinel present or status === 'awaiting-approval', regardless of what Swift sends (T-03-30 mitigation).
- Chronology rule: non-tokenDelta events close the open text-part so interleaved tool-calls produce separate text parts in the same turn.

## Task Commits

1. **Task 1: ChatPanel + discriminator router + ToolCallCard with pre-approval guard** — `e2dcaed` (feat)
2. **Task 2: Bus dispatcher wiring + store extension + streaming/chronology tests** — `4e2e05e` (feat)

_TDD cycle:_ both tasks landed as single feat commits because the test files live alongside component files; tests were authored first (verified RED), implementation second (verified GREEN).

## Files Created/Modified

**Created:**
- `webview/packages/hud/src/chat/ChatPanel.tsx` — root log list, `role="log"` + `aria-live="polite"`
- `webview/packages/hud/src/chat/ChatEventRouter.tsx` — exhaustive discriminator over `kind`
- `webview/packages/hud/src/chat/TextPart.tsx` — streaming text renderer with scoped selector
- `webview/packages/hud/src/chat/ToolCallCard.tsx` — expandable lifecycle card + args-hidden guard
- `webview/packages/hud/src/chat/ErrorPart.tsx` — `role="alert"` error surface
- `webview/packages/hud/src/chat/chat-panel.css` — minimal styling using `theme/tokens.css`
- `webview/packages/hud/tests/ChatPanel.test.tsx` — 5 tests (C1-C3, TP1-TP2)
- `webview/packages/hud/tests/ToolCallCard.test.tsx` — 6 tests (T1, T2×5 labels, T3, T3b, T4, T5)
- `webview/packages/hud/tests/streaming.test.tsx` — 12 tests (S1×3, D1-D8, I1)
- `webview/packages/hud/tests/chronology.test.tsx` — 2 tests (Ch1 interleave, Ch2 fixture)
- `webview/packages/hud/tests/fixtures/streaming-fixture.json` — 20-message canonical replay

**Modified:**
- `webview/packages/hud/src/store/index.ts` — add `currentTurnId`, `activeTextPartId`, `beginTurn`, `endTurn`
- `webview/packages/hud/src/bus/client.ts` — replace no-op arms with real store mutations
- `webview/packages/hud/src/App.tsx` — compose `<ChatPanel />` beneath `<LoadingFallbacks />`

## Decisions Made

See `key-decisions` in frontmatter. Summary: synthesized text-part id scheme chosen for forward-compat with P4 explicit `chat/textStart`; `{"awaitingApproval":true}` literal-string sentinel detection used because Phase-2 argsPreview is untyped; DOM-content normalization chosen over byte-identical HTML to survive React minor-version whitespace differences; interrupt-on-non-tokenDelta chronology rule implemented via `activeTextPartId: null` rather than a new bus field.

## Deviations from Plan

None — plan executed exactly as written, with two minor adaptations documented inline:

1. **Store `upsertToolCall` signature:** plan pseudocode shows `upsertToolCall({event})`, but 03-02's actual signature is `upsertToolCall(id, patch)`. Dispatcher adapted to match the existing store API; no store change required. Not a deviation — the plan explicitly allowed "read existing types.ts carefully".
2. **`resetStore` helpers in bus-dispatch.test.ts** were NOT updated to include the new `currentTurnId`/`activeTextPartId` slices, because Zustand's `setState` shallow-merges — the existing 03-02 tests remain green (confirmed: bus-dispatch.test.ts still 6/6). New tests in streaming/chronology include both slices in their resetStore helpers.

## Known Stubs

- **`audioLevel` dispatcher arm is a deliberate no-op** — Phase 6 will bind `msg.rms` to the ring shader via `store.setAudioRms(msg.rms)`. Documented in the dispatcher source.
- **`pending` ToolCallStatus is dead-code in P3** — Phase 2 emits only start/end; Phase 5 MCP-04 will emit a pending setup-window state. The state machine + renderer are already wired.
- **`chat/textStart` NOT added to bus schema** — Plan deliberately synthesizes the text-part client-side from first tokenDelta after turnStarted. Phase 4's agent orchestrator will extend `@jarvis/bus` with explicit `chat/textStart` (plus richer `chat/toolCallAwaitingApproval` transitions); this dispatcher's synthesis path is forward-compatible because the store uses event id as the upsert key.
- **Sidecar `streaming-fixture.expected.html` NOT created** — plan said OPTIONAL; inlined DOM-content assertions in `chronology.test.tsx` instead per plan's "avoids the double-file maintenance" suggestion.

## Issues Encountered

- `@jarvis/bus` dist/ missing on fresh `pnpm install` — had to `pnpm --filter @jarvis/bus build` first. One-time workspace bootstrap; not a regression.
- THREE.WARNING "Multiple instances of Three.js being imported" in test output — pre-existing (03-03), not introduced here.

## Self-Check: PASSED

**Files exist:**
- ChatPanel.tsx, ChatEventRouter.tsx, TextPart.tsx, ToolCallCard.tsx, ErrorPart.tsx, chat-panel.css — all FOUND
- ChatPanel.test.tsx, ToolCallCard.test.tsx, streaming.test.tsx, chronology.test.tsx, fixtures/streaming-fixture.json — all FOUND
- store/index.ts, bus/client.ts, App.tsx — modified as planned

**Commits:**
- `e2dcaed` (Task 1) — FOUND
- `4e2e05e` (Task 2) — FOUND

**Verification greps:**
- `grep -c 'role="log"' src/chat/ChatPanel.tsx` → 2 (≥1) ✓
- `grep -c 'awaitingApproval' src/chat/ToolCallCard.tsx` → 3 (≥1) ✓
- `grep -c 'ChatPanel' src/App.tsx` → 2 (≥1) ✓
- `grep -c 'appendTokenToLastText' src/bus/client.ts` → 1 (≥1) ✓
- `wc -c tests/fixtures/streaming-fixture.json` → 1025 bytes (non-empty) ✓

**Test count:** 79 passing (was 54 before plan; delta +25 = 5 ChatPanel + 6 ToolCallCard + 12 streaming + 2 chronology). Target ≥36 total from plan verification met 2.2×.

## Next Phase Readiness

- ChatPanel is live in `App.tsx`; dev server or bundled webview would render the panel beneath the ring.
- **Plan 03-05** can now (a) swap `bus-harness.html` for the R3F bundle in `JarvisHUDPanel` via `loadFileRequest`, (b) wire `HudStateCoordinator` into the bridge, (c) add `WebviewBundleLoadTests` asserting `uiReady` arrives within 2 seconds of cold boot, (d) add `build-webview.sh` to the Xcode run-script phase.
- **Phase 4 schema upgrade path:** agent orchestrator will emit `chat/textStart` + richer tool-call transitions; extending `@jarvis/bus` is the only coupling point — this dispatcher's synthesis logic is deliberately overridden when explicit `chat/textStart` arrives (store upsert-by-id makes the transition seamless).

---
*Phase: 03-hud*
*Plan: 04*
*Completed: 2026-04-24*
