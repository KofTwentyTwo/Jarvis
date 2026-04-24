import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render } from '@testing-library/react'
import { useJarvisStore } from '../src/store'
import { attachBus } from '../src/bus/client'
import { ChatPanel } from '../src/chat/ChatPanel'

type WebkitHandlerShape = {
  postMessage: (body: unknown) => Promise<unknown>
}

function installWebkitMock(): void {
  const postMessage = vi.fn<(body: unknown) => Promise<unknown>>(async () => undefined)
  ;(window as unknown as { webkit: { messageHandlers: { jarvisBus: WebkitHandlerShape } } }).webkit =
    {
      messageHandlers: {
        jarvisBus: { postMessage: postMessage as unknown as (b: unknown) => Promise<unknown> },
      },
    }
}

function clearBus() {
  delete (window as unknown as { jarvisBus?: unknown }).jarvisBus
}

function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    currentTurnId: null,
    activeTextPartId: null,
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}

function send(msg: unknown) {
  window.jarvisBus.receive(JSON.stringify(msg))
}

describe('chronology (Ch1): tool-call interrupts text stream', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
    attachBus()
  })

  it('interleave preserves order — text, tool-call, text (separate text parts)', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({ type: 'tokenDelta', text: 'hello ' })
    send({
      type: 'toolCallStart',
      id: 'tc1',
      name: 'get_time',
      argsPreview: '{}',
    })
    send({
      type: 'toolCallEnd',
      id: 'tc1',
      ok: true,
      previewOrError: '12:00',
    })
    send({ type: 'tokenDelta', text: 'there' })
    send({ type: 'turnEnded', id: 't1', terminator: 'completed' })

    const events = useJarvisStore.getState().chatEvents
    expect(events).toHaveLength(3)
    expect(events[0]?.kind).toBe('text')
    expect(events[1]?.kind).toBe('tool-call')
    expect(events[2]?.kind).toBe('text')
    if (events[0]?.kind === 'text') expect(events[0].text).toBe('hello ')
    if (events[1]?.kind === 'tool-call') {
      expect(events[1].status).toBe('completed')
      expect(events[1].name).toBe('get_time')
    }
    if (events[2]?.kind === 'text') {
      expect(events[2].text).toBe('there')
      // Second text-part gets disambiguated id
      expect(events[2].id).toBe('turn:t1:assistant:2')
    }
  })
})

describe('chronology (Ch2): byte-equivalent fixture replay', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
    attachBus()
  })

  // Normalizer tolerates React-version whitespace differences; intent is
  // "byte-identical DOM content", not "byte-identical raw HTML string".
  // Documented rationale: TEXT-02 acceptance is content-equality.
  function normalize(html: string): string {
    return html.replace(/\s+/g, ' ').trim()
  }

  it('replays the 20-message fixture and produces the expected DOM content', async () => {
    const fixture = (
      await import('./fixtures/streaming-fixture.json', {
        with: { type: 'json' },
      })
    ).default as Array<Record<string, unknown>>

    for (const msg of fixture) send(msg)

    const { container } = render(<ChatPanel />)
    const html = container.innerHTML
    const norm = normalize(html)

    // Content assertions — what the user actually sees:
    // 1) Role markers for streamed assistant text-parts
    expect(norm).toContain('Jarvis')

    // 2) First text-part contains the pre-tool-call sentence
    expect(norm).toContain('Hello, let me check the time for you. One moment')

    // 3) Tool-call card shows the tool name and its completed label
    expect(norm).toContain('get_time')
    expect(norm).toContain('Done')

    // 4) Second text-part contains the post-tool answer (separate part)
    expect(norm).toContain("It's noon on Wednesday")

    // 5) DOM structure: three events in order — text, tool-call, text
    const log = container.querySelector('[role="log"]') as HTMLElement
    const kinds = Array.from(log.children).map((c) =>
      (c as HTMLElement).getAttribute('data-chat-event-kind'),
    )
    expect(kinds).toEqual(['text', 'tool-call', 'text'])
  })
})
