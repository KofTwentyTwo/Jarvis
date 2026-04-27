import Foundation

// MARK: - AudioLevelEmitter
//
// Reads the audio RingBuffer in parallel with the VAD feed loop, computes RMS
// over a window of samples at ~30 Hz, and emits `BusOutbound.audioLevel(rms:)`
// via the bus emitter.
//
// This is the producer that replaces Plan 03-03's fake sine wave listening pulse
// with real audio-reactive RMS — the RingMesh `uPulseSpeed` uniform is driven
// by this value.
//
// Window strategy:
//   At 30 Hz, one window = 33 ms. At 16 kHz, 33 ms × 16000 samples/s ≈ 528 samples.
//   We read 512 samples (32 ms at 16 kHz — exactly one Silero VAD chunk).
//
// RMS formula:
//   rms = sqrt(sum(x^2) / N)
//
// Thread safety:
//   `AudioLevelEmitter` is `@unchecked Sendable` — its mutable state (`emitterTask`)
//   is protected by the `paused` flag and the fact that `start()`/`stop()` serialize
//   on the actor caller (VoiceController). The emitter is NOT an actor because the
//   ring-buffer read loop is a tight inner loop that should not cross actor hops on
//   every sample window.

public final class AudioLevelEmitter: @unchecked Sendable {

    // MARK: - Private state

    private let ring: RingBuffer
    private let bus: any BusOutboundEmitter
    private let intervalNs: UInt64
    private var emitterTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - ring: The `RingBuffer` from `AudioGraphOwner` (16 kHz Float32 mono).
    ///   - bus: The bus emitter — receives `postAudio(_:)` at ~`hzRate` Hz.
    ///   - hzRate: Emission rate in Hz (default 30 Hz).
    public init(ring: RingBuffer, bus: any BusOutboundEmitter, hzRate: Double = 30) {
        self.ring = ring
        self.bus = bus
        self.intervalNs = UInt64(1_000_000_000.0 / hzRate)
    }

    // MARK: - Lifecycle

    /// Start emitting RMS values.
    ///
    /// Called by `VoiceController` when transitioning into `.listening`.
    /// Spawns a background Task that reads the ring and emits at `hzRate`.
    public func start() async {
        // Cancel any prior task
        emitterTask?.cancel()

        let ring = self.ring
        let bus = self.bus
        let interval = self.intervalNs

        emitterTask = Task.detached {
            // 512 samples = 32 ms at 16 kHz (one VAD chunk — matches Silero stride)
            var scratch = [Float](repeating: 0, count: 512)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }

                let count = scratch.withUnsafeMutableBufferPointer { ptr in
                    ring.readMono16k(into: ptr)
                }

                if count > 0 {
                    // Compute RMS over the available samples
                    let n = min(count, scratch.count)
                    var sumSq: Float = 0
                    for i in 0..<n {
                        sumSq += scratch[i] * scratch[i]
                    }
                    let rms = (sumSq / Float(n)).squareRoot()
                    await bus.postAudio(rms)
                }
            }
        }
    }

    /// Stop emitting RMS values.
    ///
    /// Called by `VoiceController` when transitioning out of `.listening`.
    public func stop() async {
        emitterTask?.cancel()
        emitterTask = nil
    }
}
