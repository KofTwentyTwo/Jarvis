import type { EscalationDecision, HudState } from '@jarvis/bus'

export type { HudState }

export type ToolCallStatus =
  | 'pending'
  | 'running'
  | 'awaiting-approval'
  | 'completed'
  | 'failed'

/**
 * Local-first LLM routing (Task 8): when the orchestrator reactively
 * escalates the active Ollama turn to Anthropic, the bus emits
 * `BusOutbound.escalated`; the dispatcher attaches the decision to the
 * most-recent assistant text event so the renderer can stamp an inline
 * EscalationBadge under that message body.
 */
export type ChatEvent =
  | {
      id: string
      kind: 'text'
      text: string
      role: 'user' | 'assistant'
      turnId: string
      escalation?: EscalationDecision
    }
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
