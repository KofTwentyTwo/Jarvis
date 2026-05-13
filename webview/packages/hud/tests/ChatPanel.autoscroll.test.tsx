import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import { ChatPanel } from '../src/chat/ChatPanel'
import { useJarvisStore } from '../src/store'
import type { ChatEvent } from '../src/store/types'

/**
 * B-06 (issue #51) — tactical auto-scroll fix.
 *
 * Goal: ChatPanel scrolls to its latest content as streaming tokens arrive,
 * so the user does not have to manually scroll while the agent is speaking.
 *
 * Heuristic: only auto-scroll when the user is already "near the bottom"
 * (within a small threshold). If they have scrolled up to re-read, don't
 * yank them back to the bottom.
 *
 * JSDOM observability note: JSDOM does not lay out, so `scrollHeight` /
 * `clientHeight` / `scrollTop` are 0 by default. The tests below stub those
 * properties on the scroll container so we can assert the auto-scroll
 * effect's decision logic — which is the behavior under test. Empirical
 * pixel-level scroll verification is deferred to the M-7 typed-API work
 * (per the issue's own scope note).
 */

function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}

// Stub layout properties on an element. JSDOM treats these as ordinary
// getters; redefining lets us simulate a scrollable container.
function stubLayout(
  el: HTMLElement,
  opts: { scrollHeight: number; clientHeight: number; scrollTopGetter: () => number },
) {
  Object.defineProperty(el, 'scrollHeight', {
    configurable: true,
    get: () => opts.scrollHeight,
  })
  Object.defineProperty(el, 'clientHeight', {
    configurable: true,
    get: () => opts.clientHeight,
  })
  Object.defineProperty(el, 'scrollTop', {
    configurable: true,
    get: opts.scrollTopGetter,
    set: () => {
      /* mutation handled by stubScrollTo */
    },
  })
}

function getPanel(container: HTMLElement): HTMLElement {
  const el = container.querySelector('[role="log"]') as HTMLElement | null
  if (!el) throw new Error('chat-panel not found')
  return el
}

describe('ChatPanel auto-scroll on streaming append (B-06 / #51)', () => {
  beforeEach(() => resetStore())

  it('AS1: scrolls to bottom when a new chat event is appended and user is at bottom', () => {
    // Start empty so we can attach stubs to the panel element before any
    // streaming-driven layout queries happen.
    const { container } = render(<ChatPanel />)
    const panel = getPanel(container)

    const scrollToSpy = vi.fn()
    panel.scrollTo = scrollToSpy as unknown as typeof panel.scrollTo

    // User is at the bottom: scrollTop + clientHeight == scrollHeight.
    stubLayout(panel, {
      scrollHeight: 1000,
      clientHeight: 200,
      scrollTopGetter: () => 800,
    })

    act(() => {
      useJarvisStore.setState({
        chatEvents: [
          { id: 'e1', kind: 'text', text: 'hello', role: 'assistant', turnId: 't1' },
        ] as ChatEvent[],
      })
    })

    expect(scrollToSpy).toHaveBeenCalled()
    const arg = scrollToSpy.mock.calls.at(-1)?.[0] as ScrollToOptions
    expect(arg.top).toBe(1000)
  })

  it('AS2: scrolls on streaming token append (same event, growing text)', () => {
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
    const panel = getPanel(container)
    const scrollToSpy = vi.fn()
    panel.scrollTo = scrollToSpy as unknown as typeof panel.scrollTo

    // Simulate a growing scrollHeight as tokens stream in.
    let scrollHeight = 1000
    Object.defineProperty(panel, 'scrollHeight', {
      configurable: true,
      get: () => scrollHeight,
    })
    Object.defineProperty(panel, 'clientHeight', {
      configurable: true,
      get: () => 200,
    })
    Object.defineProperty(panel, 'scrollTop', {
      configurable: true,
      get: () => scrollHeight - 200, // pinned to bottom
      set: () => {
        /* noop */
      },
    })

    scrollToSpy.mockClear()
    for (const delta of ['h', 'e', 'l', 'l', 'o']) {
      scrollHeight += 20
      act(() => {
        useJarvisStore.getState().appendTokenToLastText('turn:t1:assistant', delta)
      })
      rerender(<ChatPanel />)
    }

    // Once per token append.
    expect(scrollToSpy.mock.calls.length).toBeGreaterThanOrEqual(5)
    const lastArg = scrollToSpy.mock.calls.at(-1)?.[0] as ScrollToOptions
    expect(lastArg.top).toBe(scrollHeight)
  })

  it('AS3: does NOT scroll when user has scrolled up away from the bottom', () => {
    const { container } = render(<ChatPanel />)
    const panel = getPanel(container)
    const scrollToSpy = vi.fn()
    panel.scrollTo = scrollToSpy as unknown as typeof panel.scrollTo

    // User scrolled up: 500 px below the bottom (way beyond the small
    // hysteresis threshold used by the auto-scroll effect).
    stubLayout(panel, {
      scrollHeight: 1000,
      clientHeight: 200,
      scrollTopGetter: () => 300, // 1000 - 200 - 300 = 500 px from bottom
    })

    act(() => {
      useJarvisStore.setState({
        chatEvents: [
          { id: 'e1', kind: 'text', text: 'noisy', role: 'assistant', turnId: 't1' },
        ] as ChatEvent[],
      })
    })

    expect(scrollToSpy).not.toHaveBeenCalled()
  })

  it('AS4: resumes auto-scroll once the user scrolls back to the bottom', () => {
    const { container } = render(<ChatPanel />)
    const panel = getPanel(container)
    const scrollToSpy = vi.fn()
    panel.scrollTo = scrollToSpy as unknown as typeof panel.scrollTo

    // Start scrolled up — `scrollTop` is mutable here so we can simulate
    // the user scrolling back to the bottom between content updates.
    // The implementation re-measures DOM at the moment of each content
    // change, so no manual `scroll` event dispatch is needed for pin
    // state to update.
    let scrollTop = 300
    stubLayout(panel, {
      scrollHeight: 1000,
      clientHeight: 200,
      scrollTopGetter: () => scrollTop,
    })

    act(() => {
      useJarvisStore.setState({
        chatEvents: [
          { id: 'e1', kind: 'text', text: 'first', role: 'assistant', turnId: 't1' },
        ] as ChatEvent[],
      })
    })
    expect(scrollToSpy).not.toHaveBeenCalled()

    // User scrolled back to the bottom. Next content update re-measures
    // distanceFromBottom = 0 and resumes auto-scroll.
    scrollTop = 800

    act(() => {
      useJarvisStore.setState({
        chatEvents: [
          { id: 'e1', kind: 'text', text: 'first', role: 'assistant', turnId: 't1' },
          { id: 'e2', kind: 'text', text: 'second', role: 'assistant', turnId: 't1' },
        ] as ChatEvent[],
      })
    })

    expect(scrollToSpy).toHaveBeenCalled()
  })
})
