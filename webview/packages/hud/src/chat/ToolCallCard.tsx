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

/**
 * `args` from Swift may be the literal sentinel `{ awaitingApproval: true }`
 * — Phase 5 MCP-04 substitutes it server-side before any pre-approval args
 * ever reach the webview. This helper is defense-in-depth: even if Phase 5
 * regresses, this card refuses to render non-sentinel args pre-approval.
 */
function isApprovalPlaceholder(args: unknown): boolean {
  return (
    typeof args === 'object' &&
    args !== null &&
    'awaitingApproval' in (args as Record<string, unknown>) &&
    (args as Record<string, unknown>)['awaitingApproval'] === true
  )
}

export function ToolCallCard({ event }: { event: ToolCallEvent }) {
  const [expanded, setExpanded] = useState(false)
  const label = STATUS_LABELS[event.status]
  // Hide whenever the sentinel is present OR the status still says
  // awaiting-approval (a belt+suspenders guard per RESEARCH Pitfall 9).
  const hideArgs =
    isApprovalPlaceholder(event.args) || event.status === 'awaiting-approval'

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
        <span className="tool-call-card__chevron" aria-hidden="true">
          {expanded ? '▾' : '▸'}
        </span>
      </button>
      {expanded && (
        <div className="tool-call-card__body">
          <section className="tool-call-card__section">
            <h4>Arguments</h4>
            <pre>
              {hideArgs
                ? '(hidden until you approve)'
                : JSON.stringify(event.args, null, 2)}
            </pre>
          </section>
          {event.result !== undefined && (
            <section className="tool-call-card__section">
              <h4>Result</h4>
              <pre>
                {typeof event.result === 'string'
                  ? event.result
                  : JSON.stringify(event.result, null, 2)}
              </pre>
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
