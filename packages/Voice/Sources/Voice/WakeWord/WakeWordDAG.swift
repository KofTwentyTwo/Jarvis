import Foundation
import OSLog

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "WakeWordDAG")

/// STUB — RED phase. Tests reference this type.
/// Full implementation follows in the GREEN commit.
///
/// Actor that owns the wake-word detection pipeline and exposes a stream of
/// `WakeWordEvent` for Plan 06-05's `VoiceController` to consume.
///
/// Threading discipline (RESEARCH §1 / T-06-02-03):
/// - DO NOT block the AVAudioEngine tap thread on ORT inference.
/// - The read-feed Task reads from `RingBuffer.readMono16k` on a dedicated
///   `Task.detached` that is NOT actor-isolated (so the actor remains responsive
///   to `pause`/`resume` requests during inference).
/// - DO NOT share ORTSession instances across stages — owned by OpenWakeWordSession.
///
/// Plan 06-01 integration:
/// - `cancel()` has the shape `@Sendable () async -> Void` matching the
///   `AudioGraphOwner.cancelInFlight` slot. Plan 06-05's VoiceController wires it:
///   `await audioGraphOwner.setCancelInFlight { await wakeWordDAG.cancel() }`
public actor WakeWordDAG {

    // MARK: - Public surface

    /// Stream of wake-word detection events. Plan 06-05's VoiceController consumes this.
    public nonisolated let wakeWordStream: AsyncStream<WakeWordEvent>

    // MARK: - Init

    public init(session: OpenWakeWordSession) {
        self.session = session
        let (stream, cont) = AsyncStream<WakeWordEvent>.makeStream()
        self.wakeWordStream = stream
        self.streamCont = cont
    }

    // MARK: - Lifecycle

    /// STUB: no-op in RED phase.
    public func start(ring: RingBuffer) async {
        // Not implemented
    }

    /// STUB: no-op in RED phase.
    public func pause() async {
        self.paused = true
    }

    /// STUB: no-op in RED phase.
    public func resume() async {
        self.paused = false
    }

    /// STUB: no-op in RED phase.
    public func cancel() async {
        feedTask?.cancel()
        feedTask = nil
        streamCont.finish()
    }

    // MARK: - Private state

    private let session: OpenWakeWordSession
    private let streamCont: AsyncStream<WakeWordEvent>.Continuation
    private var feedTask: Task<Void, Never>?
    private var paused: Bool = false
}
