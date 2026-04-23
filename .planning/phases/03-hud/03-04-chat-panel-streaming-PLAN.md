---
phase: 03-hud
plan: 04
type: execute
wave: 2
depends_on: [03-02]
files_modified:
  - webview/packages/hud/src/chat/ChatPanel.tsx
  - webview/packages/hud/src/chat/ChatEventRouter.tsx
  - webview/packages/hud/src/chat/TextPart.tsx
  - webview/packages/hud/src/chat/ToolCallCard.tsx
  - webview/packages/hud/src/chat/ErrorPart.tsx
  - webview/packages/hud/src/chat/chat-panel.css
  - webview/packages/hud/src/bus/client.ts
  - webview/packages/hud/src/store/index.ts
  - webview/packages/hud/src/App.tsx
  - webview/packages/hud/tests/ChatPanel.test.tsx
  - webview/packages/hud/tests/ToolCallCard.test.tsx
  - webview/packages/hud/tests/streaming.test.tsx
  - webview/packages/hud/tests/chronology.test.tsx
  - webview/packages/hud/tests/fixtures/streaming-fixture.json
autonomous: true
requirements: [HUD-07, TEXT-02]
tags: [typescript, react19, zustand, chat, tool-calls, streaming, accessibility]

assumptions:
  - "Plan 03-02 landed the Zustand store with chatEvents, appendTokenToLastText, upsertToolCall, pushEvent actions (skeleton). This plan extends the bus dispatcher to actually CALL those actions based on BusOutbound messages."
  - "Plan 03-03 landed ParticleRing + LoadingFallbacks. This plan adds ChatPanel as a sibling in App.tsx below the ring."
  - "Bus message types `chat/*` described in RESEARCH §Pattern 4 (chat/textStart, chat/tokenDelta, chat/textEnd, chat/toolCallStart, chat/toolCallRunning, chat/toolCallAwaitingApproval, chat/toolCallCompleted, chat/toolCallFailed, chat/errorPart) are NOT yet in `@jarvis/bus`. This plan DOES NOT extend the Swift BusOutbound enum (that's a breaking change requiring parity scripts + fixture re-spin). Instead, this plan REUSES the Phase 2 existing cases: `tokenDelta`, `toolCallStart`, `toolCallEnd`, `turnStarted`, `turnEnded` + a synthetic client-side lifecycle derivation. A Phase 4 SUMMARY-noted follow-up upgrades the schema when the agent orchestrator lands (P4) with richer tool-call state."
  - "Explicit non-goal: Plan 03-04 does NOT add `chat/textStart` to the bus schema — instead, the dispatcher synthesizes an implicit text-part on first `tokenDelta` after `turnStarted` with a deterministic id `turn:{turnId}:assistant`. Fixture tests pin this synthesis. Phase 4 adds the explicit `chat/textStart` when the orchestrator starts emitting it."
  - "Tool-call lifecycle state machine per RESEARCH §Pattern 4 lines 661-684: pending → running → (awaiting-approval?) → completed|failed. Phase 2's `toolCallStart` + `toolCallEnd` do NOT carry a `running`/`awaiting-approval` mid-state. Plan 03-04 derives: `toolCallStart` with `argsPreview` containing the sentinel JSON string `{\"awaitingApproval\":true}` → status 'awaiting-approval'; otherwise status 'running' (skipping pending since Phase 2 doesn't carry it). `toolCallEnd` with `ok:true` → 'completed'; `ok:false` → 'failed'. The 'pending' status is dead-code for P3 but the state machine is wired end-to-end; Phase 5 emits real pending/awaiting-approval transitions."
  - "Synthetic fixture test produces byte-identical output to a pre-recorded ChatPanel rendered HTML (TEXT-02 success criterion #5). The fixture is a JSON array of BusOutbound messages; the test replays them through the dispatcher and asserts the rendered DOM matches a snapshot (using `@testing-library/react`'s `getByRole('log')` + normalization)."
  - "No virtualization in P3 (RESEARCH §A8) — flat list of ChatEvents rendered directly. P8 hardening adds `@tanstack/react-virtual` if profiling shows need."

