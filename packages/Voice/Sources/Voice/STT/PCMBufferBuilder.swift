import AVFoundation
import Foundation

// MARK: - PCMBufferBuilder

/// Pure-AVFoundation helpers used by `LiveSpeechAnalyzerBridge` to translate
/// `AudioChunk` (16 kHz mono Float32 `[Float]`) into `AVAudioPCMBuffer` and
/// optionally up/down-sample to the analyzer's preferred format.
///
/// Lives outside `LiveSpeechAnalyzerBridge` because that bridge is gated on
/// `@available(macOS 26.0, *)` (SpeechAnalyzer is Tahoe-only) but these
/// buffer helpers are pure AVFoundation and runnable on every supported OS.
/// Track B-4 (2026-05-03 voice audit fix) tests target this type directly.
public enum PCMBufferBuilder {

    /// Canonical input format for AudioChunks: 16 kHz mono Float32, non-interleaved.
    /// Anchored to `STTProvider`'s contract (`AudioChunk.pcm16k`).
    public static let audioChunkFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("PCMBufferBuilder.audioChunkFormat: 16k mono Float32 should always construct")
        }
        return fmt
    }()

    /// Wraps a `[Float]` of 16 kHz mono Float32 PCM into an `AVAudioPCMBuffer`
    /// with `frameLength = samples.count`.
    ///
    /// Returns `nil` if the buffer can't be allocated (out-of-memory; treated
    /// as transient — caller should drop the chunk and continue feeding).
    public static func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = audioChunkFormat
        let capacity = AVAudioFrameCount(max(samples.count, 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard samples.isEmpty == false, let channel = buffer.floatChannelData?[0] else {
            return buffer
        }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Converts `src` (in `audioChunkFormat`) into a buffer in `dst` format,
    /// using a pre-built `AVAudioConverter`. Returns `nil` on conversion error.
    ///
    /// The output buffer's capacity is sized by the sample-rate ratio + a small
    /// safety margin. Empty inputs return an empty output buffer (no conversion).
    public static func convert(
        buffer src: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to dst: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if src.frameLength == 0 {
            return AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 1)
        }
        let ratio = dst.sampleRate / src.format.sampleRate
        let outCapacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCapacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return src
        }
        if status == .error {
            return nil
        }
        return out
    }
}
