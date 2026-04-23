import type { HudState } from '@jarvis/bus'

export type { HudState }

export type ToolCallStatus =
  | 'pending'
  | 'running'
  | 'awaiting-approval'
  | 'completed'
  | 'failed'

export type ChatEvent =
  | { id: string; kind: 'text'; text: string; role: 'user' | 'assistant'; turnId: string }
  | {
      id: string
      kind: 'tool-call'
      name: string
      args: unknown
      status: ToolCallStatus
      result?: unknown
      error?: string
      turnId: string
    }
  | { id: string; kind: 'error'; message: string; turnId: string }

export type A11y = { reduceMotion: boolean; reduceTransparency: boolean }
export type Theme = { arcReactorGlow: string }
export type Connection = 'booting' | 'ready' | 'refused'
