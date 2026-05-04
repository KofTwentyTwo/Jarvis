import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import { CameraButton } from '../src/chat/CameraButton'
import { installJarvisBus } from '@jarvis/bus'

// Track-C 3 — closes vision-audit §4 "HUD button emitter has zero matches".
// The Swift inbound handler in App/AppDelegate.swift:1696-1698 routes
// `BusInbound.frameAttachRequested` into `FrameAttachController.requestAttach
// (reason: .hudButton)`. These tests assert the JS producer side.

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
      /* skip */
    }
  }
  return null
}

describe('CameraButton (CB1-CB3) — closes vision-audit §4 HUD emitter gap', () => {
  beforeEach(() => {
    clearBus()
  })

  it('CB1: renders an accessible button', () => {
    installWebkitMock()
    installJarvisBus()
    const { getByRole } = render(<CameraButton />)
    const btn = getByRole('button', { name: /attach camera frame/i })
    expect(btn).toBeDefined()
  })

  it('CB2: click posts BusInbound.frameAttachRequested', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    const { getByRole } = render(<CameraButton />)
    fireEvent.click(getByRole('button', { name: /attach camera frame/i }))
    const sent = findInbound(mock, 'frameAttachRequested')
    expect(sent).not.toBeNull()
    expect(sent?.type).toBe('frameAttachRequested')
  })

  it('CB3: the message body has no payload (cardinal frameAttachRequested shape)', () => {
    const mock = installWebkitMock()
    installJarvisBus()
    const { getByRole } = render(<CameraButton />)
    fireEvent.click(getByRole('button', { name: /attach camera frame/i }))
    const sent = findInbound(mock, 'frameAttachRequested')
    expect(sent).not.toBeNull()
    // Only `type` — matches `case frameAttachRequested` (no associated value)
    // in packages/Bus/Sources/Bus/BusInbound.swift.
    expect(Object.keys(sent ?? {})).toEqual(['type'])
  })
})
