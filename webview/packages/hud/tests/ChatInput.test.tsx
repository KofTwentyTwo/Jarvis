import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import { ChatInput } from '../src/chat/ChatInput'
import { useJarvisStore } from '../src/store'
import { installJarvisBus } from '@jarvis/bus'

// Closes BLOCKER-INT-3. The Swift inbound side (AppDelegate.swift:1444-1449)
// already routes BusInbound.chatSubmit / .chatCancelAndSubmit into
// AgentOrchestrator. These tests assert the JS producer side: an actual input
// the user can type into, a submit path that posts the right BusInbound, and
// a local user-text echo so chronology shows what the user typed.

function resetStore() {
  useJarvisStore.setState({
    hudState: 'idle',
    chatEvents: [],
    currentTurnId: null,
    activeTextPartId: null,
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'ready',
  })
}

type Postable = (body: unknown) => Promise<unknown>

function installWebkitMock() {
  const postMessage = vi.fn<Postable>(async () => undefined)
  ;(window as unknown as {
    webkit: { messageHandlers: { jarvisBus: { postMessage: Postable } } }
  }).webkit = {
    messageHandlers: { jarvisBus: { postMessage } },
  }
  return { postMessage }
}

function clearBus() {
  delete (window as unknown as { jarvisBus?: unknown }).jarvisBus
}

function findInbound(
  mock: ReturnType<typeof installWebkitMock>,
  type: string,
): Record<string, unknown> | null {
  for (const args of mock.postMessage.mock.calls) {
    const body = args[0]
    if (typeof body !== 'string') continue
    try {
      const parsed = JSON.parse(body) as Record<string, unknown>
      if (parsed?.type === type) return parsed
    } catch {
      /* skip non-JSON */
    }
  }
  return null
}

describe('ChatInput (CI1-CI6) — closes BLOCKER-INT-3', () => {
  beforeEach(() => {
    resetStore()
    clearBus()
  })

  it('CI1: renders an input and a submit button', () => {
    installWebkitMock()
    installJarvisBus()
    const { container, getByRole } = render(<ChatInput />)
    expect(container.querySelector('input[type="text"]')).not.toBeNull()
    expect(getByRole('button', { name: /send/i })).toBeDefined()
  })

  it('CI2: empty / whitespace-only input does NOT post and does NOT push event', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    const { getByRole, container } = render(<ChatInput />)
    const input = container.querySelector('input[type="text"]') as HTMLInputElement
    fireEvent.change(input, { target: { value: '   ' } })
    fireEvent.click(getByRole('button', { name: /send/i }))
    expect(findInbound(mock, 'chatSubmit')).toBeNull()
    expect(findInbound(mock, 'chatCancelAndSubmit')).toBeNull()
    expect(useJarvisStore.getState().chatEvents.length).toBe(0)
  })

  it('CI3: typing + click submit posts chatSubmit with trimmed text and clears input', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    const { container, getByRole } = render(<ChatInput />)
    const input = container.querySelector('input[type="text"]') as HTMLInputElement
    fireEvent.change(input, { target: { value: '  hello jarvis  ' } })
    fireEvent.click(getByRole('button', { name: /send/i }))
    const sent = findInbound(mock, 'chatSubmit')
    expect(sent).not.toBeNull()
    expect(sent?.text).toBe('hello jarvis')
    expect(input.value).toBe('')
  })

  it('CI4: enter key (form submit) posts chatSubmit', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    const { container } = render(<ChatInput />)
    const input = container.querySelector('input[type="text"]') as HTMLInputElement
    const form = container.querySelector('form') as HTMLFormElement
    fireEvent.change(input, { target: { value: 'hi' } })
    fireEvent.submit(form)
    expect(findInbound(mock, 'chatSubmit')?.text).toBe('hi')
  })

  it('CI5: pushes a user-role text event into chatEvents on submit', () => {
    installWebkitMock()
    installJarvisBus()
    const { container, getByRole } = render(<ChatInput />)
    const input = container.querySelector('input[type="text"]') as HTMLInputElement
    fireEvent.change(input, { target: { value: 'good morning' } })
    fireEvent.click(getByRole('button', { name: /send/i }))
    const events = useJarvisStore.getState().chatEvents
    expect(events.length).toBe(1)
    const ev = events[0]
    expect(ev?.kind).toBe('text')
    if (ev && ev.kind === 'text') {
      expect(ev.role).toBe('user')
      expect(ev.text).toBe('good morning')
    }
  })

  it('CI6: while a turn is active, posts chatCancelAndSubmit (barge-in) instead of chatSubmit', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    useJarvisStore.setState({ currentTurnId: 't-active' })
    const { container, getByRole } = render(<ChatInput />)
    const input = container.querySelector('input[type="text"]') as HTMLInputElement
    fireEvent.change(input, { target: { value: 'stop and listen' } })
    fireEvent.click(getByRole('button', { name: /send/i }))
    expect(findInbound(mock, 'chatCancelAndSubmit')?.text).toBe('stop and listen')
    expect(findInbound(mock, 'chatSubmit')).toBeNull()
  })
})
