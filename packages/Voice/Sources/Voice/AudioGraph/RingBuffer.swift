import AVFoundation
import OSLog

/// Lock-free single-producer / single-consumer ring buffer for 16 kHz
/// Float32 mono audio frames.
///
/// The tap callback (Core Audio thread) is the producer; the wake-word /
/// VAD pipeline is the consumer.  SPSC semantics mean only one actor may
/// call `write` and only one actor may call `readMono16k` — mixing callers
/// would require external synchronisation.
///
/// Overflow strategy: when `overflowDetected` returns `true`, the
/// `AudioGraphOwner` runs the canonical six-step teardown + rebuild rather
/// than silently dropping samples.  Pitfall #4: silent drop is explicitly
/// rejected here.  The producer-side `write` path still overwrites old
/// frames when the ring is full (oldest frame replaced by newest), so the
/// consumer receives the most recent audio at the cost of a gap.
///
/// Lag tracking: `consumerLagMs` is computed from `(writeIdx - readIdx) /
/// sampleRate * 1000`.  Frames are always stored at the ring's fixed
/// `sampleRate` (16 000 Hz) — this anchor is locked by the VOICE-01/02
/// downstream contracts.
///
/// Thread safety: `writeIdx` and `readIdx` are stored as `UInt64` with
/// atomic load/store via `nonisolated(unsafe)` + explicit memory-ordering
/// conventions.  The ring is declared `@unchecked Sendable` because the
/// producer and consumer access disjoint storage regions (SPSC guarantee).
public final class RingBuffer: @unchecked Sendable {

    // MARK: - Public API

    /// Creates a ring with the given capacity and overflow threshold.
    ///
    /// - Parameters:
    ///   - capacityFrames: Power-of-two capacity in 16 kHz mono frames.
    ///     Non-power-of-two values are rounded up to the next power of two
    ///     so that wrapping is a simple bitmask operation.
    ///   - sustainedOverflowMs: Duration of sustained consumer lag (in ms)
    ///     that triggers `overflowDetected == true`.  Default 500 ms per
    ///     Pitfall #4.
    public init(capacityFrames: Int, sustainedOverflowMs: Double = 500) {
        // Round up to next power of two
        var cap = capacityFrames
        if cap <= 0 { cap = 1 }
        if !cap.isPowerOfTwo {
            var p = 1
            while p < cap { p <<= 1 }
            cap = p
        }
        self.capacity = cap
        self.mask = cap &- 1
        self.storage = .init(repeating: 0, count: cap)
        self.sustainedOverflowMs = sustainedOverflowMs
    }

    /// Writes the frames from `buffer` into the ring.
    ///
    /// The buffer is expected to be Float32 mono at 16 kHz (after
    /// `AudioGraph`'s channel-coerce + rate-convert tap pipeline).
    /// If the buffer has more than one channel the channels are averaged
    /// to produce a mono mix before writing.
    ///
    /// If the ring is full, the oldest frames are overwritten (newest
    /// survives).  Overflow is detected by `overflowDetected`.
    ///
    /// Called on the Core Audio tap thread — MUST be lock-free.
    public func write(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        for i in 0..<frameCount {
            var sample: Float = 0
            for ch in 0..<channelCount {
                sample += data[ch][i]
            }
            sample /= Float(channelCount)

            let slot = Int(writeIdx) & mask
            storage[slot] = sample
            writeIdx &+= 1
        }

        // Update lag tracking for overflow detection
        let lagMs = computeLagMs()
        if lagMs > sustainedOverflowMs {
            if _overflowFirstObservedAt == nil {
                _overflowFirstObservedAt = .now
            }
        } else {
            _overflowFirstObservedAt = nil
        }
    }

    /// Copies up to `into.count` frames from the ring into the caller's
    /// buffer.  Returns the actual number of frames copied (may be less
    /// than `into.count` if the ring has fewer frames available).
    ///
    /// Called on the consumer thread — MUST be lock-free.
    public func readMono16k(into: UnsafeMutableBufferPointer<Float>) -> Int {
        let available = Int(writeIdx &- readIdx)
        let count = min(into.count, available)
        guard count > 0 else { return 0 }

        for i in 0..<count {
            let slot = Int(readIdx) & mask
            into[i] = storage[slot]
            readIdx &+= 1
        }
        return count
    }

    /// Consumer lag in milliseconds.
    ///
    /// Computed as `(writeIdx - readIdx) / 16_000 * 1_000` — frames are
    /// always at 16 kHz mono (locked by VOICE-01/02 contracts).
    ///
    /// Resets to `0.0` when the consumer has consumed all written frames.
    public var consumerLagMs: Double {
        computeLagMs()
    }

    /// Returns `true` when the consumer has been lagging by more than
    /// `sustainedOverflowMs` for at least `sustainedOverflowMs` ms
    /// continuously.
    ///
    /// Pitfall #4: callers MUST NOT silently ignore this — fire
    /// `RebuildTrigger.ringOverflow` instead.
    public var overflowDetected: Bool {
        guard let first = _overflowFirstObservedAt else { return false }
        let elapsed = ContinuousClock.now - first
        let elapsedMs = Double(elapsed.components.seconds) * 1_000
                      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return elapsedMs >= sustainedOverflowMs
    }

    // MARK: - Internal test seams

    /// Injected by unit tests to simulate "lag first observed at" without
    /// sleeping.  The name `_overflowFirstObservedAt` signals test-only use.
    internal var _overflowFirstObservedAt: ContinuousClock.Instant?

    // MARK: - Private storage

    private let capacity: Int
    private let mask: Int
    private nonisolated(unsafe) var storage: [Float]
    private nonisolated(unsafe) var writeIdx: UInt64 = 0
    private nonisolated(unsafe) var readIdx: UInt64 = 0
    private let sustainedOverflowMs: Double

    private static let sampleRate: Double = 16_000

    private func computeLagMs() -> Double {
        let lagFrames = writeIdx &- readIdx
        guard lagFrames > 0 else { return 0.0 }
        return Double(lagFrames) / Self.sampleRate * 1_000
    }
}

// MARK: - Int helpers

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
