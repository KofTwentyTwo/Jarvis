import { useState, type FormEvent } from 'react'
import type { BusInbound } from '@jarvis/bus'
import { useJarvisStore } from '../store'

/**
 * ChatInput — the JS-side producer of `BusInbound.chatSubmit` /
 * `chatCancelAndSubmit`. Closes BLOCKER-INT-3: pre-ChatInput, the HUD had no
 * way to start a text turn from the page, and the .bus tokenDelta forwarder
 * (commit 602a95b) had nothing to react to.
 *
 * Submit semantics:
 * - Empty / whitespace-only input is a no-op (no message, no echo).
 * - When `currentTurnId === null`, sends `chatSubmit` (Swift routes to
 *   `AgentOrchestrator.submit(.text(...))`).
 * - When `currentTurnId !== null`, sends `chatCancelAndSubmit` (barge-in:
 *   Swift routes to `AgentOrchestrator.cancelAndSubmit(.text(...))`).
 * - The user's text is echoed locally as a `kind: 'text', role: 'user'`
 *   event so chronology shows what the user typed without waiting for any
 *   Swift round-trip. Hydration via `sessionHistory` (WARN-INT-2) is not
 *   yet emitted, so there's no risk of duplication today.
 */
export function ChatInput() {
  const [text, setText] = useState('')
  const currentTurnId = useJarvisStore((s) => s.currentTurnId)
  const pushEvent = useJarvisStore((s) => s.pushEvent)

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const trimmed = text.trim()
    if (trimmed.length === 0) return

    // Optimistic user-text echo. The active turn id is unknown until Swift
    // emits `turnStarted`, so anchor to a synthetic `pending:{uuid}` if no
    // turn is in flight; the event still renders correctly because
    // ChatEventRouter only reads kind/role/text.
    const turnId = currentTurnId ?? `pending:${crypto.randomUUID()}`
    pushEvent({
      kind: 'text',
      id: `user:${crypto.randomUUID()}`,
      text: trimmed,
      role: 'user',
      turnId,
    })

    const msg: BusInbound =
      currentTurnId === null
        ? { type: 'chatSubmit', text: trimmed }
        : { type: 'chatCancelAndSubmit', text: trimmed }

    void window.jarvisBus.send(msg).catch((err: unknown) => {
      // eslint-disable-next-line no-console
      console.error('[chat] send failed:', err)
    })

    setText('')
  }

  return (
    <form className="chat-input" onSubmit={handleSubmit}>
      <input
        type="text"
        className="chat-input__field"
        placeholder="Ask Jarvis…"
        value={text}
        onChange={(e) => setText(e.target.value)}
        aria-label="Message"
        autoComplete="off"
        spellCheck
      />
      <button type="submit" className="chat-input__send" aria-label="Send">
        Send
      </button>
    </form>
  )
}
