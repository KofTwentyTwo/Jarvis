import AVFoundation
import XCTest
@testable import Voice

// MARK: - PCMBufferBuilderTests
//
// Track B-4 (2026-05-03 voice audit fix): unit-level tests for the
// AudioChunk → AVAudioPCMBuffer translator that LiveSpeechAnalyzerBridge
// relies on. These run on every macOS version since AVFoundation is
// not gated on Tahoe.

final class PCMBufferBuilderTests: XCTestCase {

    // MARK: - audioChunkFormat invariants

    func test_audioChunkFormat_is_16kMonoFloat32() {
        let fmt = PCMBufferBuilder.audioChunkFormat
        XCTAssertEqual(fmt.sampleRate, 16_000, "Track B-4 contract: 16 kHz")
        XCTAssertEqual(fmt.channelCount, 1, "Track B-4 contract: mono")
        XCTAssertEqual(fmt.commonFormat, .pcmFormatFloat32, "Track B-4 contract: Float32")
    }

    // MARK: - makePCMBuffer: frame count

    func test_makePCMBuffer_assignsFrameLengthFromSampleCount() throws {
        let samples: [Float] = Array(repeating: 0.1, count: 256)
        let buffer = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: samples))
        XCTAssertEqual(Int(buffer.frameLength), 256)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
    }

    // MARK: - makePCMBuffer: payload fidelity

    func test_makePCMBuffer_copiesSamplesIntoChannelData() throws {
        let samples: [Float] = (0..<128).map { Float($0) * 0.001 }
        let buffer = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: samples))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<samples.count {
            XCTAssertEqual(channel[i], samples[i], accuracy: 1e-7,
                "Sample \(i) round-trip failure")
        }
    }

    // MARK: - makePCMBuffer: empty input

    func test_makePCMBuffer_emptyInput_returnsZeroFrameBuffer() throws {
        let buffer = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: []))
        XCTAssertEqual(buffer.frameLength, 0,
            "Empty AudioChunk must produce an empty buffer (caller drops, never crashes)")
    }

    // MARK: - convert: same-format passthrough produces identical samples

    func test_convert_sameFormat_preservesSamples() throws {
        let samples: [Float] = (0..<256).map { Float(sin(Double($0) * 0.05)) }
        let src = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: samples))
        let dstFormat = PCMBufferBuilder.audioChunkFormat
        let converter = try XCTUnwrap(AVAudioConverter(from: src.format, to: dstFormat))
        let out = try XCTUnwrap(PCMBufferBuilder.convert(buffer: src, using: converter, to: dstFormat))
        XCTAssertEqual(out.frameLength, src.frameLength,
            "Same-format conversion must preserve frame count")
        let outChannel = try XCTUnwrap(out.floatChannelData?[0])
        for i in 0..<Int(out.frameLength) {
            XCTAssertEqual(outChannel[i], samples[i], accuracy: 1e-6,
                "Same-format passthrough should not modify sample \(i)")
        }
    }

    // MARK: - convert: 16k → 24k upsamples to ~1.5x frame count

    func test_convert_16kTo24k_producesUpsampledFrameCount() throws {
        let samples: [Float] = Array(repeating: 0.0, count: 1600)  // 100 ms @ 16k
        let src = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: samples))
        let dstFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: src.format, to: dstFormat))
        let out = try XCTUnwrap(PCMBufferBuilder.convert(buffer: src, using: converter, to: dstFormat))
        let expected = AVAudioFrameCount(Double(src.frameLength) * 1.5)
        // AVAudioConverter may produce ±1 frame at boundaries; accept ±5 frames slack.
        XCTAssertGreaterThan(out.frameLength, expected - 5,
            "Upsample should produce ~1.5x frames (got \(out.frameLength), expected ~\(expected))")
        XCTAssertLessThan(out.frameLength, expected + 5,
            "Upsample should produce ~1.5x frames (got \(out.frameLength), expected ~\(expected))")
    }

    // MARK: - convert: empty input returns empty output

    func test_convert_emptyInput_returnsZeroFrameBuffer() throws {
        let src = try XCTUnwrap(PCMBufferBuilder.makePCMBuffer(from: []))
        let dstFormat = PCMBufferBuilder.audioChunkFormat
        let converter = try XCTUnwrap(AVAudioConverter(from: src.format, to: dstFormat))
        let out = try XCTUnwrap(PCMBufferBuilder.convert(buffer: src, using: converter, to: dstFormat))
        XCTAssertEqual(out.frameLength, 0,
            "Empty input must not produce phantom output frames")
    }
}
