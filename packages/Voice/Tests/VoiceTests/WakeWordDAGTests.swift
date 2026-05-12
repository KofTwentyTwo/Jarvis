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

    /// WD-3 (Issue #28): the DAG survives an audio-graph rebuild —
    /// `stopFeed()` keeps the public stream alive, and `start(ring:)`
    /// against a new ring resumes inference into the same stream. This
    /// is the canonical "rebuild boundary" sequence AppDelegate now
    /// wires (cancelInFlight → stopFeed; rebuildStream consumer →
    /// start(ring: newRing)).
    ///
    /// Regression: prior to the fix, `cancelInFlight` called `cancel()`
    /// which finished the stream — wake-word died on first
    /// device-change / mic-regrant / ring-overflow event.
    func test_DAG_survivesRebuild_streamStaysLive_newRingDrives() async throws {
        let recorder = InputRecorder()

        let session = OpenWakeWordSession(scriptedClassifier: { input in
            Task { await recorder.record(input) }
            return 0.0
        })

        // Initial ring + DAG arming.
        let ring1 = RingBuffer(capacityFrames: 16000)
        let markerA: [Float] = Array(repeating: 0.11, count: 1280)
        writeSamples(markerA, into: ring1)

        let dag = WakeWordDAG(session: session)
        await dag.start(ring: ring1)

        // Wait for at least one record from ring1.
        let deadline1 = Date().addingTimeInterval(1.0)
        while Date() < deadline1 {
            if await recorder.count > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let preRebuildCount = await recorder.count
        XCTAssertGreaterThan(
            preRebuildCount, 0,
            "Pre-rebuild: DAG must drive the session from ring1"
        )

        // Spawn a consumer that exits only when the stream is finished —
        // mirrors the production `VoiceController.spawnWakeWordConsumer`.
        // We assert it stays running across the rebuild boundary.
        actor ConsumerFlag { var exited = false; func set() { exited = true } }
        let flag = ConsumerFlag()
        let consumerTask = Task {
            for await _ in dag.wakeWordStream { /* ignore events */ }
            await flag.set()
        }

        // Simulate AudioGraphOwner.teardown → cancelInFlight.
        // The bug fix: stopFeed() (NOT cancel()) so the public stream
        // survives. The consumer Task must NOT exit.
        await dag.stopFeed()
        try? await Task.sleep(for: .milliseconds(100))
        let exitedAfterStopFeed = await flag.exited
        XCTAssertFalse(
            exitedAfterStopFeed,
            "stopFeed() must NOT finish the wake-word stream — the bug was cancel() finishing it"
        )

        // Re-arm against a NEW ring (simulating the new ring buffer from
        // AudioGraphOwner's post-rebuild graph).
        let priorCount = await recorder.count
        let ring2 = RingBuffer(capacityFrames: 16000)
        let markerB: [Float] = Array(repeating: 0.99, count: 1280)
        writeSamples(markerB, into: ring2)
        await dag.start(ring: ring2)

        // Wait for new ring's marker to drive the session.
        let deadline2 = Date().addingTimeInterval(1.0)
        var sawNewMarker = false
        while Date() < deadline2 {
            let snap = await recorder.snapshot
            if snap.suffix(snap.count - priorCount).contains(where: { buf in
                abs((buf.first ?? .nan) - 0.99) < 1e-5
            }) {
                sawNewMarker = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await dag.cancel()
        consumerTask.cancel()

        XCTAssertTrue(
            sawNewMarker,
            "After stopFeed() + start(ring: newRing), the DAG must drive the session from the new ring (rebuild boundary contract)"
        )
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
