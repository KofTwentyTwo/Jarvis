/// A chunk of raw audio for STT input.
public struct AudioChunk: Sendable {
    /// 16 kHz mono Float32 PCM samples.
    public let pcm16k: [Float]
    public init(pcm16k: [Float]) { self.pcm16k = pcm16k }
}

/// A partial (or final) transcript event from an STT provider.
public struct PartialTranscript: Sendable, Equatable {
    public let text: String
    /// `true` when this is the finalized result (no further updates expected).
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// STT backend protocol.
///
/// Both `SpeechAnalyzerSTT` (primary, Tahoe) and `WhisperKitSTT` (fallback,
/// argmax-oss-swift v0.18.0) implement this interface.
///
/// Lifecycle:
/// 1. Call `transcribe(stream:)` to start feeding audio; consume the returned stream.
/// 2. After all audio has been fed (stream ends), call `finalize()` to get the
///    final transcript string.
///
/// SEC-05: the backend is pinned at `submit()` time via `PerTurnSnapshot.stt.backend`.
/// Mid-session backend swaps are NOT supported.
public protocol STTProvider: AnyObject, Sendable {
    /// Begin streaming transcription of audio chunks.
    ///
    /// The returned `AsyncStream` emits `PartialTranscript` events as the provider
    /// processes audio. The stream ends when the audio stream is exhausted.
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript>

    /// Return the final consolidated transcript after the audio stream ends.
    ///
    /// Must be called after the stream returned by `transcribe(stream:)` has finished.
    func finalize() async throws -> String
}
