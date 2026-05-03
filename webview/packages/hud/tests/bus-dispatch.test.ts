import { describe, it, expect, beforeEach, vi } from 'vitest'
import { useJarvisStore } from '../src/store'
import { attachBus } from '../src/bus/client'

// Each test resets window.jarvisBus + window.webkit mocks. attachBus() installs
// the bridge; we then call window.jarvisBus.receive(payload) to simulate Swift
// pushing a BusOutbound into the page. Both attachBus and useJarvisStore are
// statically imported so they share the same module graph / store singleton.
function resetStore() {
  useJarvisStore.setState({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',
  })
}

type WebkitHandlerShape = {
  postMessage: (body: unknown) => Promise<unknown>
}

function installWebkitMock(): { postMessage: ReturnType<typeof vi.fn> } {
  const postMessage = vi.fn<(body: unknown) => Promise<unknown>>(async () => undefined)
  ;(window as unknown as { webkit: { messageHandlers: { jarvisBus: WebkitHandlerShape } } }).webkit =
    {
      messageHandlers: {
        jarvisBus: { postMessage: postMessage as unknown as (b: unknown) => Promise<unknown> },
      },
    }
  return { postMessage }
}

function resetDom() {
  // Remove any #root from previous tests and recreate it via safe DOM methods.
  while (document.body.firstChild) {
    document.body.removeChild(document.body.firstChild)
  }
  const root = document.createElement('div')
  root.id = 'root'
  document.body.appendChild(root)
}

function clearBus() {
  delete (window as unknown as { jarvisBus?: unknown }).jarvisBus
}

describe('bus dispatcher — hudState routes to store (B1)', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
  })

  it('hudState outbound sets store.hudState', () => {
    attachBus()
    window.jarvisBus.receive('{"type":"hudState","state":"speaking"}')
    expect(useJarvisStore.getState().hudState).toBe('speaking')
  })

  it('hudState listening transitions', () => {
    attachBus()
    window.jarvisBus.receive('{"type":"hudState","state":"listening"}')
    expect(useJarvisStore.getState().hudState).toBe('listening')
    window.jarvisBus.receive('{"type":"hudState","state":"idle"}')
    expect(useJarvisStore.getState().hudState).toBe('idle')
  })
})

describe('bus dispatcher — submitRejected pushes error event (B5)', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
  })

  it('renders a rejection reason as an inline error event', () => {
    attachBus()
    window.jarvisBus.receive(
      '{"type":"submitRejected","reason":"Local model unreachable."}',
    )
    const events = useJarvisStore.getState().chatEvents
    expect(events.length).toBe(1)
    const ev = events[0]
    expect(ev?.kind).toBe('error')
    if (ev?.kind === 'error') {
      expect(ev.message).toBe('Local model unreachable.')
    }
  })
})

describe('bus dispatcher — decode errors surface (B2)', () => {
  beforeEach(() => {
    resetStore()
    installWebkitMock()
    clearBus()
  })

  it('invalid JSON fires the console error path', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    attachBus()
    window.jarvisBus.receive('not-json-at-all')
    expect(errSpy).toHaveBeenCalled()
    const firstCall = errSpy.mock.calls[0]
    // Error message is 2nd arg (1st is the '[bus] decode failed:' prefix)
    const errArg = firstCall?.[1]
    expect(typeof errArg === 'string' && errArg.startsWith('parse error')).toBe(true)
    errSpy.mockRestore()
  })

  it('object without discriminator fires the error path', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    attachBus()
    window.jarvisBus.receive('{"foo":"bar"}')
    expect(errSpy).toHaveBeenCalled()
    const errArg = errSpy.mock.calls[0]?.[1]
    expect(errArg).toBe('missing discriminator')
    errSpy.mockRestore()
  })
})

describe('main.tsx boot posts uiReady (B3)', () => {
  beforeEach(() => {
    resetStore()
    resetDom()
    clearBus()
    vi.resetModules()
  })

  it('posts uiReady after first React commit', async () => {
    const mock = installWebkitMock()
    // Dynamic import intentionally: main.tsx has top-level side effects
    // (attachBus + React mount + uiReady microtask). Isolating via
    // resetModules ensures the side effects run once per test.
    await import('../src/main')
    // Flush the microtask queued by main.tsx
    await new Promise((r) => queueMicrotask(() => r(undefined)))
    await new Promise((r) => setTimeout(r, 0))

    const calls = mock.postMessage.mock.calls
    const uiReadyCall = calls.find((args) => {
      const body = args[0]
      return typeof body === 'string' && body.includes('uiReady')
    })
    expect(uiReadyCall).toBeDefined()
  })
})

// Exhaustiveness proof (documentation). To verify the `_exhaustive: never`
// sentinel bites, locally add a synthetic case like
// `| { type: 'futureCase'; data: string }` to the BusOutbound union and run
// `pnpm --filter @jarvis/hud typecheck`. You should see TS2322 on
// `const _exhaustive: never = msg` in src/bus/client.ts. This test file does
// NOT mutate the @jarvis/bus union — the sentinel is a compile-time guard.
describe('bus dispatcher exhaustiveness sentinel (B4, compile-time)', () => {
  it('documents the manual probe', () => {
    expect(true).toBe(true)
  })
})
