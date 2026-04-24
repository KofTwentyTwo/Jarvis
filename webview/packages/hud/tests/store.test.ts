import { describe, it, expect, beforeEach } from 'vitest'
import { useJarvisStore } from '../src/store'
import type { ChatEvent } from '../src/store/types'

// Zustand store state is module-level; reset between tests to avoid leakage.
function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}

describe('useJarvisStore defaults', () => {
  beforeEach(() => resetStore())

  it('exposes the expected default slices', () => {
    const s = useJarvisStore.getState()
    expect(s.hudState).toBe('booting')
    expect(s.chatEvents).toEqual([])
    expect(s.a11y).toEqual({ reduceMotion: false, reduceTransparency: false })
    expect(s.theme).toEqual({ arcReactorGlow: '#1E88E5' })
    expect(s.connection).toBe('booting')
  })

  it('exposes all actions', () => {
    const s = useJarvisStore.getState()
    expect(typeof s.setHudState).toBe('function')
    expect(typeof s.pushEvent).toBe('function')
    expect(typeof s.appendTokenToLastText).toBe('function')
    expect(typeof s.upsertToolCall).toBe('function')
    expect(typeof s.setA11y).toBe('function')
    expect(typeof s.setTheme).toBe('function')
    expect(typeof s.setConnection).toBe('function')
  })
})

describe('setHudState isolates mutations (S2)', () => {
  beforeEach(() => resetStore())

  it('changes only hudState; chatEvents reference is stable', () => {
    const before = useJarvisStore.getState().chatEvents
    useJarvisStore.getState().setHudState('thinking')
    const after = useJarvisStore.getState()
    expect(after.hudState).toBe('thinking')
    // Reference equality: setState shallow-merged, didn't touch chatEvents.
    expect(after.chatEvents).toBe(before)
  })
})

describe('subscribeWithSelector selector granularity (S3)', () => {
  beforeEach(() => resetStore())

  it('hudState selector does not fire on chatEvents change', () => {
    let calls = 0
    const unsub = useJarvisStore.subscribe(
      (state) => state.hudState,
      () => {
        calls += 1
      },
    )
    const event: ChatEvent = {
      id: 'e1',
      kind: 'text',
      text: 'hi',
      role: 'user',
      turnId: 't1',
    }
    useJarvisStore.getState().pushEvent(event)
    expect(calls).toBe(0)

    useJarvisStore.getState().setHudState('listening')
    expect(calls).toBe(1)
    unsub()
  })
})

describe('appendTokenToLastText no-op on missing id (S4)', () => {
  beforeEach(() => resetStore())

  it('leaves chatEvents unchanged when id does not exist', () => {
    useJarvisStore.getState().appendTokenToLastText('does-not-exist', 'hi')
    expect(useJarvisStore.getState().chatEvents).toEqual([])
  })

  it('appends delta when text event with id exists', () => {
    const event: ChatEvent = {
      id: 'e1',
      kind: 'text',
      text: 'hello',
      role: 'assistant',
      turnId: 't1',
    }
    useJarvisStore.getState().pushEvent(event)
    useJarvisStore.getState().appendTokenToLastText('e1', ' world')
    const first = useJarvisStore.getState().chatEvents[0]
    expect(first?.kind).toBe('text')
    if (first && first.kind === 'text') {
      expect(first.text).toBe('hello world')
    }
  })
})
