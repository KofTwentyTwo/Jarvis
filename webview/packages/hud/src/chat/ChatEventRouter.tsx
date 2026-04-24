import type { ChatEvent } from '../store/types'
import { TextPart } from './TextPart'
import { ToolCallCard } from './ToolCallCard'
import { ErrorPart } from './ErrorPart'

/**
 * Discriminator router over ChatEvent kind. The default branch's
 * `const _exhaustive: never = event` assignment fails `tsc --strict` if a
 * new kind is added without a case — compile-time exhaustiveness guard.
 */
export function ChatEventRouter({ event }: { event: ChatEvent }) {
  switch (event.kind) {
    case 'text':
      return <TextPart event={event} />
    case 'tool-call':
      return <ToolCallCard event={event} />
    case 'error':
      return <ErrorPart event={event} />
    default: {
      const _exhaustive: never = event
      void _exhaustive
      return null
    }
  }
}
