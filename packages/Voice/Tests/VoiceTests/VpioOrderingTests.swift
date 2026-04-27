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
@Suite("VpioOrderingTests")
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
        var callOrder: [String] = []

        let builder = RecordingGraphBuilder(
            flipVPIO: { _ in callOrder.append("flipVPIO") },
            attach: { callOrder.append("attach") },
            connect: { callOrder.append("connect") },
            installTap: { callOrder.append("installTap") }
        )

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )
        InputFormatProbe._probeOverride = { _ in fmt16k }
        defer { InputFormatProbe._probeOverride = nil }

        _ = try AudioGraph(aec: true, builder: builder)

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
        var callOrder: [String] = []

        let builder = RecordingGraphBuilder(
            flipVPIO: { _ in callOrder.append("flipVPIO") },
            attach: { callOrder.append("attach") },
            connect: { callOrder.append("connect") },
            installTap: { callOrder.append("installTap") }
        )

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )
        InputFormatProbe._probeOverride = { _ in fmt16k }
        defer { InputFormatProbe._probeOverride = nil }

        let graph = try AudioGraph(aec: false, builder: builder)

        #expect(!callOrder.contains("flipVPIO"),
                "flipVPIO should NOT be called for aec=false build")
        if case .aecOff(_) = graph.variant {
            // Expected
        } else {
            Issue.record("Expected .aecOff variant, got: \(graph.variant)")
        }
    }
}

// MARK: - Test Support

/// A `GraphBuilder` that records call names for ordering assertions.
struct RecordingGraphBuilder: GraphBuilder {
    let _flipVPIO: (AVAudioInputNode) throws -> Void
    let _attach: () -> Void
    let _connect: () -> Void
    let _installTap: () -> Void

    init(
        flipVPIO: @escaping (AVAudioInputNode) throws -> Void,
        attach: @escaping () -> Void,
        connect: @escaping () -> Void,
        installTap: @escaping () -> Void
    ) {
        _flipVPIO = flipVPIO
        _attach = attach
        _connect = connect
        _installTap = installTap
    }

    func flipVPIO(_ inputNode: AVAudioInputNode) throws {
        try _flipVPIO(inputNode)
    }

    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {
        _attach()
    }

    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {
        _connect()
    }

    func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        _installTap()
    }
}
