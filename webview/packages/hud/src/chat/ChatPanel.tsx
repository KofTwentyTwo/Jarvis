import { useLayoutEffect, useRef } from 'react'
import { useJarvisStore } from '../store'
import { ChatEventRouter } from './ChatEventRouter'
import './chat-panel.css'

/**
 * Hysteresis (in px) for the "is user at the bottom?" check. As long as the
 * scroll position is within this distance of the bottom edge, the panel is
 * considered pinned and we auto-scroll on every new token. A small value is
 * deliberate: streaming tokens grow scrollHeight by ~one line at a time, and
 * we want the very first user-initiated scroll-up to break the pin.
 */
const BOTTOM_THRESHOLD_PX = 24

/**
 * Sum the text length of all chat events. This is the streaming-progress
 * signal the auto-scroll effect depends on. Using char-count means the
 * effect re-fires on every appended token even though `chatEvents.length`
 * stays constant during streaming (tokens append to the same text part).
 *
 * Cheap to compute (O(n) over chat events, each typically a short string)
 * and avoids inventing a new bus message just to drive scroll.
 */
function totalContentSignal(
  events: ReturnType<typeof useJarvisStore.getState>['chatEvents'],
): number {
  let total = events.length // event count contributes too (non-text events)
  for (const ev of events) {
    if (ev.kind === 'text') total += ev.text.length
    else if (ev.kind === 'tool-call') {
      // Status changes (running -> completed/failed) and result text growth
      // should also trigger a scroll-pin refresh. `result` is typed
      // `unknown` (tool outputs are arbitrary JSON), so coerce to string.
      total += ev.status.length
      if (ev.result !== undefined) total += String(ev.result).length
      if (ev.error) total += ev.error.length
    } else if (ev.kind === 'error') {
      total += ev.message.length
    }
  }
  return total
}

/**
 * ChatPanel — flat, chronological list of ChatEvents. role="log" +
 * aria-live="polite" announces streamed content to screen readers.
 *
 * Auto-scroll behavior (B-06 / #51 tactical fix):
 *   - When new content arrives (new event OR a token appended to an
 *     existing text part), scroll to the bottom — but only if the user
 *     is already pinned within BOTTOM_THRESHOLD_PX of the bottom edge.
 *   - If the user has scrolled up to re-read, leave them alone. The
 *     pin auto-re-arms as soon as they scroll back down.
 *
 * The full fix lands in M-7 (v0.8) once the API surface emits
 * `turnTextComplete` and we hydrate from `Turn.listTurns`; this is the
 * pure-DOM tactical layer that fits in v0.1.
 *
 * No virtualization in P3 (RESEARCH §A8); P8 adds `@tanstack/react-virtual`
 * if profiling shows need. Each child is keyed by event.id so React reuses
 * DOM nodes across streaming updates.
 */
export function ChatPanel() {
  const chatEvents = useJarvisStore((s) => s.chatEvents)
  const panelRef = useRef<HTMLDivElement | null>(null)

  // The content signal is `totalContentSignal(chatEvents)` — a number that
  // changes on every appended token, status transition, or new event.
  // useLayoutEffect runs synchronously after DOM mutation but before paint,
  // so the user never sees the intermediate (pre-scroll) frame.
  //
  // We re-measure `distanceFromBottom` at the moment the content changed
  // (rather than tracking pin state in a separate scroll handler). The
  // browser always exposes current scroll position via getter properties,
  // so this stays accurate even as the user scrolls without our handler
  // observing it.
  const contentSignal = totalContentSignal(chatEvents)
  useLayoutEffect(() => {
    const el = panelRef.current
    if (!el) return
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight
    if (distanceFromBottom > BOTTOM_THRESHOLD_PX) return
    // `scrollTo` is missing on JSDOM Elements (and on a few legacy
    // engines). Fall back to direct scrollTop assignment so production
    // never throws if the engine ships without it.
    if (typeof el.scrollTo === 'function') {
      el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
    } else {
      el.scrollTop = el.scrollHeight
    }
  }, [contentSignal])

  return (
    <div
      ref={panelRef}
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
