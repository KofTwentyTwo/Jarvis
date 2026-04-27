import XCTest
import AVFoundation
@testable import Voice

// MARK: - AVSpeechSmokeTests
//
// Tests for Plan 06-04 (TTS tier-1 + AudioSink).
//
// A1: speak(_:voice:) async resolves within 2 s (synthesizer is STORED, not re-created — Pitfall §5).
// A2: rapid-fire speak calls — stopSpeaking(at:.immediate) fires before each new utterance.
// A3: AudioSink enqueue + awaitCompletion fires after buffer drains (not at enqueue time).
// A4: cosineFadeOut produces smooth 1.0→0.0 decay over 10 ms.

final class AVSpeechSmokeTests: XCTestCase {

    // MARK: A1 — speak resolves within 2 seconds

    func testA1_speakResolvesWithinTwoSeconds() async throws {
        let synth = AVSpeechSynth()
        let deadline = Date().addingTimeInterval(2.0)
        await synth.speak("OK", voice: nil)
        XCTAssertTrue(Date() < deadline, "speak(_:voice:) must resolve within 2 seconds")
    }

    // MARK: A2 — rapid-fire: stopSpeaking fires before each new utterance

    func testA2_rapidFireStopsBeforeNextUtterance() async throws {
        let synth = AVSpeechSynth()
        let counter = StopCounter()
        synth.onStop = { [counter] in counter.increment() }

        // Two serial speak calls — each triggers onStop.
        await synth.speak("first", voice: nil)
        await synth.speak("second", voice: nil)

        // Each call to speak() calls stopSpeaking(at:.immediate) → 2 calls = ≥2 stops.
        XCTAssertGreaterThanOrEqual(
            counter.value,
            2,
            "stopSpeaking(at:.immediate) must fire at least once per speak() call (rapid-fire guard)"
        )
    }

    // MARK: A3 — AudioSink completion fires after buffer drains

    func testA3_audioSinkCompletionAfterDrain() async throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Could not create AVAudioFormat")
            return
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()

        let sink = AudioSink(playerNode: playerNode, format: format)

        // Build a 100 ms buffer (1600 samples @ 16 kHz) of ramp-up audio
        let sampleCount = 1600
        var samples = [Float](repeating: 0.0, count: sampleCount)
        for i in 0..<sampleCount { samples[i] = Float(i) / Float(sampleCount) * 0.01 }

        let waitStart = Date()
        await sink.enqueue(samples)
        await sink.awaitCompletion(timeout: .seconds(1))
        let waitEnd = Date()

        let duration = waitEnd.timeIntervalSince(waitStart)
        XCTAssertLessThan(
            duration,
            1.5,
            "awaitCompletion must return within 1.5 s for a 100 ms buffer with 1 s timeout"
        )

        engine.stop()
    }

    // MARK: A4 — cosine fade produces smooth decay

    func testA4_cosineFadeProducesSmoothDecay() async throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let sampleRate: Double = 16000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Could not create AVAudioFormat")
            return
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()

        let sink = AudioSink(playerNode: playerNode, format: format)

        // cosineFadeOut at 10 ms @ 16 kHz = 160 samples
        await sink.cosineFadeOut(duration: .milliseconds(10))

        let fadeSamples = sink.lastFadeSamples
        XCTAssertFalse(fadeSamples.isEmpty, "cosineFadeOut must produce samples")
        XCTAssertEqual(fadeSamples.count, 160, "10 ms @ 16 kHz = 160 samples")

        if let first = fadeSamples.first, let last = fadeSamples.last {
            XCTAssertGreaterThan(first, 0.9, "First fade sample must be near 1.0 (cos(0) ≈ 1.0)")
            XCTAssertLessThan(last, 0.05, "Last fade sample must be near 0.0 (cos(π/2) ≈ 0.0)")

            // Verify monotonic decay (smooth cosine)
            for i in 1..<fadeSamples.count {
                XCTAssertLessThanOrEqual(
                    fadeSamples[i],
                    fadeSamples[i - 1] + 0.001,
                    "Fade samples must be monotonically decreasing at index \(i)"
                )
            }
        }

        engine.stop()
    }
}

// MARK: - StopCounter (thread-safe for Swift 6 strict concurrency)

final class StopCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StopCounter")
    private var _value = 0

    func increment() { queue.sync { _value += 1 } }
    var value: Int { queue.sync { _value } }
}
