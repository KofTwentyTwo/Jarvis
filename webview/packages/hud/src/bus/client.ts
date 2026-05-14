import { installJarvisBus, type BusOutbound } from '@jarvis/bus'
import { useJarvisStore } from '../store'
import type { ChatEvent } from '../store/types'
import { isApprovalPlaceholder } from '../chat/approvalSentinel'

/**
 * Install the window.jarvisBus bridge and register an exhaustive outbound
 * dispatcher. Every BusOutbound case has a switch arm; the default branch
 * uses `const _exhaustive: never = msg` with NO unsafe cast — adding a new
 * case to BusOutbound without a handler here fails `tsc --strict`.
 *
 * Plan 03-02 scaffolded this file. Plan 03-04 wires tokenDelta / turnStarted
 * / turnEnded / toolCallStart / toolCallEnd into real store mutations.
 */

/**
 * Parse Swift's `argsPreview` string. If it's valid JSON we surface the
 * parsed object to the card (which will JSON.stringify it for display).
 * Otherwise we pass the raw string through — cards fall back to a plain
 * pre-text renderer.
 */
function parseArgs(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return raw
  }
}

/**
 * Deterministic text-part id scheme: `turn:{turnId}:assistant` for the
 * first part of a turn; `turn:{turnId}:assistant:{n+1}` for subsequent
 * parts after a tool-call interruption (plan chronology rule Ch1).
 *
 * Counting is based on how many text-parts already exist for this turn so
 * replays converge to the same id (idempotency test I1).
 */
function nextTextPartId(
  turnId: string,
  chatEvents: readonly ChatEvent[],
): string {
  const existing = chatEvents.filter(
    (e) => e.kind === 'text' && e.turnId === turnId,
  ).length
  return existing === 0
    ? `turn:${turnId}:assistant`
    : `turn:${turnId}:assistant:${existing + 1}`
}

export function attachBus(): void {
  installJarvisBus({
    onDecodeError: (e, raw) => {
      // eslint-disable-next-line no-console
      console.error('[bus] decode failed:', e, raw)
    },
  })
  window.jarvisBus.onOutbound((msg: BusOutbound) => {
    const store = useJarvisStore.getState()
    switch (msg.type) {
      case 'hello':
        // Handled by the bridge's auto-ack prior to handler registration.
        break
      case 'hudState':
        store.setHudState(msg.state)
        break
      case 'turnStarted':
        store.beginTurn(msg.id)
        break
      case 'turnEnded':
        store.endTurn()
        break
      case 'tokenDelta': {
        const turnId = store.currentTurnId
        if (!turnId) {
          // No active turn — ignore but surface to ops.
          // eslint-disable-next-line no-console
          console.warn('[bus] tokenDelta without active turn:', msg.text)
          break
        }
        let id = store.activeTextPartId
        if (!id) {
          id = nextTextPartId(turnId, store.chatEvents)
          // If an escalation decision arrived before any assistant text
          // event (e.g. connectionFailure on the very first response),
          // attach it to the freshly-created text part so the badge isn't
          // dropped. The pending slot is cleared as a side-effect of the
          // store mutation below.
          const pending = store.pendingEscalation
          store.pushEvent({
            kind: 'text',
            id,
            text: '',
            role: 'assistant',
            turnId,
            ...(pending ? { escalation: pending } : {}),
          })
          useJarvisStore.setState({
            activeTextPartId: id,
            ...(pending ? { pendingEscalation: null } : {}),
          })
        }
        store.appendTokenToLastText(id, msg.text)
        break
      }
      case 'toolCallStart': {
        const turnId = store.currentTurnId ?? 'untracked'
        // Unified with ToolCallCard's defense-in-depth guard: parse the JSON
        // first and test via `isApprovalPlaceholder` so whitespace or field
        // ordering drift from Swift (e.g. pretty-printed output) can't
        // silently defeat the status label.
        const parsedArgs = parseArgs(msg.argsPreview)
        const isApproval = isApprovalPlaceholder(parsedArgs)
        store.upsertToolCall(msg.id, {
          name: msg.name,
          args: parsedArgs,
          status: isApproval ? 'awaiting-approval' : 'running',
          turnId,
        })
        // Any non-tokenDelta event on the active turn closes the open
        // text-part so the next tokenDelta opens a chronologically correct
        // new part (plan Ch1 rule).
        useJarvisStore.setState({ activeTextPartId: null })
        break
      }
      case 'toolCallEnd': {
        const existing = store.chatEvents.find(
          (e) => e.kind === 'tool-call' && e.id === msg.id,
        )
        if (!existing || existing.kind !== 'tool-call') {
          // eslint-disable-next-line no-console
          console.warn('[bus] toolCallEnd for unknown id:', msg.id)
          break
        }
        store.upsertToolCall(msg.id, {
          status: msg.ok ? 'completed' : 'failed',
          // Use undefined to clear the opposite field; the store action
          // only assigns defined patch fields, so pass explicit values.
          ...(msg.ok
            ? { result: msg.previewOrError }
            : { error: msg.previewOrError }),
        })
        useJarvisStore.setState({ activeTextPartId: null })
        break
      }
      case 'audioLevel':
        // Plan 03-03's ring shader uses a synthetic sine; Phase 6 binds this
        // to the real mic RMS. Intentional no-op for P3.
        break
      case 'submitRejected': {
        // Plan 09-04 / D-10. Render rejection inline as an error event so the
        // user sees why their text turn didn't start. A dedicated transient
        // toast slot is a future polish; surfacing inline keeps the chronology
        // honest right now.
        const turnId = store.currentTurnId ?? 'rejected'
        store.pushEvent({
          kind: 'error',
          id: `rejected:${Date.now()}`,
          message: msg.reason,
          turnId,
        })
        break
      }
      case 'sessionHistory':
        // Plan 07-06 added the case; AppDelegate.installMemory does not yet
        // hydrate (= WARN-INT-2). Until then we acknowledge but no-op so the
        // exhaustiveness sentinel below remains tight.
        break
      case 'escalated':
        // Local-first LLM routing Task 8 — attach the EscalationDecision
        // to the most-recent assistant text event. If none exists yet (the
        // failure fired before the first token), the store parks the
        // decision and the next assistant text event inherits it (see
        // tokenDelta arm above).
        store.attachEscalationToLastAssistantText(msg.decision)
        break
      default: {
        const _exhaustive: never = msg
        void _exhaustive
        // eslint-disable-next-line no-console
        console.warn('[bus] unknown outbound:', msg)
      }
    }
  })
}
