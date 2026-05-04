import type { BusInbound } from '@jarvis/bus'

/**
 * CameraButton — JS-side producer of `BusInbound.frameAttachRequested`.
 *
 * Closes Track-C 3 (vision-audit §4): pre-CameraButton, the bus protocol
 * declared `frameAttachRequested` and the Swift inbound handler routed it
 * into `FrameAttachController.requestAttach(reason: .hudButton)`, but no
 * React component dispatched it. Now the user has a clickable affordance.
 *
 * Keeping this stateless and small — no preview modal, no captured-frame
 * UI yet. Firing `frameAttachRequested` arms the Swift controller, which
 * runs CameraCapture.captureFrame() and parks the frame in its
 * pendingFrame slot. The default-cancel timeout (D-14) discards the frame
 * if the user does nothing else; the chat-input "Send" path picks the
 * frame up via the AppDelegate confirm/submit wiring (Track-C 5).
 */
export function CameraButton() {
  function handleClick() {
    const msg: BusInbound = { type: 'frameAttachRequested' }
    void window.jarvisBus.send(msg).catch((err: unknown) => {
      // eslint-disable-next-line no-console
      console.error('[camera] send failed:', err)
    })
  }

  return (
    <button
      type="button"
      className="camera-button"
      aria-label="Attach camera frame"
      title="Attach a camera frame to your next message"
      onClick={handleClick}
    >
      Camera
    </button>
  )
}
