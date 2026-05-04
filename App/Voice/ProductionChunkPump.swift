import Foundation
import Voice

// MARK: - ProductionChunkPump
//
// Track B-5 + B-7 production chunk pump, extracted from `AppDelegate.installVoice`
// for testability (P1-2, audit 2026-05-04). The factory builds a
// `@Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void` that:
//
//   1. Resolves the current AudioGraphOwner via the supplied async accessor.
//   2. Subscribes through `AudioGraphOwner.subscribe()` so it has its own
//      per-subscriber RingBuffer (Track B-7 fan-out — never share the
//      legacy `ringBuffer` SPSC pointer with other consumers).
//   3. Drains the subscription's ring at 1024-frame windows (~64 ms @ 16 kHz),
//      yielding one `AudioChunk(pcm16k:)` per non-empty read into the
//      supplied STT continuation.
//   4. Sleeps 10 ms when the ring drains so it doesn't spin against a
//      starving producer.
//   5. Unsubscribes on exit (cancellation or stream finish), so a fresh
//      session gets a fresh subscription.
//
// The closure's lifetime is bound to a single STT session: VoiceController
// cancels its `chunkPumpTask` in `endSTTSession` and `shutdown`, which
// terminates the `while !Task.isCancelled` loop and runs the `defer`-style
// unsubscribe.

/// Build the production chunk pump used by `VoiceController.startSTTSession`.
///
/// - Parameter graphOwner: An async accessor returning the current
///   `AudioGraphOwner`. AppDelegate passes a `@MainActor`-bouncing closure
///   that reads `self.audioGraphOwner`. Tests inject a closure that
///   returns a test-built owner without crossing MainActor.
/// - Returns: A `@Sendable` closure consumed by `VoiceController.chunkPump`.
public func makeProductionChunkPump(
    graphOwner: @escaping @Sendable () async -> AudioGraphOwner?
) -> @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void {
    return { cont in
        // Resolve the owner and create a fresh subscription per pump
        // session. If the graph isn't open yet (e.g., installVoice
        // short-circuited), the pump finishes immediately so the STT
        // provider drains and finalize() returns "".
        guard let owner = await graphOwner(),
              let subscription = await owner.subscribe() else {
            cont.finish()
            return
        }
        defer { subscription.unsubscribe() }
        let ring = subscription.ring

        var scratch = [Float](repeating: 0, count: 1024)
        while !Task.isCancelled {
            let count = scratch.withUnsafeMutableBufferPointer { ptr in
                ring.readMono16k(into: ptr)
            }
            if count > 0 {
                let samples = count == scratch.count
                    ? scratch
                    : Array(scratch.prefix(count))
                cont.yield(AudioChunk(pcm16k: samples))
            } else {
                // Ring drained — yield 10 ms before retrying so we don't
                // spin against a starving producer.
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        cont.finish()
    }
}
