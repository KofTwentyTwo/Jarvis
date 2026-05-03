import XCTest
import AVFAudio
@testable import Voice

/// Coverage for the production wiring of `WakeWordDAG.start(ring:)` →
/// `OpenWakeWordSession.feed(samples:)`. Closes the bug class from the
/// 2026-05-03 voice audit:
///
///   `WakeWordDAG.swift:93` calls the test seam `session.feedTest()`,
///   which always feeds an EMPTY `[Float]` to the hysteresis. In a
///   production build with real ORT models, the wake word never fires
///   because the hysteresis never sees the actual mic samples — every
///   frame is empty. No prior test caught it because every existing
///   `WakeWordHysteresisTests` case calls `feedTest()` directly,
///   bypassing the DAG's wiring entirely.
///
/// These tests construct a scripted `OpenWakeWordSession` whose
/// classifier records the buffer it receives. The DAG drives a
/// pre-loaded `RingBuffer` and we assert that:
///
/// 1. The DAG passes a NON-EMPTY buffer to the session (proves the
///    production path uses `feed(samples:)` not `feedTest()`).
/// 2. The buffer contains the literal samples we wrote into the ring.
@MainActor
final class WakeWordDAGTests: XCTestCase {

    /// Ring fill helper — writes `samples` (Float32 mono 16 kHz) into
    /// the ring via an AVAudioPCMBuffer in the same format the
    /// production audio tap uses.
    private func writeSamples(_ samples: [Float], into ring: RingBuffer) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCapacity = AVAudioFrameCount(samples.count)
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            XCTFail("AVAudioPCMBuffer allocation failed")
            return
        }
        buf.frameLength = frameCapacity
        // Channel 0 is the only one (mono); copy the samples in.
        let channel = buf.floatChannelData![0]
        for (i, s) in samples.enumerated() {
            channel[i] = s
        }
        ring.write(buf)
    }

    /// Actor-isolated recorder for classifier inputs — async-safe (NSLock
    /// is unavailable from `async` contexts under Swift 6 strict
    /// concurrency).
    private actor InputRecorder {
        private(set) var buffers: [[Float]] = []
        func record(_ input: [Float]) { buffers.append(input) }
        var count: Int { buffers.count }
        var snapshot: [[Float]] { buffers }
    }

    /// WD-1: the DAG forwards the actual ring contents to the session.
    /// The scripted classifier records the most recent buffer; we
    /// assert it received 1280 samples (one mel frame) with a
    /// recognizable signature value.
    func test_DAG_forwardsRingSamplesToSession_notEmpty() async throws {
        let recorder = InputRecorder()

        let session = OpenWakeWordSession(scriptedClassifier: { input in
            // Sync hop into the actor — `Task.detached` because the closure
            // is sync. Test waits for the recording to land via polling.
            Task { await recorder.record(input) }
            return 0.0  // never trigger; we only care about the call shape
        })

        let ring = RingBuffer(capacityFrames: 16000) // 1s buffer
        // Marker pattern: 1280 samples, all 0.42. Distinguishable from
        // an empty buffer (the bug) and from any random mic data.
        let marker: [Float] = Array(repeating: 0.42, count: 1280)
        writeSamples(marker, into: ring)

        let dag = WakeWordDAG(session: session)
        await dag.start(ring: ring)

        // Wait up to 1s for the DAG's detached task + the recorder Task
        // hop to land at least one buffer.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if await recorder.count > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await dag.cancel()

        let recorded = await recorder.snapshot
        XCTAssertGreaterThan(
            recorded.count, 0,
            "DAG must invoke session classifier at least once when ring has data"
        )
        let firstNonEmpty = recorded.first(where: { !$0.isEmpty })
        XCTAssertNotNil(
            firstNonEmpty,
            "DAG must pass non-empty samples to session — only-empty arrays indicates the feedTest bug"
        )
        if let buf = firstNonEmpty {
            XCTAssertEqual(
                buf.count, 1280,
                "DAG must pass a full mel frame (1280 samples) per call"
            )
            // Marker check: rules out empty / accidentally-zeroed buffers.
            XCTAssertEqual(
                Double(buf.first ?? .nan), 0.42, accuracy: 1e-5,
                "DAG must pass the actual ring samples (not zeros, not the test seam's empty arg)"
            )
        }
    }

    /// WD-2: when the ring is empty, the DAG should NOT call the
    /// classifier (current loop sleeps and retries when framesRead == 0).
    /// Locks in the contract that we don't burn CPU calling the
    /// classifier on empty input.
    func test_DAG_skipsClassifierWhenRingEmpty() async throws {
        let recorder = InputRecorder()

        let session = OpenWakeWordSession(scriptedClassifier: { _ in
            Task { await recorder.record([0.0]) }
            return 0.0
        })

        let ring = RingBuffer(capacityFrames: 16000)
        // Intentionally don't write anything.

        let dag = WakeWordDAG(session: session)
        await dag.start(ring: ring)

        // Run for ~200ms — plenty of time to spin many empty reads.
        try? await Task.sleep(for: .milliseconds(200))
        await dag.cancel()

        let count = await recorder.count
        XCTAssertEqual(
            count, 0,
            "DAG must not call classifier with empty data; got \(count) calls"
        )
    }
}