must_haves:
  truths:
    - "ChatPanel renders an ordered list of `ChatEvent` items via React flat-list with stable `key={event.id}`; tool-call cards are rendered INLINE with text parts based on `chatEvents` array order (chronological inlining)"
    - "`<TextPart>` renders `event.text` as plain text; tokens stream in via Zustand's `appendTokenToLastText` action on each `tokenDelta`; component rerenders only when its own `text` changes (scoped selector)"
    - "`<ToolCallCard>` has local expand/collapse state; renders 5 status labels (`pending`, `running`, `awaiting-approval`, `completed`, `failed`) per RESEARCH §Pattern 4 state machine"
    - "For tool calls with `argsPreview === '{\"awaitingApproval\":true}'`, the card body renders 'Arguments: (hidden until you approve)' — args do NOT leak pre-approval (RESEARCH §Pitfall 9 defense-in-depth, even though Phase 5 is the authoritative enforcer)"
    - "Bus dispatcher in `webview/packages/hud/src/bus/client.ts` is extended to handle `turnStarted`, `turnEnded`, `tokenDelta`, `toolCallStart`, `toolCallEnd` — each routes to a specific store action"
    - "`tokenDelta` dispatch: if no open text-part exists for current turn, synthesize one with id `turn:{turnId}:assistant` + role='assistant', then append the delta. Subsequent tokenDeltas on the same turn append to the same id."
    - "`toolCallStart` + `toolCallEnd` upsert the tool-call ChatEvent by id — insertion happens at the END of the events array at the time of `toolCallStart` (which is chronologically correct); `toolCallEnd` mutates the same event by id without moving its position"
    - "`turnEnded` dispatch resolves the active text-part (closes the turn's assistant message) — subsequent tokenDelta (belonging to a NEW turn) would synthesize a new text-part at the next `turnStarted`"
    - "`ChatPanel` root div has `role='log'` + `aria-live='polite'` for screen-reader announcement of streamed content"
    - "`ChatEventRouter` discriminator exhaustively handles `kind: 'text' | 'tool-call' | 'error'` with a `_exhaustive: never` sentinel"
    - "Replay-fixture test drives a 20-message stream (turnStarted → 12x tokenDelta → toolCallStart → toolCallEnd → 5x tokenDelta → turnEnded) and asserts rendered HTML matches snapshot byte-for-byte after normalizing whitespace"
    - "Bus dispatcher is idempotent: replaying the fixture twice produces the same final store state (no double-appending)"
  artifacts:
    - path: "webview/packages/hud/src/chat/ChatPanel.tsx"
      provides: "Root <ChatPanel> component rendering flat list; role='log' + aria-live='polite'"
      contains: "role=\"log\""
    - path: "webview/packages/hud/src/chat/ChatEventRouter.tsx"
      provides: "Discriminator router over ChatEvent kind with exhaustiveness sentinel"
      contains: "_exhaustive: never"
    - path: "webview/packages/hud/src/chat/TextPart.tsx"
      provides: "Streaming text rendered with scoped Zustand selector"
      contains: "event.text"
    - path: "webview/packages/hud/src/chat/ToolCallCard.tsx"
      provides: "Expandable lifecycle card; pre-approval args hidden; 5 status labels"
      contains: "awaitingApproval"
    - path: "webview/packages/hud/src/bus/client.ts"
      provides: "Extended dispatcher handling tokenDelta, toolCallStart/End, turnStarted/Ended"
      contains: "appendTokenToLastText"
    - path: "webview/packages/hud/tests/fixtures/streaming-fixture.json"
      provides: "Canonical 20-message replay fixture for TEXT-02 chronology test"
      contains: "turnStarted"
  key_links:
    - from: "webview/packages/hud/src/bus/client.ts"
      to: "webview/packages/hud/src/store/index.ts"
      via: "useJarvisStore.getState().appendTokenToLastText / upsertToolCall / pushEvent"
      pattern: "appendTokenToLastText|upsertToolCall|pushEvent"
    - from: "webview/packages/hud/src/chat/ChatPanel.tsx"
      to: "webview/packages/hud/src/store/index.ts"
      via: "useJarvisStore selector (chatEvents)"
      pattern: "useJarvisStore\\(\\(s\\) => s\\.chatEvents\\)"
    - from: "webview/packages/hud/src/App.tsx"
      to: "webview/packages/hud/src/chat/ChatPanel.tsx"
      via: "import + JSX"
      pattern: "ChatPanel"
---

<objective>
Add a chat panel to the HUD that (a) renders streaming tokens token-by-token chronologically inlined with tool-call lifecycle cards (TEXT-02), (b) surfaces tool-call state transitions as expandable cards with all 5 lifecycle states (pending / running / awaiting-approval / completed / failed) per HUD-07, and (c) protects pre-approval tool-call args behind the `awaitingApproval` sentinel (defense-in-depth for RESEARCH §Pitfall 9).

The plan also extends the webview's bus dispatcher (Plan 03-02 left no-op arms for `tokenDelta`, `toolCallStart`, `toolCallEnd`, `turnStarted`, `turnEnded`) to route each Phase-2-available BusOutbound case into the right Zustand store mutation. A synthetic-fixture replay test proves that a pre-recorded 20-message stream produces byte-identical rendered output, satisfying TEXT-02's "byte-identical to a pre-recorded fixture" acceptance criterion.

Purpose: TEXT-02 + HUD-07 together are the user's second-most-visible Phase 3 surface. Without the chat panel, the ring is a mood-ring that can't show what Jarvis is actually doing. The tool-call cards are what make Jarvis feel like a *tool-using* agent rather than a chatbot — the user watches `run_applescript` traverse pending → running → completed right there in the log, with the AppleScript source visible on expand. The pre-approval guard is a seatbelt for Phase 5 — Phase 5's MCP-04 is the authoritative "args never leak pre-approval" enforcer, but this plan's webview dispatcher and card component already render hidden-args correctly so Phase 5's Swift-side substitution never accidentally gets undone by a permissive webview renderer.

Scope boundary: Plan 03-04 does NOT extend the Swift-side BusOutbound schema. Phase 2 landed fixed cases (`tokenDelta`, `toolCallStart` with `argsPreview`, `toolCallEnd` with `ok`, `turnStarted`, `turnEnded`). Plan 03-04 derives the richer P3 chat lifecycle FROM those existing cases — `chat/textStart` is synthesized on first `tokenDelta` after `turnStarted`; tool-call `pending`/`awaiting-approval` states are inferred from the `argsPreview` content. Phase 4's agent orchestrator will emit richer bus messages; Plan 04-NN (not this one) will extend the schema. This keeps Plan 03-04 buildable today with zero parity-script churn.

