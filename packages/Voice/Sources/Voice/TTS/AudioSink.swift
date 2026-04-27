import AVFoundation
import Foundation

// MARK: - AudioSink
//
// Wraps an `AVAudioPlayerNode` to provide:
//   - `enqueue(_:)` — schedule PCM Float32 buffers
//   - `cosineFadeOut(duration:)` — enqueue a cosine-shaped fade buffer (VOICE-11)
//   - `stop()` — synchronous playerNode.stop()
//   - `awaitCompletion(timeout:)` — wait until node is silent or timeout fires
//
// VOICE-11 constraint: The 10 ms cosine fade enqueued by `InterruptSequence`
// must use real audio samples (not a `volume` ramp on the node) so the fade
// is the last scheduled buffer. `playerNode.stop()` then halts precisely at
// the end of the fade.
//
// Pitfall #6 guard: `.ttsStopped` is emitted by `InterruptSequence.run` at
// step 5 (after `awaitCompletion`), not here — this class does not emit events.
//
// Thread-safety: AudioSink is @unchecked Sendable. Internal state is protected
// by a DispatchQueue (not NSLock) because NSLock is unavailable from async
// Swift 6 contexts while still needing to be called from AVAudioPlayerNode
// completion handlers (which run on arbitrary Core Audio threads).

public final class AudioSink: @unchecked Sendable {

    // MARK: - Public API

    /// The player node owned externally (caller attaches to engine).
    public let playerNode: AVAudioPlayerNode

    /// Format used for PCM buffers (e.g. 24 kHz mono Float32 for Orpheus).
    public let format: AVAudioFormat

    /// Test seam: last set of samples passed to `cosineFadeOut(duration:)`.
    /// Populated only from tests; production code ignores this.
    public nonisolated(unsafe) var lastFadeSamples: [Float] = []

    // MARK: - Private state

    // Serial queue guards all mutable state. Used from both Core Audio callbacks
    // (sync) and Swift async tasks (via sync { } blocks on the queue).
    private let queue = DispatchQueue(label: "com.jarvis.AudioSink", attributes: [])
    private var pendingBuffers: Int = 0
    private var completionBoxes: [ContinuationBox] = []
    private var _isStopped: Bool = false

    // MARK: - Init

    /// Creates a sink bound to `playerNode` and `format`.
    ///
    /// The caller is responsible for attaching `playerNode` to an `AVAudioEngine`
    /// and calling `playerNode.play()` before the first `enqueue`.
    public init(playerNode: AVAudioPlayerNode, format: AVAudioFormat) {
        self.playerNode = playerNode
        self.format = format
    }

    // MARK: - Enqueue

    /// Schedule a Float32 PCM buffer on the player node.
    ///
    /// The completion handler fires when the buffer has finished rendering
    /// (i.e. the samples have left the speaker). This is the correct signal
    /// for drain detection — not the time of scheduling.
    public func enqueue(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }

        guard let buffer = makePCMBuffer(samples: samples, format: format) else {
            return
        }

        queue.sync { self.pendingBuffers += 1 }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            var boxesToResume: [ContinuationBox] = []
            self.queue.sync {
                self.pendingBuffers -= 1
                if self.pendingBuffers == 0 {
                    boxesToResume = self.completionBoxes
                    self.completionBoxes = []
                }
            }
            for box in boxesToResume {
                box.tryResume()
            }
        }
    }

    // MARK: - Cosine Fade

    /// Enqueue a cosine-shaped fade buffer of `duration` that decays from
    /// amplitude 1.0 to 0.0 (VOICE-11: prevents click/pop on interrupt).
    ///
    /// The fade is a real PCM buffer — NOT a `volume` property ramp — so it
    /// integrates correctly with the scheduler's FIFO ordering. Once this
    /// buffer is enqueued, `playerNode.stop()` halts at the end of the fade.
    ///
    /// Sample formula: `amplitude[i] = cos(π * i / (2 * n))` where n = frameCount.
    /// - cos(0) = 1.0 (full amplitude at start)
    /// - cos(π/2) = 0.0 (silence at end)
    public func cosineFadeOut(duration: Duration) async {
        guard !queue.sync(execute: { self._isStopped }) else { return }

        let sampleRate = format.sampleRate
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        let frameCount = max(1, Int(sampleRate * seconds))

        var samples = [Float](repeating: 0.0, count: frameCount)
        let n = Float(frameCount)
        for i in 0..<frameCount {
            // cosine taper from 1.0 → 0.0 over frameCount samples
            samples[i] = cos(Float.pi * Float(i) / (2.0 * n))
        }

        // Expose for test inspection (A4)
        lastFadeSamples = samples

        await enqueue(samples)
    }

    // MARK: - Stop

    /// Synchronously stops the player node (halts scheduling).
    public func stop() {
        var boxesToResume: [ContinuationBox] = []
        queue.sync {
            self._isStopped = true
            boxesToResume = self.completionBoxes
            self.completionBoxes = []
        }
        playerNode.stop()
        for box in boxesToResume {
            box.tryResume()
        }
    }

    // MARK: - Await Completion

    /// Wait until all enqueued buffers have drained OR `timeout` expires.
    ///
    /// VOICE-11 spec: bounded at ≤ 20 ms in `InterruptSequence.run`.
    public func awaitCompletion(timeout: Duration) async {
        // Fast path: already drained or stopped
        let alreadyDone = queue.sync { pendingBuffers == 0 || _isStopped }
        if alreadyDone { return }

        let timeoutSeconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) * 1e-18

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The box owns the continuation. Both the drain path (enqueue's
            // completion handler / stop()) and the timeout path call
            // `box.tryResume()`; whichever wins first resumes, the loser is a
            // no-op. This is the load-bearing guarantee against
            // SWIFT TASK CONTINUATION MISUSE on overlapping drain + timeout.
            let box = ContinuationBox(continuation)

            var shouldArmTimeout = true
            queue.sync {
                // Re-check under lock — drain may have completed between the
                // fast-path check above and acquiring the queue.
                if self.pendingBuffers == 0 || self._isStopped {
                    shouldArmTimeout = false
                } else {
                    self.completionBoxes.append(box)
                }
            }

            if !shouldArmTimeout {
                box.tryResume()
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                // Remove our box from the pending list (by identity) before
                // resuming, so the drain path doesn't race against this resume.
                self?.queue.sync {
                    self?.completionBoxes.removeAll { $0 === box }
                }
                box.tryResume()
            }
        }
    }

    // MARK: - Helpers

    private func makePCMBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        for i in 0..<samples.count {
            channel[i] = samples[i]
        }
        return buffer
    }
}

// MARK: - ContinuationBox

/// One-shot owner of a `CheckedContinuation<Void, Never>` whose `tryResume()`
/// is idempotent. The drain path and the timeout path both race to resume the
/// same waiter; whichever calls `tryResume()` first wins, the other becomes a
/// no-op. Without this, both paths would call `cont.resume()` directly and
/// `CheckedContinuation` would trap with SWIFT TASK CONTINUATION MISUSE.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// Resume the held continuation iff this is the first call. Returns true
    /// if the resume actually happened.
    @discardableResult
    func tryResume() -> Bool {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return false
        }
        continuation = nil
        lock.unlock()
        cont.resume()
        return true
    }
}
