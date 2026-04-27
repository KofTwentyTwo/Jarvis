import XCTest
@testable import Voice
import AVFoundation
import MLXAudioCore
import MLXAudioTTS

// MARK: - OrpheusTTFATests
//
// Scaffold-time perf probe for Orpheus TTFA (time-to-first-audio).
// Gated by JARVIS_REAL_MODELS=1 env var — skipped in CI.
//
// T1: Measure TTFA for "Hello, this is Jarvis." — log result; remediation note if > 250 ms.
// T2: TTSKit fallback functional smoke test.
//
// Per Plan 06-04 must_haves: "if measured TTFA > 250 ms, the test logs the
// value and emits a clear remediation note (flip to TTSKit fallback) — does
// NOT hard-fail." The probe is informational; Plan 06-05 reads the signal
// to choose the tier-2 default in features.tts.tier2.
//
// Run interactively on Apple Silicon:
//   JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests

final class OrpheusTTFATests: XCTestCase {

    func testT1_orpheusTTFAProbe() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1",
            "Set JARVIS_REAL_MODELS=1 to run TTFA probes (requires Orpheus weights on Apple Silicon)"
        )

        let model = try await LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")
        let start = ContinuousClock.now

        let stream = model.generateStream(
            text: "Hello, this is Jarvis.",
            voice: "tara",
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )

        var ttfa: Duration?
        for try await event in stream {
            if case .audio = event {
                ttfa = ContinuousClock.now - start
                break
            }
        }

        // Convert Duration to milliseconds
        let ttfaMs: Int64
        if let t = ttfa {
            // Duration.components: seconds + attoseconds (1e-18)
            let totalNs = Int64(t.components.seconds) * 1_000_000_000
                + t.components.attoseconds / 1_000_000_000
            ttfaMs = totalNs / 1_000_000
        } else {
            ttfaMs = -1
        }

        print("OrpheusTTFATests T1: TTFA = \(ttfaMs) ms (target: 150–250 ms)")

        if ttfaMs > 250 {
            print("""
            OrpheusTTFATests T1: REMEDIATION NOTE
            Measured TTFA \(ttfaMs) ms exceeds 250 ms target.
            Recommended action: set features.tts.tier2 = "ttskit" in Plan 06-05's
            feature-flag JSON to use TTSKit as tier-2 instead of Orpheus.
            """)
        }

        XCTAssertTrue(true, "TTFA probe completed (non-gating diagnostic)")
    }

    func testT2_ttskitFallbackFunctional() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1",
            "Set JARVIS_REAL_MODELS=1 to run TTSKit functional smoke test"
        )

        let fallback = try await TTSKitFallback(modelName: "ttskit-qwen3-tts-0.6b")
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Cannot create format")
            return
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()
        let sink = AudioSink(playerNode: playerNode, format: format)

        do {
            try await fallback.synthesize("Hello.", into: sink)
        } catch {
            XCTFail("TTSKit fallback synthesize failed: \(error)")
        }

        engine.stop()
        XCTAssertTrue(true, "TTSKit T2 functional smoke passed")
    }
}