Output: a working chat panel below the particle ring that streams text + tool-call cards live; TEXT-02's byte-identical fixture replay passes; HUD-07's expand/collapse + pre-approval hidden-args behavior is enforced; React component tests cover the full lifecycle.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-hud/03-RESEARCH.md
@webview/packages/hud/src/store/types.ts
@webview/packages/hud/src/store/index.ts
@webview/packages/hud/src/bus/client.ts
@webview/packages/hud/src/App.tsx
@webview/packages/bus/src/protocol.ts

<interfaces>
<!-- Phase 2 BusOutbound cases (from @jarvis/bus) — the toolkit available to Plan 03-04: -->

```ts
type BusOutbound =
  | { type: "hello"; version: string }
  | { type: "hudState"; state: HudState }
  | { type: "tokenDelta"; text: string }            // NOT associated with an id; Plan 04 synthesizes the id
  | { type: "audioLevel"; rms: number }
  | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
  | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
  | { type: "turnStarted"; id: string }
  | { type: "turnEnded"; id: string; terminator: TurnTerminator }
```

<!-- ChatEvent shape landed in Plan 03-02's store/types.ts: -->
```ts
type ChatEvent =
  | { id: string; kind: 'text'; text: string; role: 'user'|'assistant'; turnId: string }
  | { id: string; kind: 'tool-call'; name: string; args: unknown; status: ToolCallStatus; result?: unknown; error?: string; turnId: string }
  | { id: string; kind: 'error'; message: string; turnId: string }
type ToolCallStatus = 'pending'|'running'|'awaiting-approval'|'completed'|'failed'
```

<!-- Derivation rules (this plan defines): -->
- `turnStarted { id }` → store `currentTurnId = id`; push no event yet.
- First `tokenDelta` after `turnStarted` → synthesize `{kind:'text', id:'turn:'+currentTurnId+':assistant', text:'', role:'assistant', turnId:currentTurnId}` via `pushEvent`, then `appendTokenToLastText(id, delta)`.
- Subsequent `tokenDelta` on same turn → `appendTokenToLastText(id, delta)`.
- `toolCallStart { id, name, argsPreview }` → `upsertToolCall({kind:'tool-call', id, name, args: parseArgsPreview(argsPreview), status: argsPreview==='{"awaitingApproval":true}' ? 'awaiting-approval' : 'running', turnId: currentTurnId})`.
- `toolCallEnd { id, ok, previewOrError }` → upsert existing event: status = ok?'completed':'failed'; result=ok?previewOrError:undefined; error=ok?undefined:previewOrError.
- `turnEnded { id, terminator }` → clear `currentTurnId`; no UI event (the text-part stays as-is).

