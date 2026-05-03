import Foundation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "WakeWordDAG")

/// Actor that owns the wake-word detection pipeline and exposes an async stream
/// of `WakeWordEvent` for downstream consumers (Plan 06-05 VoiceController).
///
/// ## Threading discipline (RESEARCH §1 / T-06-02-03)
/// The read-feed Task is `Task.detached` (NOT actor-isolated) so inference does not
/// block actor responsiveness to `pause()`/`resume()`. Paused state is checked
/// before each call to `session.feedTest()` (or `session.feed()`).
///
/// ## 1280-sample scratch buffer
/// Corresponds to 80 ms of audio at 16 kHz (1280 / 16000 = 0.08 s) — one mel
/// frame per the openWakeWord pipeline. Post-VPIO, Plan 06-01's graph taps at
/// the probed sample rate and resamples to 16 kHz before writing to the ring.
///
/// ## Plan 06-01 integration
/// `cancel()` has the signature `@Sendable () async -> Void` matching the
/// `AudioGraphOwner.cancelInFlight` slot. Plan 06-05 wires it:
/// ```swift
/// await audioGraphOwner.cancelInFlight = { [dag] in await dag.cancel() }
/// ```
///
/// ## Pause/resume preserve-counter decision
/// The `consecutive` counter is owned by `OpenWakeWordSession`, NOT by the DAG.
/// When paused, the feed loop reads frames from the ring but does NOT call
/// `session.feedTest()`. The session's consecutive count is therefore preserved
/// across pause/resume: a wake-word fragment started before pause can complete
/// after resume (e.g., the user says "Hey" → pause → "Jarvis" → resume → fires).
/// Reversal cost: change the `if paused { continue }` to
/// `if paused { _ = session.resetConsecutive(); continue }` (one line).
///
/// ## cancelInFlight wiring
/// `cancel()` → `feedTask?.cancel()` → the Task loop exits on `Task.isCancelled`.
/// The stream continuation is finished immediately in `cancel()` so consumers see
/// the stream end without waiting for the Task to drain.
public actor WakeWordDAG {

    // MARK: - Public surface

    /// Stream of wake-word detection events.
    ///
    /// Plan 06-05's `VoiceController` consumes this stream as the trigger for
    /// the `.idle → .listening` HUD state transition.
    public nonisolated let wakeWordStream: AsyncStream<WakeWordEvent>

    // MARK: - Init

    public init(session: OpenWakeWordSession) {
        self.session = session
        let (stream, cont) = AsyncStream<WakeWordEvent>.makeStream()
        self.wakeWordStream = stream
        self.streamCont = cont
    }

    // MARK: - Lifecycle

    /// Starts the ring-buffer read / session feed loop on a detached Task.
    ///
    /// The scratch buffer is 1280 Float32 samples (80 ms / 16 kHz / one mel frame).
    /// If no frames are available from the ring, the loop sleeps 10 ms before retrying.
    ///
    /// - Parameter ring: The `RingBuffer` from Plan 06-01's `AudioGraphOwner`.
    public func start(ring: RingBuffer) async {
        // Cancel any previous feed task
        feedTask?.cancel()

        feedTask = Task.detached { [weak self, ring] in
            // 1280 samples = 80 ms at 16 kHz — one mel frame (RESEARCH §1)
            var scratch = [Float](repeating: 0, count: 1280)

            while !Task.isCancelled {
                // Read one frame from the ring (lock-free SPSC)
                let framesRead = scratch.withUnsafeMutableBufferPointer { ptr in
                    ring.readMono16k(into: ptr)
                }

                if framesRead == 0 {
                    // Ring is empty — sleep 10 ms to avoid busy-waiting
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                guard let self else { return }

                // Check pause state — if paused, skip inference (preserve counter)
                if await self.paused { continue }

                // Slice the scratch buffer to the actual frames read.
                // Track B-2 (2026-05-03 voice audit fix): was
                // `session.feedTest()` which always passed an EMPTY
                // `[Float]` to `runHysteresis` — production never saw
                // mic samples, wake word never fired. `feedTest()` is
                // the test seam (internal scope) for hysteresis tests
                // that bypass the buffer. Production path uses
                // `feed(samples:)` with actual PCM. Coverage:
                // WakeWordDAGTests.WD-1.
                let samples = framesRead == scratch.count
                    ? scratch
                    : Array(scratch.prefix(framesRead))
                if let decision = try? await self.session.feed(samples: samples) {
                    if case .fired = decision {
                        logger.info("WakeWordDAG: wake-word fired at \(Date())")
                        await self.streamCont.yield(.fired(at: Date()))
                    }
                }
            }
            logger.debug("WakeWordDAG: feed task exited (cancelled=\(Task.isCancelled))")
        }

        logger.info("WakeWordDAG: started ring-feed loop")
    }

    /// Pauses the pipeline. The feed loop continues reading the ring but skips
    /// inference, preserving the `consecutive` counter in `OpenWakeWordSession`.
    public func pause() async {
        paused = true
        logger.debug("WakeWordDAG: paused (consecutive counter preserved)")
    }

    /// Resumes the pipeline after `pause()`. Inference picks up from where the
    /// `consecutive` counter left off.
    public func resume() async {
        paused = false
        logger.debug("WakeWordDAG: resumed")
    }

    /// Cancels the feed Task and finishes the wake-word stream.
    ///
    /// Called by `AudioGraphOwner.cancelInFlight` during the six-step teardown
    /// (Plan 06-01, step 1). The Task cancels within 50 ms (one sleep cycle +
    /// cooperative cancellation on `Task.isCancelled` check).
    ///
    /// After `cancel()`, the `wakeWordStream` is finished — no further events will
    /// be emitted. Callers that iterate `wakeWordStream` will see the async for-loop
    /// exit naturally.
    public func cancel() async {
        feedTask?.cancel()
        feedTask = nil
        streamCont.finish()
        logger.info("WakeWordDAG: cancelled — stream finished")
    }

    // MARK: - Private state

    private let session: OpenWakeWordSession
    private let streamCont: AsyncStream<WakeWordEvent>.Continuation
    private var feedTask: Task<Void, Never>?
    private var paused: Bool = false
}
