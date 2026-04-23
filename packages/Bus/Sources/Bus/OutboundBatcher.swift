import Foundation

/// Coalesces high-frequency outbound bus events at ~30 Hz (33 ms window).
///
/// Coalescing strategy per event type:
/// - `postAudio`: **latest value wins** — volume is scalar, stale values are
///   irrelevant; the HUD only cares about what the mic is doing right now.
/// - `postToken`: **concatenated** — preserves every character while
///   minimizing the call count across the main-actor JS-call boundary.
/// - `flushAndSend`: **cancel + drain + send** — for state-transition events
///   (`hudState`, `toolCallStart`/`End`, `turnStarted`/`Ended`, etc.). Drains
///   the pending audio/token buffers first so the caller's message never
///   overtakes earlier-posted data in the chronological stream.
///
/// Why `actor` rather than `@MainActor`: the per-event buffer bookkeeping does
/// not need main-thread isolation. The final JS call hops back to `@MainActor`
/// via `Sink.sendRaw(_:)`. Keeping the batcher off the main actor means audio
/// posts from a high-frequency CoreAudio callback don't contend with UI work
/// on every single chunk.
public actor OutboundBatcher {
    /// Protocol seam for testability — `WebviewBridge` conforms; tests use a
    /// recording fake. Declared `Sendable` so we can hold a weak reference
    /// across the actor boundary.
    public protocol Sink: AnyObject, Sendable {
        @MainActor func sendRaw(_ msg: BusOutbound) async throws
    }

    private weak var sink: Sink?
    private var latestAudio: Float?
    private var pendingTokens: [String] = []
    private var scheduled: Task<Void, Never>?
    private let windowMillis: UInt64

    public init(sink: Sink, windowMillis: UInt64 = 33) {
        self.sink = sink
        self.windowMillis = windowMillis
    }

    public func postAudio(_ rms: Float) {
        latestAudio = rms
        scheduleDrainIfNeeded()
    }

    public func postToken(_ chunk: String) {
        pendingTokens.append(chunk)
        scheduleDrainIfNeeded()
    }

    /// Drains the pending batch (if any) in order, then sends the caller's
    /// message. Cancels any scheduled drain task so a stale window doesn't
    /// fabricate a duplicate send after `flushAndSend` returned.
    public func flushAndSend(_ msg: BusOutbound) async throws {
        scheduled?.cancel()
        scheduled = nil
        try await drainBuffers()
        try await sink?.sendRaw(msg)
    }

    // MARK: - Private

    private func scheduleDrainIfNeeded() {
        guard scheduled == nil else { return }
        let millis = windowMillis
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(millis))
            guard !Task.isCancelled else { return }
            await self?.scheduledDrainFired()
        }
    }

    private func scheduledDrainFired() async {
        scheduled = nil
        try? await drainBuffers()
    }

    /// Drain order: audio first (latest-wins), then tokens (concat). Both are
    /// cleared before the `sendRaw` hop so a reentrant `postAudio`/`postToken`
    /// from the same task cannot double-send the same payload.
    private func drainBuffers() async throws {
        if let audio = latestAudio {
            latestAudio = nil
            try await sink?.sendRaw(.audioLevel(rms: audio))
        }
        if !pendingTokens.isEmpty {
            let joined = pendingTokens.joined()
            pendingTokens.removeAll()
            try await sink?.sendRaw(.tokenDelta(text: joined))
        }
    }
}
