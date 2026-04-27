import Testing
import AVFoundation
@testable import Voice

/// Tests for InputFormatProbe — the post-VPIO format probe contract (VOICE-08).
///
/// The probe is a pure pass-through: it calls `inputNode.outputFormat(forBus: 0)`
/// (or the `_probeOverride` test seam) and returns the result. This test verifies
/// that the probe correctly handles both 24 kHz Tahoe and 16 kHz Sonoma payloads
/// without mutation or hardcoding.
///
/// The `.serialized` trait is required because the tests share the
/// `InputFormatProbe._probeOverride` global mutable test seam.  Without
/// serialization, parallel test execution causes a race where one test's
/// defer-nil clears the seam while the other test is mid-use.
@Suite("InputFormatProbeTests", .serialized)
struct InputFormatProbeTests {

    @Test("Probe returns 24 kHz stereo format unchanged (Tahoe)")
    func probe24kHzStereo() throws {
        let fmt24k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 24_000,
                          channels: 2,
                          interleaved: false)
        )
        // Inject the test seam so we don't need a live AVAudioEngine
        InputFormatProbe._probeOverride = { _ in fmt24k }
        defer { InputFormatProbe._probeOverride = nil }

        let result = InputFormatProbe.probe(inputNode: dummyInputNode())
        #expect(result.sampleRate == 24_000)
        #expect(result.channelCount == 2)
    }

    @Test("Probe returns 16 kHz mono format unchanged (Sonoma)")
    func probe16kHzMono() throws {
        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )
        InputFormatProbe._probeOverride = { _ in fmt16k }
        defer { InputFormatProbe._probeOverride = nil }

        let result = InputFormatProbe.probe(inputNode: dummyInputNode())
        #expect(result.sampleRate == 16_000)
        #expect(result.channelCount == 1)
    }

    // MARK: - Helpers

    /// Returns a dummy node reference; only used as the parameter to the
    /// override closure (which ignores its argument in tests).
    private func dummyInputNode() -> AVAudioInputNode {
        // We never actually call methods on this node in tests because
        // _probeOverride intercepts the call.
        AVAudioEngine().inputNode
    }
}
