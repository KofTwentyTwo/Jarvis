import { create } from 'zustand'
import { subscribeWithSelector } from 'zustand/middleware'
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
  setA11y: (patch: Partial<A11y>) => void
  setTheme: (patch: Partial<Theme>) => void
  setConnection: (c: Connection) => void
}

export const useJarvisStore = create<JarvisState>()(
  subscribeWithSelector((set) => ({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
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
