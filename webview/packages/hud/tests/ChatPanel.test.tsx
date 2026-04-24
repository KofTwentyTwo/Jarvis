import { describe, it, expect, beforeEach } from 'vitest'
import { render, act } from '@testing-library/react'
import { ChatPanel } from '../src/chat/ChatPanel'
import { useJarvisStore } from '../src/store'
import type { ChatEvent } from '../src/store/types'

// Keep the module-level store reset between tests so event ordering assertions
// don't leak across cases.
function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}

describe('ChatPanel (C1-C3, TP1-TP2)', () => {
  beforeEach(() => resetStore())

  it('C1: empty state renders role=log + aria-live=polite with no children', () => {
    const { container } = render(<ChatPanel />)
    const log = container.querySelector('[role="log"]')
    expect(log).not.toBeNull()
    expect(log?.getAttribute('aria-live')).toBe('polite')
    expect(log?.children.length).toBe(0)
  })

  it('C2: preserves chronological order of chatEvents in DOM', () => {
    const events: ChatEvent[] = [
      { id: 'e1', kind: 'text', text: 'first', role: 'assistant', turnId: 't1' },
      { id: 'e2', kind: 'tool-call', name: 'get_time', args: {}, status: 'running', turnId: 't1' },
      { id: 'e3', kind: 'text', text: 'second', role: 'assistant', turnId: 't1' },
    ]
    act(() => {
      useJarvisStore.setState({ chatEvents: events })
    })
    const { container } = render(<ChatPanel />)
    const log = container.querySelector('[role="log"]')!
    const children = Array.from(log.children) as HTMLElement[]
    expect(children.length).toBe(3)
    expect(children[0]?.getAttribute('data-chat-event-kind')).toBe('text')
    expect(children[1]?.getAttribute('data-chat-event-kind')).toBe('tool-call')
    expect(children[2]?.getAttribute('data-chat-event-kind')).toBe('text')
    expect(children[0]?.textContent).toContain('first')
    expect(children[2]?.textContent).toContain('second')
  })

  it('C3: ChatEventRouter discriminates by kind', () => {
    const events: ChatEvent[] = [
      { id: 't', kind: 'text', text: 'msg', role: 'assistant', turnId: 't1' },
      { id: 'tc', kind: 'tool-call', name: 'noop', args: {}, status: 'completed', turnId: 't1' },
      { id: 'err', kind: 'error', message: 'bang', turnId: 't1' },
    ]
    act(() => {
      useJarvisStore.setState({ chatEvents: events })
    })
    const { container } = render(<ChatPanel />)
    expect(container.querySelector('[data-chat-event-kind="text"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-event-kind="tool-call"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-event-kind="error"]')).not.toBeNull()
  })

  it('TP1: TextPart renders event.text verbatim', () => {
    const events: ChatEvent[] = [
      { id: 'e1', kind: 'text', text: 'hello world', role: 'assistant', turnId: 't1' },
    ]
    act(() => {
      useJarvisStore.setState({ chatEvents: events })
    })
    const { container } = render(<ChatPanel />)
    expect(container.textContent).toContain('hello world')
  })

  it('TP2: streaming via appendTokenToLastText accumulates text without re-keying', () => {
    const base: ChatEvent = {
      id: 'turn:t1:assistant',
      kind: 'text',
      text: '',
      role: 'assistant',
      turnId: 't1',
    }
    act(() => {
      useJarvisStore.setState({ chatEvents: [base] })
    })
    const { container, rerender } = render(<ChatPanel />)
    const initialTextEl = container.querySelector('[data-chat-event-kind="text"]') as HTMLElement
    expect(initialTextEl).not.toBeNull()

    for (const delta of ['h', 'e', 'l', 'l', 'o']) {
      act(() => {
        useJarvisStore.getState().appendTokenToLastText('turn:t1:assistant', delta)
      })
      rerender(<ChatPanel />)
    }
    const finalTextEl = container.querySelector('[data-chat-event-kind="text"]') as HTMLElement
    expect(finalTextEl.textContent).toContain('hello')
    // Same DOM node across streaming updates (React reuses via stable key)
    expect(finalTextEl).toBe(initialTextEl)
  })
})
