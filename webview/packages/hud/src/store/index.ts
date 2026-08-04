import { create } from 'zustand'
import { subscribeWithSelector } from 'zustand/middleware'
import type { EscalationDecision } from '@jarvis/bus'
import type {
  A11y,
  ChatEvent,
  Connection,
  HudState,
  Theme,
  ToolCallStatus,
} from './types'

export interface JarvisState {
  hudState: HudState
  chatEvents: ChatEvent[]
  /**
   * Plan 03-04: tracks the Swift-reported turn id between turnStarted and
   * turnEnded. Null when no turn is active. The bus dispatcher uses this to
   * tag synthesized text-parts with their owning turn and to guard
   * tokenDelta messages that arrive outside a turn.
   */
  currentTurnId: string | null
  /**
   * Plan 03-04: id of the currently-open assistant text-part, or null if no
   * text-part is open on the current turn. A non-tokenDelta event (tool-call
   * start/end) nulls this so the next tokenDelta opens a fresh, chronologically
   * correct text-part after the interruption.
   */
  activeTextPartId: string | null
  /**
   * Local-first LLM routing (Task 8): when `BusOutbound.escalated`
   * arrives before any assistant text event exists for the current turn
   * (e.g. connectionFailure on the very first response), the decision is
   * parked here and stamped onto the *first* assistant text event created
   * by a subsequent tokenDelta. Cleared on `beginTurn` and after consumption.
   */
  pendingEscalation: EscalationDecision | null
  a11y: A11y
  theme: Theme
  connection: Connection
  setHudState: (s: HudState) => void
  pushEvent: (e: ChatEvent) => void
  appendTokenToLastText: (id: string, delta: string) => void
  upsertToolCall: (
    id: string,
    patch: {
      name?: string
      args?: unknown
      status?: ToolCallStatus
      result?: unknown
      error?: string
      turnId?: string
    },
  ) => void
  beginTurn: (id: string) => void
  endTurn: () => void
  /**
   * Local-first LLM routing (Task 8): attach an EscalationDecision to the
   * most-recent assistant text event. Called from the bus dispatcher when
   * `BusOutbound.escalated` arrives. No-op if no assistant text event
   * exists yet — escalation may fire before any token streamed (e.g.
   * connectionFailure/refusal on the first response). The Anthropic
   * stream that follows the escalation will produce assistant text whose
   * tokenDeltas land *after* this call; for that case the badge is
   * surfaced on the subsequent text event via a small pending hand-off.
   */
  attachEscalationToLastAssistantText: (decision: EscalationDecision) => void
  setA11y: (patch: Partial<A11y>) => void
  setTheme: (patch: Partial<Theme>) => void
  setConnection: (c: Connection) => void
}

export const useJarvisStore = create<JarvisState>()(
  subscribeWithSelector((set) => ({
    hudState: 'booting',
    chatEvents: [],
    currentTurnId: null,
    activeTextPartId: null,
    pendingEscalation: null,
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#4FC3F7' },
    connection: 'booting',

    setHudState: (s) => set({ hudState: s }),

    pushEvent: (e) =>
      set((state) => ({ chatEvents: [...state.chatEvents, e] })),

    appendTokenToLastText: (id, delta) =>
      set((state) => {
        const idx = state.chatEvents.findIndex(
          (e) => e.id === id && e.kind === 'text',
        )
        if (idx === -1) return state
        const next = state.chatEvents.slice()
        const prev = next[idx]
        if (!prev || prev.kind !== 'text') return state
        next[idx] = { ...prev, text: prev.text + delta }
        return { chatEvents: next }
      }),

    upsertToolCall: (id, patch) =>
      set((state) => {
        const idx = state.chatEvents.findIndex(
          (e) => e.id === id && e.kind === 'tool-call',
        )
        if (idx === -1) {
          const fresh: ChatEvent = {
            id,
            kind: 'tool-call',
            name: patch.name ?? '',
            args: patch.args,
            status: patch.status ?? 'pending',
            ...(patch.result !== undefined ? { result: patch.result } : {}),
            ...(patch.error !== undefined ? { error: patch.error } : {}),
            turnId: patch.turnId ?? '',
          }
          return { chatEvents: [...state.chatEvents, fresh] }
        }
        const next = state.chatEvents.slice()
        const prev = next[idx]
        if (!prev || prev.kind !== 'tool-call') return state
        next[idx] = {
          ...prev,
          ...(patch.name !== undefined ? { name: patch.name } : {}),
          ...(patch.args !== undefined ? { args: patch.args } : {}),
          ...(patch.status !== undefined ? { status: patch.status } : {}),
          ...(patch.result !== undefined ? { result: patch.result } : {}),
          ...(patch.error !== undefined ? { error: patch.error } : {}),
          ...(patch.turnId !== undefined ? { turnId: patch.turnId } : {}),
        }
        return { chatEvents: next }
      }),

    beginTurn: (id) =>
      set({ currentTurnId: id, activeTextPartId: null, pendingEscalation: null }),

    endTurn: () => set({ currentTurnId: null, activeTextPartId: null }),

    attachEscalationToLastAssistantText: (decision) =>
      set((state) => {
        // Walk from the tail to find the most-recent assistant text event.
        for (let i = state.chatEvents.length - 1; i >= 0; i--) {
          const ev = state.chatEvents[i]
          if (ev && ev.kind === 'text' && ev.role === 'assistant') {
            const next = state.chatEvents.slice()
            next[i] = { ...ev, escalation: decision }
            return { chatEvents: next, pendingEscalation: null }
          }
        }
        // No assistant text yet — park the decision; the next assistant
        // text event created by tokenDelta inherits it.
        return { pendingEscalation: decision }
      }),

    setA11y: (patch) =>
      set((state) => ({ a11y: { ...state.a11y, ...patch } })),

    setTheme: (patch) =>
      set((state) => ({ theme: { ...state.theme, ...patch } })),

    setConnection: (c) => set({ connection: c }),
  })),
)

/**
 * Imperative HudState subscription for RingMesh (Plan 03-03) — subscribe
 * from inside `useFrame` without triggering React re-renders. Returns an
 * unsubscribe fn.
 */
export function subscribeHudState(fn: (s: HudState) => void): () => void {
  return useJarvisStore.subscribe((state) => state.hudState, fn)
}
