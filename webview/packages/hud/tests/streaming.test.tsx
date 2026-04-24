import { describe, it, expect, beforeEach, vi } from 'vitest'
import { useJarvisStore } from '../src/store'
import { attachBus } from '../src/bus/client'

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

describe('store slices (S1): currentTurnId, activeTextPartId, beginTurn, endTurn', () => {
  beforeEach(() => resetStore())

  it('has currentTurnId and activeTextPartId null by default', () => {
    const s = useJarvisStore.getState()
    expect(s.currentTurnId).toBeNull()
    expect(s.activeTextPartId).toBeNull()
  })

  it('beginTurn sets currentTurnId and clears activeTextPartId', () => {
    useJarvisStore.setState({ activeTextPartId: 'stale' })
    useJarvisStore.getState().beginTurn('t1')
    expect(useJarvisStore.getState().currentTurnId).toBe('t1')
    expect(useJarvisStore.getState().activeTextPartId).toBeNull()
  })

  it('endTurn clears both', () => {
    useJarvisStore.setState({ currentTurnId: 't1', activeTextPartId: 'turn:t1:assistant' })
    useJarvisStore.getState().endTurn()
    expect(useJarvisStore.getState().currentTurnId).toBeNull()
    expect(useJarvisStore.getState().activeTextPartId).toBeNull()
  })
})

describe('bus dispatcher streaming (D1-D8)', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
    attachBus()
  })

  it('D1: tokenDelta synthesizes text-part with deterministic id', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({ type: 'tokenDelta', text: 'he' })
    const events = useJarvisStore.getState().chatEvents
    expect(events).toHaveLength(1)
    const first = events[0]
    expect(first?.kind).toBe('text')
    if (first?.kind === 'text') {
      expect(first.id).toBe('turn:t1:assistant')
      expect(first.text).toBe('he')
      expect(first.role).toBe('assistant')
      expect(first.turnId).toBe('t1')
    }
  })

  it('D2: subsequent tokenDeltas append to same text-part', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({ type: 'tokenDelta', text: 'he' })
    send({ type: 'tokenDelta', text: 'llo' })
    const events = useJarvisStore.getState().chatEvents
    expect(events).toHaveLength(1)
    const first = events[0]
    if (first?.kind === 'text') {
      expect(first.text).toBe('hello')
    }
  })

  it('D3: turnEnded resolves the turn (clears tracking, keeps event)', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({ type: 'tokenDelta', text: 'hello' })
    send({ type: 'turnEnded', id: 't1', terminator: 'completed' })
    const s = useJarvisStore.getState()
    expect(s.chatEvents).toHaveLength(1)
    expect(s.currentTurnId).toBeNull()
    expect(s.activeTextPartId).toBeNull()
  })

  it('D4: new turn starts a new text-part with new id', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({ type: 'tokenDelta', text: 'hello' })
    send({ type: 'turnEnded', id: 't1', terminator: 'completed' })
    send({ type: 'turnStarted', id: 't2' })
    send({ type: 'tokenDelta', text: 'world' })
    const events = useJarvisStore.getState().chatEvents
    expect(events).toHaveLength(2)
    expect(events[0]?.id).toBe('turn:t1:assistant')
    expect(events[1]?.id).toBe('turn:t2:assistant')
  })

  it('D5: toolCallStart with awaitingApproval sentinel sets status awaiting-approval', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({
      type: 'toolCallStart',
      id: 'tc1',
      name: 'run_applescript',
      argsPreview: '{"awaitingApproval":true}',
    })
    const events = useJarvisStore.getState().chatEvents
    const tc = events.find((e) => e.kind === 'tool-call')
    expect(tc).toBeDefined()
    if (tc?.kind === 'tool-call') {
      expect(tc.status).toBe('awaiting-approval')
      expect(tc.args).toEqual({ awaitingApproval: true })
    }
  })

  it('D6: toolCallStart without sentinel sets status running', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({
      type: 'toolCallStart',
      id: 'tc2',
      name: 'get_time',
      argsPreview: '{}',
    })
    const tc = useJarvisStore
      .getState()
      .chatEvents.find((e) => e.kind === 'tool-call')
    expect(tc).toBeDefined()
    if (tc?.kind === 'tool-call') {
      expect(tc.status).toBe('running')
    }
  })

  it('D7: toolCallEnd ok=true transitions to completed with result', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({
      type: 'toolCallStart',
      id: 'tc2',
      name: 'get_time',
      argsPreview: '{}',
    })
    send({
      type: 'toolCallEnd',
      id: 'tc2',
      ok: true,
      previewOrError: '2026-04-22T12:00:00Z',
    })
    const tc = useJarvisStore
      .getState()
      .chatEvents.find((e) => e.kind === 'tool-call')
    if (tc?.kind === 'tool-call') {
      expect(tc.status).toBe('completed')
      expect(tc.result).toBe('2026-04-22T12:00:00Z')
      expect(tc.error).toBeUndefined()
    }
  })

  it('D8: toolCallEnd ok=false transitions to failed with error', () => {
    send({ type: 'turnStarted', id: 't1' })
    send({
      type: 'toolCallStart',
      id: 'tc3',
      name: 'run_applescript',
      argsPreview: '{}',
    })
    send({
      type: 'toolCallEnd',
      id: 'tc3',
      ok: false,
      previewOrError: 'timeout',
    })
    const tc = useJarvisStore
      .getState()
      .chatEvents.find((e) => e.kind === 'tool-call')
    if (tc?.kind === 'tool-call') {
      expect(tc.status).toBe('failed')
      expect(tc.error).toBe('timeout')
      expect(tc.result).toBeUndefined()
    }
  })

  it('I1: replaying the fixture twice converges to the same state', async () => {
    // Deep-equal final chatEvents across two replays proves idempotency
    // (no duplicate append, no stale state leakage).
    const fixture = (
      await import('./fixtures/streaming-fixture.json', {
        with: { type: 'json' },
      })
    ).default as Array<Record<string, unknown>>

    for (const msg of fixture) send(msg)
    const firstRun = JSON.parse(JSON.stringify(useJarvisStore.getState().chatEvents))

    resetStore()
    for (const msg of fixture) send(msg)
    const secondRun = JSON.parse(JSON.stringify(useJarvisStore.getState().chatEvents))

    expect(secondRun).toEqual(firstRun)
  })
})
