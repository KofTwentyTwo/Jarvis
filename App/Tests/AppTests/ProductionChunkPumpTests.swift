import XCTest
import AVFoundation
@testable import Jarvis
@testable import Voice

// MARK: - ProductionChunkPumpTests
//
// P1-2 (audit 2026-05-04): the production chunkPump closure that lives in
// `App/Voice/ProductionChunkPump.swift` and is wired by `AppDelegate
// .installVoice` was previously inline in AppDelegate and had zero coverage.
// Tests E1/E2/E3 exercised the chunkPump pipeline only with synthetic pumps,
// allowing BLOCKER-INT-1-style divergence between "tested" and "real."
//
// These integration tests:
//   - Build a real `AudioGraphOwner` with a tap-block-capturing
//     `GraphBuilder`. This bypasses live AVAudioEngine hardware while still
//     exercising the real `AudioGraphOwner.subscribe()` + `BufferBroadcaster`
//     fan-out path.
//   - Construct the production chunkPump factory under test.
//   - Run the pump in a Task, publish scripted PCM via the captured tap
//     block, and assert an `AsyncStream<AudioChunk>` consumer receives the
//     expected bytes.
//
// Anti-pattern guard the tests defend against: P1-1 / Track B-7 — if the
// pump ever regresses to reading from the legacy `ringBuffer` SPSC pointer
// it would steal samples. PCT3 publishes to the broadcaster, takes a second
// subscription, and asserts both subscriptions still see the bytes.

final class ProductionChunkPumpTests: XCTestCase {

    // MARK: - PCT1: pump finishes immediately when graphOwner is nil

    func testPCT1_pumpFinishesImmediatelyWhenOwnerNil() async {
        let pump = makeProductionChunkPump { nil }
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()

        let task = Task {
            await pump(cont)
        }

        // Drain the stream — should finish immediately without yielding.
        var chunks: [AudioChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }
        await task.value
        XCTAssertTrue(chunks.isEmpty, "Pump must finish without yielding when owner is nil")
    }

    // MARK: - PCT2: pump receives real buffers via broadcaster fan-out

    func testPCT2_pumpReceivesPublishedBuffersViaBroadcaster() async throws {
        // Build an AudioGraphOwner with a tap-capturing builder so we can
        // synthesize Core-Audio-tap-thread buffer publishes without running
        // the real AVAudioEngine.
        let recorder = TapBlockCapture()
        let builder = TapCapturingGraphBuilder(capture: recorder)

        let (degStream, degCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebStream, rebCont) = AsyncStream<RebuildEvent>.makeStream()
        // Drain the streams so continuations don't back-pressure.
        let drainDeg = Task { for await _ in degStream { } }
        let drainReb = Task { for await _ in rebStream { } }

        let owner = AudioGraphOwner(
            degradationContinuation: degCont,
            rebuildContinuation: rebCont,
            graphBuilder: builder
        )
        try await owner.open()

        // Get a stable reference to the owner to inject into the pump.
        let ownerRef: AudioGraphOwner = owner
        let pump = makeProductionChunkPump { ownerRef }

        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        let pumpTask = Task { await pump(cont) }

        // Wait for the subscription to be established. The pump does
        // `await owner.subscribe()` first, then enters its read loop. We
        // poll subscriberCount on the broadcaster captured by the tap.
        let block = try XCTUnwrap(recorder.capturedBlock, "Tap block must have been captured")

        // Synthesize a 1024-sample buffer of constant 0.5 amplitude at 16 kHz mono.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buf.frameLength = 1024
        let data = buf.floatChannelData![0]
        for i in 0..<1024 { data[i] = 0.5 }

        // Allow the pump to subscribe before we publish.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Publish via the captured tap block (simulates Core Audio thread).
        block(buf, AVAudioTime(sampleTime: 0, atRate: 16_000))

        // Drain at most a few chunks then cancel the pump.
        var receivedSamples: [Float] = []
        let drainTask = Task {
            for await chunk in stream {
                receivedSamples.append(contentsOf: chunk.pcm16k)
                if receivedSamples.count >= 1024 { break }
            }
        }

        // Wait up to 1 s for the pump to deliver the bytes.
        let deadline = Date().addingTimeInterval(1.0)
        while receivedSamples.count < 1024 && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        pumpTask.cancel()
        drainTask.cancel()
        await owner.shutdown()
        drainDeg.cancel()
        drainReb.cancel()

        XCTAssertGreaterThanOrEqual(receivedSamples.count, 1024,
            "Pump must yield at least one chunk worth of samples after publish")
        // All samples are 0.5 (within Float epsilon).
        let nonHalf = receivedSamples.prefix(1024).filter { abs($0 - 0.5) > 1e-6 }
        XCTAssertEqual(nonHalf.count, 0,
            "All received samples should equal the published 0.5 amplitude (P1-2 fidelity)")
    }

