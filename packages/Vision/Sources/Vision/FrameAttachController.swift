import Foundation
import AgentCore

/// Plan 07-05 / D-13 + D-14 + D-15 — frame-attach lifecycle owner.
///
/// **Surface:**
///   - `requestAttach(reason:)` — single ingest entry point. Reachable from
///     EITHER (a) `ContextBuilder.matchesFrameAttachPhrase` upstream, or
///     (b) the HUD camera-icon Bus message. Both producers reach this same
///     method (D-13 dual-trigger contract).
///   - `confirmSend(userText:)` — user explicitly chose `[Send]`. Returns
///     an `ImageBlock` that the orchestrator submits to `VisionRouter`.
///   - `cancel()` — user explicitly chose `[Cancel]`. Discards immediately.
///   - `onAssistantTurnComplete()` — drive-by from the orchestrator after
///     `LLMEvent.messageStop` has flushed. Releases the in-memory bytes
///     via `discardFrame()` (D-15).
///
/// **SOLE EMISSION SITE — D-15.** The `discardFrame()` function is the
/// ONLY place in this file that clears the pendingFrame slot. Every
/// release path (cancel, timeout, assistant-turn-complete) routes through
/// that single function. `FrameAttachDiscardSiteGrepTests` enforces this
/// invariant via a structural grep gate.
public actor FrameAttachController {

    // MARK: - Public dependencies (test-injectable)

    public protocol CaptureSource: Sendable {
        func captureFrame() async throws -> CapturedFrame
    }

    public protocol ReplaySink: Sendable {
        func recordImageTurn(text: String) async
    }

    public enum AttachReason: Sendable, Equatable {
        case phraseDetected(in: String)
        case hudButton
    }

    // MARK: - State

    private let captureSession: any CaptureSource
    private let replaySink: any ReplaySink
    private let config: VisionRouterConfig

    private var pendingFrame: CapturedFrame?
    private var lastAttachReason: AttachReason?
    private(set) public var lastDecision: FrameConfirmationDecision?
    private var pendingTimeoutTask: Task<Void, Never>?

    public init(
        captureSession: any CaptureSource,
        replaySink: any ReplaySink,
        config: VisionRouterConfig = .default
    ) {
        self.captureSession = captureSession
        self.replaySink = replaySink
        self.config = config
    }

    public var hasPendingFrame: Bool { pendingFrame != nil }

    // MARK: - Entry point (D-13 dual-trigger ingest)

    /// SINGLE ENTRY POINT — both phrase detection (ContextBuilder) and the
    /// HUD camera-icon Bus message route here. There is no other public
    /// surface that places a frame in the pending slot.
    public func requestAttach(reason: AttachReason) async {
        // Cancel any in-flight confirmation timeout from a prior request.
        pendingTimeoutTask?.cancel()
        lastAttachReason = reason
        lastDecision = nil

        do {
            let frame = try await captureSession.captureFrame()
            pendingFrame = frame
        } catch {
            // Capture failed — route through the SOLE emission site so the
            // single-emission-site invariant holds even on the error path.
            discardFrame()
            return
        }

        // Arm the default-cancel timeout (D-14, ~2s). If the user neither
        // confirms nor explicitly cancels in time, the controller fires
        // `.timeout` and discards the frame.
        let timeout = config.frameConfirmTimeout
        pendingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return  // cancelled — confirmSend or cancel() superseded us
            }
            if Task.isCancelled { return }
            await self?.timeoutFired()
        }
    }

    // MARK: - User decisions (D-14 always-confirm)

    /// User chose [Send]. Returns the ImageBlock the orchestrator submits.
    /// Returns nil if no frame is pending (defensive — UI should not call
    /// this out of order).
    public func confirmSend(userText: String) async -> ImageBlock? {
        guard let frame = pendingFrame else { return nil }
        pendingTimeoutTask?.cancel()
        lastDecision = .send
        // Record placeholder in replay BEFORE returning the block — the
        // raw bytes never enter the replay sink (D-15 invariant).
        await replaySink.recordImageTurn(text: userText)
        return ImageBlock(mediaType: "image/jpeg", data: frame.jpegData)
    }

    /// User chose [Cancel]. Discard immediately.
    public func cancel() async {
        pendingTimeoutTask?.cancel()
        lastDecision = .cancel
        discardFrame()
    }

    /// Default-cancel timeout fired (~2s with no user action).
    private func timeoutFired() {
        guard pendingFrame != nil else { return }
        lastDecision = .timeout
        discardFrame()
    }

    // MARK: - Assistant-turn-complete edge (D-15 byte release)

    /// The orchestrator calls this after the assistant's response has flushed
    /// (`LLMEvent.messageStop`). Releases the in-memory ImageBlock bytes.
    /// Idempotent — subsequent calls are no-ops.
    public func onAssistantTurnComplete() {
        discardFrame()
    }

    /// Release the pending frame when `confirmSend` returned a block but the
    /// orchestrator rejected the submit (no turn was allocated, so the
    /// broadcaster's `.turnEnd` watcher will never fire `onAssistantTurnComplete`).
    /// Without this hook the JPEG bytes would sit in actor memory until the
    /// next `requestAttach` overwrites the slot — a privacy regression on the
    /// D-15 byte-release window. Routes through the SOLE emission site
    /// (`discardFrame`) so the single-emission-site invariant is preserved.
    /// Idempotent — safe to call when no frame is pending.
    public func releaseAfterRejectedSubmit() {
        pendingTimeoutTask?.cancel()
        discardFrame()
    }

    // MARK: - SOLE EMISSION SITE — D-15

    /// D-15 single emission site. The ONLY place in this file where the
    /// pendingFrame slot is cleared. Cancel, timeout, and
    /// onAssistantTurnComplete all route through here. Enforced by
    /// `FrameAttachDiscardSiteGrepTests` grep gate.
    private func discardFrame() {
        pendingFrame = nil
    }
}
