import type { ChatEvent } from '../store/types'
import { EscalationBadge } from './EscalationBadge'

type TextEvent = Extract<ChatEvent, { kind: 'text' }>

/**
 * TextPart — renders event.text as a React text node.
 *
 * React auto-escapes `<`, `>`, `&` in text interpolations, so malicious LLM
 * output cannot inject markup here (T-03-31). Parent ChatPanel uses
 * `key={event.id}` so React reuses this DOM node across streaming updates;
 * only the text span's textContent diffs as tokens append.
 *
 * When the bus dispatcher attached an `EscalationDecision` to this event
 * (local-first LLM routing Task 8), an inline EscalationBadge is rendered
 * as a footer affordance under the message body.
 */
export function TextPart({ event }: { event: TextEvent }) {
  return (
    <div
      className="chat-panel__text"
      data-chat-event-kind="text"
      data-role={event.role}
    >
      <span className="chat-panel__text-role">
        {event.role === 'user' ? 'You' : 'Jarvis'}
      </span>
      <span className="chat-panel__text-content">{event.text}</span>
      {event.escalation && <EscalationBadge reason={event.escalation.reason} />}
    </div>
  )
}
