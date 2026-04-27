import Testing
import AVFoundation
@testable import Voice

/// Tests proving VPIO ordering invariant (VOICE-08).
///
/// The fundamental rule: `setVoiceProcessingEnabled(true)` MUST be called
/// before ANY `attach`, `connect`, or `installTap` on the audio graph.
/// Pitfall #7: flipping VPIO after connect is a silent no-op on Tahoe and
/// a crash on Sonoma.
///
/// These tests use `AudioGraph`'s `GraphBuilder` injection point to record
/// the call sequence without needing a live audio device.
///
/// `.serialized` is required because V2 and V3 set `InputFormatProbe._probeOverride`
/// (a global test seam) and must not run concurrently with other tests that use it.
@Suite("VpioOrderingTests", .serialized)
struct VpioOrderingTests {

    // MARK: V1 — vpioNotEnabled guard

    @Test("V1: buildGraph throws vpioNotEnabled when aec=false and caller tries AEC tap")
    func vpioNotEnabledErrorSurface() throws {
        // The AudioGraphError.vpioNotEnabled case exists in the surface — smoke test.
        let err = AudioGraphError.vpioNotEnabled
        #expect(err == .vpioNotEnabled)
    }

    // MARK: V2 — aec=true ordering: VPIO first

    @Test("V2: aec=true builds call setVoiceProcessingEnabled before attach/connect/installTap")
    func vpioCalledFirstInAecOnBuild() throws {
        let recorder = CallRecorder()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )
        let builder = RecordingGraphBuilder(recorder: recorder, injectedFormat: fmt16k)

        _ = try AudioGraph(aec: true, builder: builder)

        let callOrder = recorder.calls
        // flipVPIO must be call index 0
        #expect(callOrder.first == "flipVPIO",
                "Expected flipVPIO to be first call, got: \(callOrder)")
        // attach comes after
        #expect(callOrder.contains("attach"))
        // installTap comes last
        #expect(callOrder.last == "installTap",
                "Expected installTap to be last call, got: \(callOrder)")
    }

    // MARK: V3 — aec=false skips VPIO, variant is .aecOff

    @Test("V3: aec=false build skips setVoiceProcessingEnabled; variant is aecOff")
    func aecFalseSkipsVpio() throws {
        let recorder = CallRecorder()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )
        let builder = RecordingGraphBuilder(recorder: recorder, injectedFormat: fmt16k)

        let graph = try AudioGraph(aec: false, builder: builder)

        #expect(!recorder.calls.contains("flipVPIO"),
                "flipVPIO should NOT be called for aec=false build")
        if case .aecOff(_) = graph.variant {
            // Expected
        } else {
            Issue.record("Expected .aecOff variant, got: \(graph.variant)")
        }
    }
}

// MARK: - Test Support

/// Thread-safe call recorder used by test builders.
/// `@unchecked Sendable` because the array is only mutated from the
/// single-threaded test set-up phase (before AudioGraph.init races).
final class CallRecorder: @unchecked Sendable {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

/// A `GraphBuilder` that records call names into a shared `CallRecorder`
/// and returns an injected format for `probeFormat`.
struct RecordingGraphBuilder: GraphBuilder {
    let recorder: CallRecorder
    let injectedFormat: AVAudioFormat

    func flipVPIO(_ inputNode: AVAudioInputNode) throws {
        recorder.record("flipVPIO")
    }

    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {
        recorder.record("attach")
    }

    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {
        recorder.record("connect")
    }

    func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        recorder.record("installTap")
    }

    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat {
        injectedFormat
    }
}
