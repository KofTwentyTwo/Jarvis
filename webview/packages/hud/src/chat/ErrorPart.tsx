import type { ChatEvent } from '../store/types'

type ErrorEvent = Extract<ChatEvent, { kind: 'error' }>

export function ErrorPart({ event }: { event: ErrorEvent }) {
  return (
    <div
      className="chat-panel__error"
      data-chat-event-kind="error"
      role="alert"
    >
      <strong>Error:</strong> {event.message}
    </div>
  )
}
