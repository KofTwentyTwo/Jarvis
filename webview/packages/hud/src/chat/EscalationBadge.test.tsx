import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { EscalationBadge } from './EscalationBadge'

describe('EscalationBadge', () => {
  it('renders the failure reason in a friendly form', () => {
    render(<EscalationBadge reason="malformedToolCall" />)
    expect(screen.getByText(/malformed tool call/i)).toBeInTheDocument()
    expect(screen.getByText(/escalated to opus/i)).toBeInTheDocument()
  })

  it('uses a stable test id for selector use', () => {
    render(<EscalationBadge reason="streamTruncated" />)
    expect(screen.getByTestId('escalation-badge')).toBeInTheDocument()
  })

  it('renders all six failure kinds without throwing', () => {
    const reasons = [
      'streamTruncated',
      'malformedToolCall',
      'unknownTool',
      'refusal',
      'connectionFailure',
      'emptyResponse',
    ] as const
    for (const r of reasons) {
      render(<EscalationBadge reason={r} />)
    }
    // If any reason was not mapped, render would have thrown.
    expect(screen.getAllByTestId('escalation-badge').length).toBe(reasons.length)
  })
})
