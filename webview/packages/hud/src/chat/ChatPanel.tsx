import { useJarvisStore } from '../store'
import { ChatEventRouter } from './ChatEventRouter'
import './chat-panel.css'

/**
 * ChatPanel — flat, chronological list of ChatEvents. role="log" +
 * aria-live="polite" announces streamed content to screen readers.
 *
 * No virtualization in P3 (RESEARCH §A8); P8 adds `@tanstack/react-virtual`
 * if profiling shows need. Each child is keyed by event.id so React reuses
 * DOM nodes across streaming updates.
 */
export function ChatPanel() {
  const chatEvents = useJarvisStore((s) => s.chatEvents)
  return (
    <div
      className="chat-panel"
      role="log"
      aria-live="polite"
      aria-atomic="false"
    >
      {chatEvents.map((ev) => (
        <ChatEventRouter key={ev.id} event={ev} />
      ))}
    </div>
  )
}
