/**
 * Shared pre-approval sentinel detection.
 *
 * Phase 5 MCP-04 substitutes the literal `{ awaitingApproval: true }` object
 * server-side before any pre-approval args ever reach the webview. Two sites
 * need to agree on the detection:
 *
 * 1. `bus/client.ts` — picks the initial `status` for a toolCallStart so the
 *    card renders "Waiting for your approval" instead of "Running".
 * 2. `chat/ToolCallCard.tsx` — defense-in-depth guard that hides args body
 *    whenever the sentinel is present, even if status was miscomputed.
 *
 * Prior to the H-01 fix the two checks disagreed on whitespace — the
 * dispatcher used literal-byte JSON equality while the card used
 * parsed-object semantics. Any Swift-side pretty-printing would silently
 * regress the status label. Unified here on the parsed-object form.
 */
export function isApprovalPlaceholder(args: unknown): boolean {
  return (
    typeof args === 'object' &&
    args !== null &&
    'awaitingApproval' in (args as Record<string, unknown>) &&
    (args as Record<string, unknown>)['awaitingApproval'] === true
  )
}