<!-- Parsing argsPreview: Phase 2 `argsPreview` is a string (may or may not be JSON). Plan 03-04's parseArgsPreview tries JSON.parse; on failure, returns the raw string. -->
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: ChatPanel + ChatEventRouter + TextPart + ToolCallCard + ErrorPart components; component-level Vitest coverage; pre-approval args-hidden behavior</name>
  <files>webview/packages/hud/src/chat/ChatPanel.tsx, webview/packages/hud/src/chat/ChatEventRouter.tsx, webview/packages/hud/src/chat/TextPart.tsx, webview/packages/hud/src/chat/ToolCallCard.tsx, webview/packages/hud/src/chat/ErrorPart.tsx, webview/packages/hud/src/chat/chat-panel.css, webview/packages/hud/src/App.tsx, webview/packages/hud/tests/ChatPanel.test.tsx, webview/packages/hud/tests/ToolCallCard.test.tsx</files>
  <behavior>
    - Test C1 (ChatPanel.test.tsx: empty state): with chatEvents=[], `<ChatPanel />` renders an element with `role="log"` + `aria-live="polite"` + no children.
    - Test C2 (ChatPanel.test.tsx: order preserved): store.setState with chatEvents=[text1, tool1, text2]; render; assert DOM order is text1 → tool1 → text2 (via `container.children` order of testid-bearing nodes).
    - Test C3 (ChatPanel.test.tsx: discriminator router): feed one of each kind (text/tool-call/error); assert three different components render based on grep-like `data-chat-event-kind` attribute.
    - Test T1 (ToolCallCard.test.tsx: expand/collapse toggles `aria-expanded`): render card with status='running'; `getByRole('button').getAttribute('aria-expanded')` === 'false'; click button; → 'true'.
    - Test T2 (ToolCallCard.test.tsx: all 5 status labels): render once per status ∈ {pending, running, awaiting-approval, completed, failed}; assert the rendered status text matches the spec ("Preparing…", "Running", "Waiting for your approval", "Done", "Failed").
    - Test T3 (ToolCallCard.test.tsx: pre-approval args hidden): render with `args={{ awaitingApproval: true }}` and `status='awaiting-approval'`; click expand; assert body contains the literal string "(hidden until you approve)"; assert body does NOT contain any JSON representation of arbitrary args.
    - Test T4 (ToolCallCard.test.tsx: completed state shows result): render with `status='completed'`, `result='42'`; expand; assert body contains '42'.
    - Test T5 (ToolCallCard.test.tsx: failed state shows error): render with `status='failed'`, `error='AppleScript timeout'`; expand; assert body contains 'AppleScript timeout'.
    - Test TP1 (TextPart test via ChatPanel.test.tsx: renders event.text verbatim): chatEvent with `text='hello world'` renders `hello world` as text content.
    - Test TP2 (TextPart: streaming append via store): render ChatPanel; dispatch setState pushing empty text event; dispatch appendTokenToLastText with 'h', 'e', 'l', 'l', 'o' in sequence; assert final rendered text is 'hello' (without a flicker or re-key).
    - Test A1 (App.tsx integration): `grep -c 'ChatPanel' webview/packages/hud/src/App.tsx` ≥ 1.
  </behavior>
  <action>
    1. Create `webview/packages/hud/src/chat/ChatPanel.tsx`:
       ```tsx
       import { useJarvisStore } from '../store'
       import { ChatEventRouter } from './ChatEventRouter'
       import './chat-panel.css'
       export function ChatPanel() {
         const chatEvents = useJarvisStore((s) => s.chatEvents)
         return (
           <div className="chat-panel" role="log" aria-live="polite" aria-atomic="false">
             {chatEvents.map((ev) => (
               <ChatEventRouter key={ev.id} event={ev} />
             ))}
           </div>
         )
       }
       ```
    2. Create `webview/packages/hud/src/chat/ChatEventRouter.tsx`:
       ```tsx
       import type { ChatEvent } from '../store/types'
       import { TextPart } from './TextPart'
       import { ToolCallCard } from './ToolCallCard'
       import { ErrorPart } from './ErrorPart'
       export function ChatEventRouter({ event }: { event: ChatEvent }) {
         switch (event.kind) {
           case 'text':      return <TextPart event={event} />
           case 'tool-call': return <ToolCallCard event={event} />
           case 'error':     return <ErrorPart event={event} />
           default: {
             const _exhaustive: never = event
             void _exhaustive
             return null
           }
         }
       }
       ```
    3. Create `webview/packages/hud/src/chat/TextPart.tsx`:
       ```tsx
       import type { ChatEvent } from '../store/types'
       type TextEvent = Extract<ChatEvent, { kind: 'text' }>
       export function TextPart({ event }: { event: TextEvent }) {
         // Note: we render event.text directly as a React text node; React
         // auto-escapes all content so HTML characters in the stream (from
         // LLM output) cannot inject markup. Parent ChatPanel uses
         // key={event.id} so React reuses the DOM node across streaming
         // updates — the text span simply diffs its textContent.
         return (
           <div className="chat-panel__text" data-chat-event-kind="text" data-role={event.role}>
             <span className="chat-panel__text-role">{event.role === 'user' ? 'You' : 'Jarvis'}</span>
             <span className="chat-panel__text-content">{event.text}</span>
           </div>
         )
       }
       ```
    4. Create `webview/packages/hud/src/chat/ToolCallCard.tsx` per RESEARCH §Pattern 4 lines 697-758 — but strictly obey T3 (args hidden pre-approval):
       ```tsx
       import { useState } from 'react'
       import type { ChatEvent } from '../store/types'
       type ToolCallEvent = Extract<ChatEvent, { kind: 'tool-call' }>
       const STATUS_LABELS = {
         pending: 'Preparing…',
         running: 'Running',
         'awaiting-approval': 'Waiting for your approval',
         completed: 'Done',
         failed: 'Failed',
       } as const
       function isApprovalPlaceholder(args: unknown): boolean {
         return typeof args === 'object' && args !== null
           && 'awaitingApproval' in (args as Record<string, unknown>)
           && (args as Record<string, unknown>)['awaitingApproval'] === true
       }
       export function ToolCallCard({ event }: { event: ToolCallEvent }) {
         const [expanded, setExpanded] = useState(false)
         const label = STATUS_LABELS[event.status]
         const hideArgs = isApprovalPlaceholder(event.args) || event.status === 'awaiting-approval'
         return (
           <div
             className={`tool-call-card tool-call-card--${event.status}`}
             data-chat-event-kind="tool-call"
             data-tool-status={event.status}
             role="group"
             aria-label={`Tool call ${event.name}, ${label}`}
           >
             <button
               type="button"
               className="tool-call-card__header"
               onClick={() => setExpanded((v) => !v)}
               aria-expanded={expanded}
             >
               <span className="tool-call-card__status-dot" aria-hidden="true" />
               <span className="tool-call-card__name">{event.name}</span>
               <span className="tool-call-card__status">{label}</span>
               <span className="tool-call-card__chevron" aria-hidden="true">{expanded ? '▾' : '▸'}</span>
             </button>
             {expanded && (
               <div className="tool-call-card__body">
                 <section className="tool-call-card__section">
                   <h4>Arguments</h4>
                   <pre>{hideArgs ? '(hidden until you approve)' : JSON.stringify(event.args, null, 2)}</pre>
                 </section>
                 {event.result !== undefined && (
                   <section className="tool-call-card__section">
                     <h4>Result</h4>
                     <pre>{typeof event.result === 'string' ? event.result : JSON.stringify(event.result, null, 2)}</pre>
                   </section>
                 )}
                 {event.error && (
                   <section className="tool-call-card__section tool-call-card__section--error">
                     <h4>Error</h4>
                     <pre>{event.error}</pre>
                   </section>
                 )}
               </div>
             )}
           </div>
         )
       }
       ```
    5. Create `webview/packages/hud/src/chat/ErrorPart.tsx`:
       ```tsx
       import type { ChatEvent } from '../store/types'
       type ErrorEvent = Extract<ChatEvent, { kind: 'error' }>
       export function ErrorPart({ event }: { event: ErrorEvent }) {
         return (
           <div className="chat-panel__error" data-chat-event-kind="error" role="alert">
             <strong>Error:</strong> {event.message}
           </div>
         )
       }
       ```
    6. Create `webview/packages/hud/src/chat/chat-panel.css` — minimal styles with consistent design tokens from `theme/tokens.css` (arc-reactor-glow, card-bg, card-border, text-primary, text-secondary). Keep visual parity: ChatPanel takes `flex: 1` beneath the ring; max width 720px centered; card styles with subtle border + background.
    7. Update `webview/packages/hud/src/App.tsx` to include `<ChatPanel />` beneath `<LoadingFallbacks />`:
       ```tsx
       import { ParticleRing } from './hud/ParticleRing'
       import { LoadingFallbacks } from './hud/LoadingFallbacks'
       import { ChatPanel } from './chat/ChatPanel'
       export function App() {
         return (
           <div className="jarvis-hud">
             <div className="jarvis-hud__ring"><ParticleRing particles={512} /></div>
             <LoadingFallbacks />
             <ChatPanel />
           </div>
         )
       }
       ```
    8. Create `webview/packages/hud/tests/ChatPanel.test.tsx` and `webview/packages/hud/tests/ToolCallCard.test.tsx` covering C1-C3, T1-T5, TP1-TP2. Use `@testing-library/react` for DOM assertions. Tests call `useJarvisStore.setState(...)` in `beforeEach` to reset/seed state.
    9. Run `pnpm --filter @jarvis/hud test` — all tests pass (stateUniforms + RingMesh + store + bus-dispatch + ChatPanel + ToolCallCard from Plans 03-02/03/04).
    10. Run `pnpm --filter @jarvis/hud typecheck` — exit 0.
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm --filter @jarvis/hud test 2>&amp;1 | tail -15 &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; grep -c 'ChatPanel' packages/hud/src/App.tsx &amp;&amp; grep -c 'awaitingApproval' packages/hud/src/chat/ToolCallCard.tsx</automated>
  </verify>
  <done>
    - Five component files exist: ChatPanel, ChatEventRouter, TextPart, ToolCallCard, ErrorPart.
    - ChatPanel has role='log' and aria-live='polite'.
    - ToolCallCard hides args when `awaitingApproval: true` regardless of test input.
    - ChatPanel test + ToolCallCard test each have ≥4 passing test methods.
    - App.tsx renders the ChatPanel.
    - `pnpm test` + `pnpm typecheck` + `pnpm build` all exit 0.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Extend bus dispatcher to route tokenDelta/toolCallStart/toolCallEnd/turnStarted/turnEnded; add currentTurnId + activeTextPartId tracking to the store; synthetic-fixture replay test (TEXT-02)</name>
  <files>webview/packages/hud/src/bus/client.ts, webview/packages/hud/src/store/index.ts, webview/packages/hud/tests/streaming.test.tsx, webview/packages/hud/tests/chronology.test.tsx, webview/packages/hud/tests/fixtures/streaming-fixture.json</files>
  <behavior>
    - Test S1 (store.test.ts, amending Plan 03-02): store has additional slices `currentTurnId: string | null` (initially null) and `activeTextPartId: string | null` (initially null); actions `beginTurn(id)`, `endTurn()`.
    - Test D1 (streaming.test.tsx: tokenDelta without open text-part synthesizes one): dispatch turnStarted {id:'t1'}; dispatch tokenDelta {text:'he'}; expect chatEvents has 1 text event with id='turn:t1:assistant' and text='he'.
    - Test D2 (streaming.test.tsx: subsequent tokenDeltas append to same text-part): after D1, dispatch tokenDelta {text:'llo'}; expect same event now has text='hello'.
    - Test D3 (streaming.test.tsx: turnEnded resolves the turn): after D2, dispatch turnEnded {id:'t1', terminator:'completed'}; expect chatEvents still has 1 text event (not cleared); expect currentTurnId is null; expect activeTextPartId is null.
    - Test D4 (streaming.test.tsx: new turn starts a new text-part): after D3, dispatch turnStarted {id:'t2'}; dispatch tokenDelta {text:'world'}; expect chatEvents now has 2 text events; second has id='turn:t2:assistant'.
    - Test D5 (streaming.test.tsx: toolCallStart with awaitingApproval sentinel sets status='awaiting-approval'): dispatch toolCallStart {id:'tc1', name:'run_applescript', argsPreview:'{"awaitingApproval":true}'}; expect tool-call ChatEvent with status='awaiting-approval' AND args={awaitingApproval: true}.
    - Test D6 (streaming.test.tsx: toolCallStart without sentinel sets status='running'): dispatch toolCallStart {id:'tc2', name:'get_time', argsPreview:'{}'}; expect status='running'.
    - Test D7 (streaming.test.tsx: toolCallEnd ok=true transitions to completed): after D6, dispatch toolCallEnd {id:'tc2', ok:true, previewOrError:'2026-04-22T12:00:00Z'}; expect status='completed', result='2026-04-22T12:00:00Z'.
    - Test D8 (streaming.test.tsx: toolCallEnd ok=false transitions to failed): dispatch toolCallStart+toolCallEnd {ok:false, previewOrError:'timeout'}; expect status='failed', error='timeout'.
    - Test Ch1 (chronology.test.tsx: interleave preserved): dispatch sequence turnStarted → tokenDelta('hello ') → toolCallStart(tc1, get_time) → toolCallEnd(tc1, ok=true, '12:00') → tokenDelta('there') → turnEnded. Expect chatEvents in order: [text 'hello ', tool-call 'get_time' completed, text 'there'] — the second text-part is a SEPARATE text event because the tool-call interrupted the stream.
       - Plan this correctly: the rule is "when a non-text event arrives between tokenDeltas on the same turn, close the active text-part so the next tokenDelta opens a new one." Implement via: any non-tokenDelta event on the active turn nulls `activeTextPartId`. The text id then becomes `turn:t1:assistant:2` for disambiguation.
    - Test Ch2 (chronology.test.tsx: byte-identical to pre-recorded fixture): load `webview/packages/hud/tests/fixtures/streaming-fixture.json` (array of 20 BusOutbound messages); replay via dispatcher; snapshot the rendered HTML via `render(<ChatPanel />).container.innerHTML`; compare to a fixture-sidecar expected string (also committed under `tests/fixtures/`). The snapshot uses trim-whitespace + collapse-multi-space normalization because CSS order doesn't affect readability. TEXT-02 success criterion #5.
    - Test I1 (streaming.test.tsx: idempotent replay): replay the same 20-message fixture twice; final store state after second replay equals final state after first replay (use deep equality on chatEvents).
  </behavior>
  <action>
    1. Extend `webview/packages/hud/src/store/types.ts` with:
       ```ts
       export interface JarvisStore {
         hudState: HudState
         chatEvents: ChatEvent[]
         currentTurnId: string | null
         activeTextPartId: string | null
         // ... existing slices
         // ... actions
         beginTurn: (id: string) => void
         endTurn: () => void
         // Keep existing action names; Plan 03-04 uses them:
         // appendTokenToLastText(id, delta), upsertToolCall(ev), pushEvent(ev), setHudState(s)
       }
       ```
    2. Extend `webview/packages/hud/src/store/index.ts` with the two new slices + actions:
       ```ts
       currentTurnId: null,
       activeTextPartId: null,
       beginTurn: (id) => set({ currentTurnId: id, activeTextPartId: null }),
       endTurn: () => set({ currentTurnId: null, activeTextPartId: null }),
       ```
       Also add a helper action `closeActiveTextPart` (internal; no export) that just does `set({ activeTextPartId: null })` — called by the dispatcher when a non-tokenDelta event arrives mid-turn so the next tokenDelta opens a fresh text-part.
    3. Replace `webview/packages/hud/src/bus/client.ts` no-op arms with real dispatchers:
       ```ts
       import { installJarvisBus, type BusOutbound } from '@jarvis/bus'
       import { useJarvisStore } from '../store'
       function parseArgs(raw: string): unknown {
         try { return JSON.parse(raw) } catch { return raw }
       }
       function nextTextPartId(turnId: string, store: ReturnType<typeof useJarvisStore.getState>): string {
         // Deterministic id: first = turn:ID:assistant; subsequent = :assistant:2, :3...
         const existing = store.chatEvents.filter(e => e.kind === 'text' && e.turnId === turnId).length
         return existing === 0 ? `turn:${turnId}:assistant` : `turn:${turnId}:assistant:${existing + 1}`
       }
       export function attachBus(): void {
         installJarvisBus({
           onDecodeError: (e, raw) => console.error('[bus] decode failed:', e, raw),
         })
         window.jarvisBus.onOutbound((msg: BusOutbound) => {
           const store = useJarvisStore.getState()
           switch (msg.type) {
             case 'hello':
               // Auto-acked by @jarvis/bus bridge; no store action.
               break
             case 'hudState':
               store.setHudState(msg.state)
               break
             case 'turnStarted':
               store.beginTurn(msg.id)
               break
             case 'turnEnded':
               store.endTurn()
               break
             case 'tokenDelta': {
               const turnId = store.currentTurnId
               if (!turnId) {
                 // No active turn — ignore (log once)
                 console.warn('[bus] tokenDelta without active turn:', msg.text)
                 break
               }
               let id = store.activeTextPartId
               if (!id) {
                 id = nextTextPartId(turnId, store)
                 store.pushEvent({ kind: 'text', id, text: '', role: 'assistant', turnId })
                 useJarvisStore.setState({ activeTextPartId: id })
               }
               store.appendTokenToLastText(id, msg.text)
               break
             }
             case 'toolCallStart': {
               const turnId = store.currentTurnId ?? 'untracked'
               const isApproval = msg.argsPreview === '{"awaitingApproval":true}'
               store.upsertToolCall({
                 kind: 'tool-call',
                 id: msg.id,
                 name: msg.name,
                 args: parseArgs(msg.argsPreview),
                 status: isApproval ? 'awaiting-approval' : 'running',
                 turnId,
               })
               // Interrupt any active text-part so the next tokenDelta opens a new one
               useJarvisStore.setState({ activeTextPartId: null })
               break
             }
             case 'toolCallEnd': {
               const existing = store.chatEvents.find(
                 (e) => e.kind === 'tool-call' && e.id === msg.id,
               )
               if (!existing || existing.kind !== 'tool-call') {
                 console.warn('[bus] toolCallEnd for unknown id:', msg.id)
                 break
               }
               store.upsertToolCall({
                 ...existing,
                 status: msg.ok ? 'completed' : 'failed',
                 result: msg.ok ? msg.previewOrError : undefined,
                 error: msg.ok ? undefined : msg.previewOrError,
               })
               useJarvisStore.setState({ activeTextPartId: null })
               break
             }
             case 'audioLevel':
               // Plan 03-03's shader currently uses a fake sine; Phase 6 binds this to the mic RMS.
               // No store mutation needed for P3; the future wiring is `store.setAudioRms(msg.rms)`.
               break
             default: {
               const _exhaustive: never = msg
               void _exhaustive
               console.warn('[bus] unknown outbound:', msg)
             }
           }
         })
       }
       ```
    4. Create `webview/packages/hud/tests/fixtures/streaming-fixture.json` — a 20-message canonical replay. Structure: 1 turnStarted, 12 tokenDelta, 1 toolCallStart, 1 toolCallEnd, 4 tokenDelta, 1 turnEnded. Example payload:
       ```json
       [
         {"type":"turnStarted","id":"550e8400-e29b-41d4-a716-446655440001"},
         {"type":"tokenDelta","text":"Hello"},
         {"type":"tokenDelta","text":", "},
         {"type":"tokenDelta","text":"let "},
         {"type":"tokenDelta","text":"me "},
         {"type":"tokenDelta","text":"check "},
         {"type":"tokenDelta","text":"the "},
         {"type":"tokenDelta","text":"time "},
         {"type":"tokenDelta","text":"for "},
         {"type":"tokenDelta","text":"you"},
         {"type":"tokenDelta","text":". "},
         {"type":"tokenDelta","text":"One"},
         {"type":"tokenDelta","text":" moment"},
         {"type":"toolCallStart","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","name":"get_time","argsPreview":"{}"},
         {"type":"toolCallEnd","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","ok":true,"previewOrError":"2026-04-22T12:00:00Z"},
         {"type":"tokenDelta","text":"It's "},
         {"type":"tokenDelta","text":"noon"},
         {"type":"tokenDelta","text":" on "},
         {"type":"tokenDelta","text":"Wednesday"},
         {"type":"turnEnded","id":"550e8400-e29b-41d4-a716-446655440001","terminator":"completed"}
       ]
       ```
       Also create a sidecar `streaming-fixture.expected.html` with the expected normalized DOM. Or (simpler) embed the expected string inline in `chronology.test.tsx` alongside the fixture load — avoids the double-file maintenance if one changes.
    5. Create `webview/packages/hud/tests/streaming.test.tsx` (D1-D8 + I1) + `webview/packages/hud/tests/chronology.test.tsx` (Ch1, Ch2). Both tests use the same dispatch helper (drive `window.jarvisBus.receive(JSON.stringify(msg))` in a loop; or directly import the internal dispatch function if refactored; easier route: call `window.jarvisBus.receive` which routes through the bridge's `decodeOutbound` + `onOutbound` — same path as production).
    6. For Ch2 normalization: `normalizeHtml(s) = s.replace(/\s+/g, ' ').trim()`. This tolerates React's indentation/newline insertion differences across versions without sacrificing the "byte-identical content" check. Document in a test comment that the normalization is intentional per TEXT-02's "byte-identical rendered output" reading — we render the same DOM content, not necessarily the same whitespace.
    7. Run `pnpm --filter @jarvis/hud test` — all tests pass.
    8. Run `pnpm --filter @jarvis/hud typecheck` — exit 0.
    9. Run `pnpm --filter @jarvis/hud build` — exit 0.
  </action>
  <verify>
    <automated>cd webview &amp;&amp; pnpm --filter @jarvis/hud test 2>&amp;1 | tail -20 &amp;&amp; pnpm --filter @jarvis/hud typecheck &amp;&amp; pnpm --filter @jarvis/hud build 2>&amp;1 | tail -5 &amp;&amp; test -s packages/hud/tests/fixtures/streaming-fixture.json &amp;&amp; grep -c 'appendTokenToLastText' packages/hud/src/bus/client.ts</automated>
  </verify>
  <done>
    - Bus dispatcher routes all Phase 2 BusOutbound cases into correct store mutations.
    - Store has `currentTurnId` + `activeTextPartId` + `beginTurn` + `endTurn` actions.
    - Streaming fixture at `tests/fixtures/streaming-fixture.json` with 20 messages.
    - `streaming.test.tsx` reports ≥8 passing tests; `chronology.test.tsx` reports ≥2 passing tests.
    - Byte-identical rendered output assertion passes.
    - All previous tests from Plans 03-02/03/04-Task1 still green.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Swift orchestrator → webview (bus) | Trusted producer; content (tool-call args preview, tokens) may be attacker-influenced if the LLM returns malicious text. Phase 5 SEC-07 sanitize pipeline is the authoritative line of defense; Plan 03-04 never renders raw HTML from event payloads — only text content via `{event.text}` JSX which React auto-escapes. |
| Tool-call args (pre-approval) | Args MUST NOT reach the webview DOM before user approval. Phase 5 MCP-04 substitutes `{awaitingApproval: true}` in Swift. Plan 03-04 additionally checks the args shape in the card and renders "(hidden until you approve)" as defense-in-depth. |
| React JSX escaping | All `{event.text}`, `{event.name}`, `{event.error}` render via React text nodes — `<` and `>` in content are auto-escaped. No raw-HTML injection APIs are used anywhere in chat components (neither the direct escape hatch nor any wrapper library; plain JSX text interpolation only). |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-30 | Information Disclosure | Pre-approval tool-call args leak into DOM | mitigate | Swift (Phase 5 / RESEARCH Pitfall 9) substitutes `{awaitingApproval: true}`. Plan 03-04's ToolCallCard additionally checks `isApprovalPlaceholder(args)` and renders "(hidden until you approve)" regardless of actual args content. Test T3 enforces. |
| T-03-31 | Tampering | Malicious LLM output injects HTML | mitigate | Plan 03-04 renders all payload content through React JSX text interpolation, which auto-escapes `<`, `>`, `&`. No raw-HTML APIs are used anywhere in chat components. CSP meta (Plan 03-02) additionally disallows inline/remote scripts. |
| T-03-32 | DoS | Unbounded chatEvents growth | accept | P3's expected event count per session is <500 (RESEARCH §A8). Virtualization (`@tanstack/react-virtual`) is P8 hardening work if profiling reveals need. |
| T-03-33 | Tampering | Token-delta race (Pitfall 7) | mitigate | Dispatcher runs synchronously inside the `onOutbound` callback (Zustand `set` is synchronous). First-delta synthesizes the text-part BEFORE appending; no async gap. Test D1+D2 verify ordering. |
| T-03-34 | Repudiation | Tool-call without matching End | accept | Dispatcher's `toolCallEnd` handler logs `console.warn` on unknown id but does not synthesize a phantom card. A tool-call that leaves `running` forever is a Phase 4/5 orchestrator bug, not a P3 concern. |
| T-03-35 | Tampering | BusOutbound schema drift without dispatcher update | mitigate | The dispatcher's default branch has `const _exhaustive: never = msg;` — adding a new BusOutbound variant without extending the switch fails `tsc --strict`. |
</threat_model>

<verification>
Phase-gate for Plan 03-04:
1. `pnpm --filter @jarvis/hud build && pnpm --filter @jarvis/hud test && pnpm --filter @jarvis/hud typecheck` all exit 0.
2. `pnpm --filter @jarvis/hud test` reports ≥N passing tests where N is the sum of: 6 stateUniforms + 4 RingMesh + 4 store + 3 bus-dispatch (03-02) + 4 ChatPanel + 5 ToolCallCard + 8 streaming + 2 chronology = ≥36 total. No failing tests.
3. `grep -c 'awaitingApproval' webview/packages/hud/src/chat/ToolCallCard.tsx` ≥ 1.
4. `grep -c 'ChatPanel' webview/packages/hud/src/App.tsx` ≥ 1.
5. `grep -c 'role="log"' webview/packages/hud/src/chat/ChatPanel.tsx` ≥ 1.
6. `test -s webview/packages/hud/tests/fixtures/streaming-fixture.json` (non-empty file).
7. `cd packages/Bus && swift test` stays 47/47 green.
8. No changes to Swift or @jarvis/bus package code.
</verification>

<success_criteria>
- Chat panel renders beneath the ring with role='log' + aria-live='polite'.
- Streaming tokens flow into text parts via Zustand; tool-call cards interleave chronologically.
- Tool-call cards render all 5 lifecycle states with correct labels.
- Pre-approval args are hidden behind the sentinel check, defense-in-depth for Phase 5 MCP-04.
- Byte-normalized-identical output from the 20-message fixture replay proves TEXT-02 chronology.
- Bus dispatcher extends Plan 03-02's scaffold with real store mutations; all Phase 2 BusOutbound cases are exhaustively handled.
- No changes to Swift code or `@jarvis/bus`; schema extensions are deferred to Phase 4 when the orchestrator needs richer lifecycle events.
</success_criteria>

<output>
After completion, create `.planning/phases/03-hud/03-04-SUMMARY.md`:
- `requirements-completed: [HUD-07, TEXT-02]` (both satisfied within the webview boundary; Plan 03-05's end-to-end integration proves them against live Swift traffic).
- Decisions: synthesized text-part id scheme `turn:{id}:assistant[:n]`; derivation of lifecycle states from Phase-2-available `toolCallStart`/`toolCallEnd`; args-hidden defense-in-depth in the card even though Phase 5 is authoritative.
- Known stubs: `audioLevel` dispatcher arm is a deliberate no-op awaiting Phase 6; `pending` status is dead-code in P3 (Phase 5 emits it during the tool-call setup window).
- Phase 4 schema upgrade notes: agent orchestrator will emit richer bus events (`chat/textStart`, `chat/toolCallAwaitingApproval`, explicit state transitions); Plan 04-NN will extend `@jarvis/bus` and update this dispatcher. The synthesized-id scheme is forward-compatible because the store uses event id as the upsert key.
- Next plan readiness: Plan 03-05 swaps `bus-harness.html` for the R3F bundle via `loadFileRequest`, updates AppDelegate.installBus() and JarvisHUDPanel to use the new bundle, wires HudStateCoordinator into the bridge, and adds the `WebviewBundleLoadTests` end-to-end test that boots the real HUD and asserts `uiReady` arrives within 2 seconds.
</output>
