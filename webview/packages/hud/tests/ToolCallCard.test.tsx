import { describe, it, expect } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import { ToolCallCard } from '../src/chat/ToolCallCard'
import type { ChatEvent } from '../src/store/types'

type ToolCallEvent = Extract<ChatEvent, { kind: 'tool-call' }>

function makeEvent(overrides: Partial<ToolCallEvent> = {}): ToolCallEvent {
  return {
    id: 'tc1',
    kind: 'tool-call',
    name: 'run_applescript',
    args: { script: 'tell application "Finder" to activate' },
    status: 'running',
    turnId: 't1',
    ...overrides,
  } as ToolCallEvent
}

describe('ToolCallCard (T1-T5)', () => {
  it('T1: expand/collapse toggles aria-expanded', () => {
    const { container } = render(<ToolCallCard event={makeEvent()} />)
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.getAttribute('aria-expanded')).toBe('false')
    fireEvent.click(btn)
    expect(btn.getAttribute('aria-expanded')).toBe('true')
    fireEvent.click(btn)
    expect(btn.getAttribute('aria-expanded')).toBe('false')
  })

  it('T2: all 5 status labels render per spec', () => {
    const cases: Array<[ToolCallEvent['status'], string]> = [
      ['pending', 'Preparing'],
      ['running', 'Running'],
      ['awaiting-approval', 'Waiting for your approval'],
      ['completed', 'Done'],
      ['failed', 'Failed'],
    ]
    for (const [status, label] of cases) {
      const { container, unmount } = render(<ToolCallCard event={makeEvent({ status })} />)
      expect(container.textContent).toContain(label)
      unmount()
    }
  })

  it('T3: pre-approval hides args (sentinel) even with arbitrary args data present', () => {
    // Even if Swift side accidentally passed real args, the card MUST hide them
    // whenever status=='awaiting-approval' OR args.awaitingApproval===true.
    const ev = makeEvent({
      args: { awaitingApproval: true },
      status: 'awaiting-approval',
    })
    const { container } = render(<ToolCallCard event={ev} />)
    const btn = container.querySelector('button') as HTMLButtonElement
    fireEvent.click(btn)
    expect(container.textContent).toContain('(hidden until you approve)')
    // No leakage of secret-shaped data
    expect(container.textContent).not.toMatch(/tell application/)
  })

  it('T3b: even with awaiting-approval status alone (no sentinel), args are hidden', () => {
    // Defense-in-depth: plan says status === 'awaiting-approval' also hides args
    const ev = makeEvent({
      args: { script: 'dangerous' },
      status: 'awaiting-approval',
    })
    const { container } = render(<ToolCallCard event={ev} />)
    const btn = container.querySelector('button') as HTMLButtonElement
    fireEvent.click(btn)
    expect(container.textContent).toContain('(hidden until you approve)')
    expect(container.textContent).not.toContain('dangerous')
  })

  it('T4: completed state shows result on expand', () => {
    const ev = makeEvent({ status: 'completed', result: '42' })
    const { container } = render(<ToolCallCard event={ev} />)
    fireEvent.click(container.querySelector('button') as HTMLButtonElement)
    expect(container.textContent).toContain('42')
  })

  it('T5: failed state shows error on expand', () => {
    const ev = makeEvent({ status: 'failed', error: 'AppleScript timeout' })
    const { container } = render(<ToolCallCard event={ev} />)
    fireEvent.click(container.querySelector('button') as HTMLButtonElement)
    expect(container.textContent).toContain('AppleScript timeout')
  })
})
