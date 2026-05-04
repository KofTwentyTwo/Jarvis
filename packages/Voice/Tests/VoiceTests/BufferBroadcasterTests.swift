import Testing
import AVFoundation
@testable import Voice

/// Tests for `BufferBroadcaster` — the multi-consumer fan-out hub at the
/// AudioGraph tap (Track B-7, 2026-05-03 voice audit fix).
///
/// `RingBuffer` is documented SPSC; in production three consumers
/// (WakeWordDAG, AudioLevelEmitter, the Track B-5 chunk pump) all drained the
/// same ring concurrently and stole samples from each other. The broadcaster
/// gives each subscriber its own per-subscriber RingBuffer so every consumer
/// sees every sample.
@Suite("BufferBroadcasterTests")
struct BufferBroadcasterTests {

    // MARK: BB-1 — single subscriber receives every published buffer

    @Test("BB-1: single subscriber receives every published buffer")
    func singleSubscriberReceivesEverything() throws {
        let bc = BufferBroadcaster()
        let sub = bc.subscribe()

        // Publish 10 distinct buffers; tag samples with a known ramp so we
        // can verify both count and identity.
        let frameCount = 256
        var expected: [Float] = []
        for i in 0..<10 {
            let buf = try makeBuffer(frameCount: frameCount, baseValue: Float(i) * 0.1)
            bc.publish(buf)
            for _ in 0..<frameCount { expected.append(Float(i) * 0.1) }
        }

        var out = [Float](repeating: 0, count: frameCount * 10)
        let read = out.withUnsafeMutableBufferPointer { sub.ring.readMono16k(into: $0) }
        #expect(read == frameCount * 10)
        for i in 0..<read {
            #expect(abs(out[i] - expected[i]) < 1e-6, "sample \(i) mismatch")
        }
    }

    // MARK: BB-2 — multiple subscribers each receive their own copy

    @Test("BB-2: multiple subscribers each receive their own copy of every buffer")
    func multipleSubscribersGetOwnCopies() throws {
        let bc = BufferBroadcaster()
        let subA = bc.subscribe()
        let subB = bc.subscribe()

        // Single buffer; all samples = 0.42
        let frameCount = 512
        let buf = try makeBuffer(frameCount: frameCount, baseValue: 0.42)
        bc.publish(buf)

        // Both subscribers must see ALL frameCount samples — neither steals
        // from the other.
        var outA = [Float](repeating: 0, count: frameCount)
        let readA = outA.withUnsafeMutableBufferPointer { subA.ring.readMono16k(into: $0) }
        var outB = [Float](repeating: 0, count: frameCount)
        let readB = outB.withUnsafeMutableBufferPointer { subB.ring.readMono16k(into: $0) }

        #expect(readA == frameCount)
        #expect(readB == frameCount)
        for i in 0..<frameCount {
            #expect(abs(outA[i] - 0.42) < 1e-6)
            #expect(abs(outB[i] - 0.42) < 1e-6)
        }
    }

    // MARK: BB-3 — unsubscribe stops delivery

    @Test("BB-3: unsubscribe stops delivery of subsequent publishes")
    func unsubscribeStopsDelivery() throws {
        let bc = BufferBroadcaster()
        let sub = bc.subscribe()

        // Drain pre-existing samples (sub starts empty so this is a no-op).
        let frameCount = 256
        let buf = try makeBuffer(frameCount: frameCount, baseValue: 0.1)
        bc.publish(buf)

        // Drain everything received so far so the post-unsubscribe read has
        // a clean baseline.
        var drain = [Float](repeating: 0, count: frameCount * 4)
        _ = drain.withUnsafeMutableBufferPointer { sub.ring.readMono16k(into: $0) }

        // Unsubscribe, then publish more.
        sub.unsubscribe()
        bc.publish(buf)
        bc.publish(buf)

        // Subscriber's ring must show zero new frames after unsubscribe.
        let read = drain.withUnsafeMutableBufferPointer { sub.ring.readMono16k(into: $0) }
        #expect(read == 0)
    }

    // MARK: BB-4 — late-joining subscriber sees only post-subscribe buffers

    @Test("BB-4: late-joining subscriber sees only buffers published after subscribe")
    func lateJoinerSkipsPriorBuffers() throws {
        let bc = BufferBroadcaster()

        let frameCount = 256
        // Publish 5 BEFORE any subscriber exists.
        let pre = try makeBuffer(frameCount: frameCount, baseValue: 0.9)
        for _ in 0..<5 { bc.publish(pre) }

        // Subscribe.
        let sub = bc.subscribe()

        // Publish 5 AFTER subscribe with a different value.
        let post = try makeBuffer(frameCount: frameCount, baseValue: 0.1)
        for _ in 0..<5 { bc.publish(post) }

        var out = [Float](repeating: 0, count: frameCount * 10)
        let read = out.withUnsafeMutableBufferPointer { sub.ring.readMono16k(into: $0) }
        #expect(read == frameCount * 5)
        for i in 0..<read {
            #expect(abs(out[i] - 0.1) < 1e-6, "late joiner saw a pre-subscribe sample at \(i)")
        }
    }

    // MARK: BB-5 — high-frequency publish + concurrent subscribe doesn't deadlock or crash

    @Test("BB-5: concurrent publishers + subscribers run without crash or deadlock")
    func concurrentStress() async throws {
        let bc = BufferBroadcaster()

        // Pre-subscribe one consumer to guarantee at least one delivery target.
        let primary = bc.subscribe()

        // Hold buffers in a Sendable wrapper so the detached publisher
        // tasks can safely reference them. AVAudioPCMBuffer itself is not
        // Sendable, so we wrap it.
        let frameCount = 128
        let buf = try makeBuffer(frameCount: frameCount, baseValue: 0.5)
        let bufBox = UncheckedBox(buf)

        // Two publishers
        let pub1 = Task.detached {
            for _ in 0..<500 {
                bc.publish(bufBox.value)
            }
        }
        let pub2 = Task.detached {
            for _ in 0..<500 {
                bc.publish(bufBox.value)
            }
        }

        // Two subscriber-churners
        let churn1 = Task.detached {
            for _ in 0..<200 {
                let s = bc.subscribe()
                s.unsubscribe()
            }
        }
        let churn2 = Task.detached {
            for _ in 0..<200 {
                let s = bc.subscribe()
                s.unsubscribe()
            }
        }

        await pub1.value
        await pub2.value
        await churn1.value
        await churn2.value

        // Primary must have received at least *some* samples without crash.
        var out = [Float](repeating: 0, count: 4096)
        let read = out.withUnsafeMutableBufferPointer { primary.ring.readMono16k(into: $0) }
        #expect(read > 0, "primary subscriber received zero samples under concurrent load")
    }

    // MARK: - Helpers

    /// `@unchecked Sendable` wrapper so detached test tasks can pass an
    /// `AVAudioPCMBuffer` (which is itself not Sendable) into closures
    /// without tripping the strict-concurrency diagnostic. Safe here
    /// because the buffer is filled once and only read concurrently
    /// thereafter — `BufferBroadcaster.publish` only reads from it.
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private func makeBuffer(frameCount: Int, baseValue: Float) throws -> AVAudioPCMBuffer {
        let fmt = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)))
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ch = buf.floatChannelData![0]
        for i in 0..<frameCount { ch[i] = baseValue }
        return buf
    }
}
