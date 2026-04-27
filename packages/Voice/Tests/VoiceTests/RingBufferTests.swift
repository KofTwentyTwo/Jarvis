import Testing
import AVFoundation
@testable import Voice

/// Tests for the SPSC RingBuffer — overflow detection, lag tracking,
/// round-trip fidelity, and concurrent producer/consumer safety (VOICE-10).
///
/// The ring is the hand-off point between the Core Audio tap thread (producer)
/// and the wake-word / VAD consumer. These tests prove the contract:
/// - 16 kHz Float32 mono frames round-trip bit-for-bit.
/// - `overflowDetected` fires after 500 ms sustained consumer lag.
/// - `consumerLagMs` resets to zero when the consumer catches up.
/// - No data races under concurrent load.
@Suite("RingBufferTests")
struct RingBufferTests {

    // MARK: R1 — round-trip fidelity

    @Test("R1: 480 frames write then read returns identical samples")
    func roundTrip480Frames() throws {
        let capacity = 16_000  // 1 second at 16 kHz
        let ring = RingBuffer(capacityFrames: capacity)

        let frameCount = 480
        let buf = try makePCMBuffer(frameCount: frameCount, sampleRate: 16_000, channels: 1)

        // Fill with a recognizable ramp
        let channel = buf.floatChannelData![0]
        for i in 0..<frameCount {
            channel[i] = Float(i) / Float(frameCount)
        }
        buf.frameLength = AVAudioFrameCount(frameCount)

        ring.write(buf)

        var out = [Float](repeating: 0, count: frameCount)
        let read = out.withUnsafeMutableBufferPointer { ring.readMono16k(into: $0) }
        #expect(read == frameCount)
        for i in 0..<frameCount {
            #expect(abs(out[i] - channel[i]) < 1e-6, "Sample \(i) mismatch: wrote \(channel[i]) read \(out[i])")
        }
    }

    // MARK: R2 — overflow detection

    @Test("R2: overflowDetected is true after 600 ms lag, false at 400 ms")
    func overflowDetection() throws {
        // Use a tiny capacity and fast timestamp injection so we can
        // simulate lag without sleeping in the test.
        let capacity = 16_000  // 1 s
        let threshold = 500.0  // ms

        let ring = RingBuffer(capacityFrames: capacity, sustainedOverflowMs: threshold)

        // Fill the ring completely (no consumer)
        let chunk = try makePCMBuffer(frameCount: 512, sampleRate: 16_000, channels: 1)
        chunk.frameLength = 512
        for _ in 0..<(capacity / 512) {
            ring.write(chunk)
        }

        // At this point lag is capacity frames = 1000 ms.
        // Simulate "first observed lag" 600 ms ago by injecting a timestamp.
        ring._overflowFirstObservedAt = ContinuousClock.now - .milliseconds(600)

        #expect(ring.overflowDetected == true)

        // Now simulate "first observed lag" only 400 ms ago.
        ring._overflowFirstObservedAt = ContinuousClock.now - .milliseconds(400)
        #expect(ring.overflowDetected == false)
    }

    // MARK: R3 — lag monotonicity and reset

    @Test("R3: consumerLagMs monotonic under write-only; resets to 0 when consumer catches up")
    func lagMonotonicAndReset() throws {
        let ring = RingBuffer(capacityFrames: 16_000)
        let chunk = try makePCMBuffer(frameCount: 160, sampleRate: 16_000, channels: 1)
        chunk.frameLength = 160

        var prevLag = 0.0
        for _ in 0..<10 {
            ring.write(chunk)
            let lag = ring.consumerLagMs
            #expect(lag >= prevLag, "Lag should be non-decreasing under write-only load")
            prevLag = lag
        }

        // Drain all frames
        let totalFrames = 160 * 10
        var out = [Float](repeating: 0, count: totalFrames)
        let read = out.withUnsafeMutableBufferPointer { ring.readMono16k(into: $0) }
        #expect(read == totalFrames)
        #expect(ring.consumerLagMs == 0.0)
    }

    // MARK: R4 — concurrent producer/consumer

    @Test("R4: concurrent producer and consumer run 1 s with no data race")
    func concurrentProducerConsumer() async throws {
        let ring = RingBuffer(capacityFrames: 16_000 * 2)  // 2 s buffer
        let chunk = try makePCMBuffer(frameCount: 512, sampleRate: 16_000, channels: 1)
        chunk.frameLength = 512
        let channel = chunk.floatChannelData![0]
        for i in 0..<512 { channel[i] = Float(i) * 0.001 }

        // Producer: write 100 chunks
        let producer = Task.detached {
            for _ in 0..<100 {
                ring.write(chunk)
                // Tiny yield so both tasks interleave
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        // Consumer: read chunks as they arrive
        let consumer = Task.detached {
            var totalRead = 0
            for _ in 0..<50 {
                var out = [Float](repeating: 0, count: 512)
                let n = out.withUnsafeMutableBufferPointer { ring.readMono16k(into: $0) }
                totalRead += n
                try? await Task.sleep(for: .milliseconds(10))
            }
            return totalRead
        }

        await producer.value
        let _ = await consumer.value
        // Test passes if no data race was detected by TSan and no crash occurred.
    }

    // MARK: - Helpers

    private func makePCMBuffer(
        frameCount: Int,
        sampleRate: Double,
        channels: UInt32
    ) throws -> AVAudioPCMBuffer {
        let fmt = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: sampleRate,
                          channels: channels,
                          interleaved: false)
        )
        return try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)))
    }
}
