import type { OllamaFailureKind } from '@jarvis/bus'

/**
 * EscalationBadge — small inline marker rendered inside an assistant
 * message when the orchestrator reactively escalated that turn from the
 * local Ollama provider to Anthropic Opus. The reason string is the
 * `OllamaFailureKind` carried on `BusOutbound.escalated.decision.reason`;
 * the friendly map below covers all six kinds defined in
 * `packages/bus/src/protocol.ts` and `AgentCore.OllamaFailureKind`.
 *
 * Visual styling (`.escalation-badge` in `chat-panel.css`) follows the
 * existing chip pattern — small font, low-contrast amber accent, unobtrusive.
 */
const FRIENDLY: Record<OllamaFailureKind, string> = {
  streamTruncated: 'stream truncated',
  malformedToolCall: 'malformed tool call',
  unknownTool: 'unknown tool',
  refusal: 'refusal',
  connectionFailure: 'connection failure',
  emptyResponse: 'empty response',
}

export function EscalationBadge({ reason }: { reason: OllamaFailureKind }) {
  return (
    <span
      data-testid="escalation-badge"
      className="escalation-badge"
      role="status"
    >
      Escalated to Opus — {FRIENDLY[reason]}
    </span>
  )
}