    // MARK: - PCT3: pump's broadcaster subscription does not steal from siblings

    /// Track B-7 + P1-1 invariant: each consumer gets a distinct ring.
    /// Confirms that running the production pump alongside another
    /// subscription leaves the sibling subscription's ring intact.
    func testPCT3_pumpDoesNotStealFromSiblingSubscription() async throws {
        let recorder = TapBlockCapture()
        let builder = TapCapturingGraphBuilder(capture: recorder)
        let (degStream, degCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebStream, rebCont) = AsyncStream<RebuildEvent>.makeStream()
        let drainDeg = Task { for await _ in degStream { } }
        let drainReb = Task { for await _ in rebStream { } }
        let owner = AudioGraphOwner(
            degradationContinuation: degCont,
            rebuildContinuation: rebCont,
            graphBuilder: builder
        )
        try await owner.open()

        // Sibling subscription — represents WakeWordDAG's perspective.
        let siblingSub = try XCTUnwrap(await owner.subscribe(), "Sibling subscribe must succeed")

        let ownerRef: AudioGraphOwner = owner
        let pump = makeProductionChunkPump { ownerRef }
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        let pumpTask = Task { await pump(cont) }

        let block = try XCTUnwrap(recorder.capturedBlock)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buf.frameLength = 1024
        let data = buf.floatChannelData![0]
        for i in 0..<1024 { data[i] = 0.25 }

        try await Task.sleep(nanoseconds: 50_000_000)
        block(buf, AVAudioTime(sampleTime: 0, atRate: 16_000))

        // Drain the pump's chunk briefly so it consumes its own ring.
        let drainTask = Task {
            for await _ in stream { /* drain */ }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Sibling subscription's ring should still hold the full 1024 frames
        // — the pump did NOT steal samples (P1-1 / Track B-7 invariant).
        var scratch = [Float](repeating: 0, count: 1024)
        let count = scratch.withUnsafeMutableBufferPointer { ptr in
            siblingSub.ring.readMono16k(into: ptr)
        }

        pumpTask.cancel()
        drainTask.cancel()
        siblingSub.unsubscribe()
        await owner.shutdown()
        drainDeg.cancel()
        drainReb.cancel()

        XCTAssertEqual(count, 1024,
            "Sibling subscription must still hold full buffer after pump runs (P1-1 / Track B-7 invariant)")
        XCTAssertEqual(scratch.first, 0.25,
            "Sibling samples must equal published amplitude (no corruption)")
    }
}

// MARK: - Test support

/// `@unchecked Sendable` reference cell that captures the tap block installed
/// by `AudioGraph.init`. Tests use the captured block to synthesize Core-Audio
/// thread publishes without running real `AVAudioEngine` hardware.
final class TapBlockCapture: @unchecked Sendable {
    var capturedBlock: AVAudioNodeTapBlock?
}

/// `GraphBuilder` that records the tap block so tests can invoke it directly.
/// All other operations are no-ops: tests don't need real engine wiring,
/// only the tap-block side of the pipeline (which feeds the broadcaster).
struct TapCapturingGraphBuilder: GraphBuilder {
    let capture: TapBlockCapture

    func flipVPIO(_ inputNode: AVAudioInputNode) throws {}
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {}

    func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        capture.capturedBlock = block
    }

    func startEngine(_ engine: AVAudioEngine) throws {
        // Skip: tests synthesize publishes via the captured tap block.
    }

    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 16_000,
                      channels: 1,
                      interleaved: false)!
    }
}
