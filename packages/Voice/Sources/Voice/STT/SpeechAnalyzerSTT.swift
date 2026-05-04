import AVFoundation
import Foundation
import Speech

// MARK: - SpeechAnalyzerBridge (test seam)

/// Protocol bridging the macOS 26 Tahoe `SpeechAnalyzer` + `SpeechTranscriber` APIs.
///
/// Production code creates a `LiveSpeechAnalyzerBridge` (guarded by
/// `@available(macOS 26, *)`); tests inject `MockSpeechAnalyzerBridge`.
public protocol SpeechAnalyzerBridge: Sendable {
    /// Prepare the analyzer (called once before feeding audio).
    func start() async throws
    /// Feed one audio chunk.
    func feed(_ chunk: AudioChunk) async throws
    /// Signal end of audio — triggers the final result.
    func finish() async throws
    /// Stream of partial transcript strings as speech is recognized.
    func partialResults() -> AsyncStream<String>
    /// Final concatenated transcript after `finish()`.
    func finalText() async throws -> String
}

// MARK: - SpeechAnalyzerSTT

/// Primary STT provider using macOS 26 Tahoe `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// Entitlement requirement (CLAUDE.md):
/// `com.apple.developer.speech-recognition-assets` + `NSSpeechRecognitionAssetsUsageDescription`
/// are required. Missing them causes `SFSpeechErrorCode.assetUnavailable` which this class
/// maps to `STTError.assetMissing` for the orchestrator to surface as a user-visible banner.
///
/// VAD-deadlock anti-pattern note (PLAN 06-03): the `.speechEnd` handler in
/// VoiceController must NOT synchronously block on `analyzer.finish()` —
/// VoiceController wraps that path in its own Task. Inside `feedTask` here
/// the synchronous form is correct, because the Task IS the serial owner of
/// feed→finish ordering. Earlier revisions wrapped `bridge.finish()` in a
/// nested fire-and-forget Task here as well — that was the wrong site for
/// the anti-pattern; per audit 2026-05-04 P2-5 we now `await` it directly so
/// finalize errors surface to `storeError` and `finalize()` can observe them.
public final class SpeechAnalyzerSTT: STTProvider {

    // MARK: - State

    private let bridge: any SpeechAnalyzerBridge
    // nonisolated(unsafe): accessed only from the sequential feed/finalize task chain.
    nonisolated(unsafe) private var storeError: (any Error)?

    // Internal continuation for the transcription stream
    nonisolated(unsafe) private var streamContinuation: AsyncStream<PartialTranscript>.Continuation?
    nonisolated(unsafe) private var feedTask: Task<Void, Never>?
    nonisolated(unsafe) private var drainTask: Task<Void, Never>?

    // MARK: - Init

    /// Public production init using the live SpeechAnalyzer bridge.
    ///
    /// The bridge is created eagerly; `SpeechAnalyzer` setup happens in `start()` when
    /// the first audio arrives via `transcribe(stream:)`.
    public init() {
        if #available(macOS 26.0, *) {
            self.bridge = LiveSpeechAnalyzerBridge()
        } else {
            self.bridge = UnavailableSpeechAnalyzerBridge()
        }
    }

    /// Test-seam init: inject a custom bridge.
    init(analyzerBridge: any SpeechAnalyzerBridge) {
        self.bridge = analyzerBridge
    }

    // MARK: - STTProvider

    public func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        let (asyncStream, continuation) = AsyncStream<PartialTranscript>.makeStream()
        self.streamContinuation = continuation

        // Task 1: feed audio chunks → bridge
        feedTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.start()
                for await chunk in stream {
                    do {
                        try await bridge.feed(chunk)
                    } catch {
                        self.storeError = self.mapError(error)
                        break
                    }
                }
                // P2-5 (audit 2026-05-04 concurrency HIGH-2): direct await
                // here. The VAD-deadlock anti-pattern protects the `.speechEnd`
                // VOICE handler, NOT this feedTask. feedTask IS the serial
                // owner of feed → finish ordering; awaiting bridge.finish()
                // directly lets finalize errors surface to storeError so
                // finalize() can throw them properly.
                do {
                    try await self.bridge.finish()
                } catch {
                    self.storeError = self.mapError(error)
                }
            } catch {
                self.storeError = self.mapError(error)
            }
        }

        // Task 2: drain partial results → stream
        drainTask = Task { [weak self] in
            guard let self else { return }
            for await text in bridge.partialResults() {
                continuation.yield(PartialTranscript(text: text, isFinal: false))
            }
            continuation.finish()
        }

        return asyncStream
    }

    public func finalize() async throws -> String {
        // Wait for feed + drain tasks to settle
        await feedTask?.value
        await drainTask?.value

        if let err = storeError {
            throw err
        }

        do {
            return try await bridge.finalText()
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Error mapping

    private func mapError(_ error: Error) -> any Error {
        let nsError = error as NSError
        // SFSpeechErrorDomain / code 1 = SFSpeechErrorCode.assetUnavailable
        // AUDIT-R2-S5: map to STTError.assetMissing so the orchestrator can surface a banner.
        if nsError.domain.contains("speech") || nsError.domain.contains("Speech"),
           nsError.code == 1 {
            return STTError.assetMissing
        }
        // Also catch the "assetUnavailable" description directly for robustness
        if nsError.localizedDescription.lowercased().contains("asset") {
            return STTError.assetMissing
        }
        return STTError.finalizationFailed(underlying: error)
    }
}

// MARK: - LiveSpeechAnalyzerBridge (macOS 26+)

/// Production bridge for the macOS 26 Tahoe `SpeechAnalyzer` + `SpeechTranscriber` APIs.
///
/// The `SpeechAnalyzer` / `SpeechTranscriber` APIs are new in macOS 26 Tahoe.
/// On earlier systems, `SpeechAnalyzerSTT` falls back to `UnavailableSpeechAnalyzerBridge`.
///
/// ## Track B-4 (2026-05-03 voice audit fix)
/// `feed()` was a `_ = chunk` no-op, leaving STT deaf in production. Real wiring
/// now lives here:
///
/// 1. `start()` builds the transcriber + analyzer, queries
///    `SpeechAnalyzer.bestAvailableAudioFormat`, opens the
///    `AsyncStream<AnalyzerInput>` input pipe, and spawns a background task
///    draining `transcriber.results` into the partials continuation.
/// 2. `feed()` packs `AudioChunk.pcm16k` into an `AVAudioPCMBuffer`
///    (`PCMBufferBuilder.makePCMBuffer`) and converts to the analyzer's
///    preferred format if needed, then yields an `AnalyzerInput(buffer:)`
///    on the input builder.
/// 3. `finish()` finishes the input stream, calls
///    `analyzer.finalizeAndFinishThroughEndOfInput()`, and awaits the result task.
/// 4. `partialResults()` returns the pre-built partial-text stream so
///    `SpeechAnalyzerSTT.transcribe` can subscribe before audio arrives.
/// 5. `finalText()` waits for the result drain to complete and returns the
///    concatenation of every `isFinal` segment.
///
/// `nonisolated(unsafe)` storage is deliberate: the surrounding
/// `SpeechAnalyzerSTT` serialises `start → feed* → finish → finalText` through
/// its single `feedTask` chain (see line 73), so cross-task races on these
/// fields cannot occur in production. Tests that exercise the bridge directly
/// must follow the same sequence.
@available(macOS 26.0, *)
private final class LiveSpeechAnalyzerBridge: SpeechAnalyzerBridge {

    // MARK: - Storage (single-writer-per-phase; SpeechAnalyzerSTT serialises)

    nonisolated(unsafe) private var transcriber: SpeechTranscriber?
    nonisolated(unsafe) private var analyzer: SpeechAnalyzer?
    nonisolated(unsafe) private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    nonisolated(unsafe) private var converter: AVAudioConverter?

    private let partialsStream: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    nonisolated(unsafe) private var resultsTask: Task<Void, Never>?
    nonisolated(unsafe) private var collectedText: String = ""
    nonisolated(unsafe) private var resultsError: (any Error)?
    nonisolated(unsafe) private var didFinish: Bool = false

    init() {
        let (stream, cont) = AsyncStream<String>.makeStream()
        self.partialsStream = stream
        self.partialsContinuation = cont
    }

    // MARK: - SpeechAnalyzerBridge

    func start() async throws {
        // Idempotent: if already started, do nothing. SpeechAnalyzerSTT calls
        // start exactly once per session, but the guard keeps us safe.
        guard analyzer == nil else { return }

        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // bestAvailableAudioFormat returns nil if no module has a format
        // preference (rare). Fall back to the AudioChunk format so we still
        // attempt feeding rather than dropping silently.
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) ?? PCMBufferBuilder.audioChunkFormat

        // Build the converter only when formats differ. AVAudioConverter
        // construction is cheap but has small per-frame overhead, so skip
        // when possible.
        let conv: AVAudioConverter?
        if !format.isEqual(PCMBufferBuilder.audioChunkFormat) {
            conv = AVAudioConverter(from: PCMBufferBuilder.audioChunkFormat, to: format)
        } else {
            conv = nil
        }

        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.converter = conv
        self.inputBuilder = builder

        // Spawn the result drain BEFORE start() so we don't miss early
        // partials. AttributedString is bridged via `result.text.characters`.
        let cont = self.partialsContinuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.collectedText.append(text)
                    }
                    cont.yield(text)
                }
            } catch {
                self?.resultsError = error
            }
            cont.finish()
        }

        try await analyzer.start(inputSequence: inputSequence)
    }

    func feed(_ chunk: AudioChunk) async throws {
        guard let inputBuilder, !chunk.pcm16k.isEmpty else { return }

        guard let raw = PCMBufferBuilder.makePCMBuffer(from: chunk.pcm16k) else {
            // Allocation failed — drop this chunk; SpeechAnalyzer can't recover from
            // missing samples but the next chunk may succeed.
            return
        }

        let toFeed: AVAudioPCMBuffer
        if let converter, let analyzerFormat {
            guard let converted = PCMBufferBuilder.convert(
                buffer: raw,
                using: converter,
                to: analyzerFormat
            ) else {
                return
            }
            toFeed = converted
        } else {
            toFeed = raw
        }

        inputBuilder.yield(AnalyzerInput(buffer: toFeed))
    }

    func finish() async throws {
        guard !didFinish else { return }
        didFinish = true

        inputBuilder?.finish()
        inputBuilder = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Wait for the results-drain Task to flush any remaining segments.
        await resultsTask?.value
        resultsTask = nil
    }

    func partialResults() -> AsyncStream<String> {
        partialsStream
    }

    func finalText() async throws -> String {
        await resultsTask?.value
        if let resultsError {
            throw resultsError
        }
        return collectedText
    }
}

// MARK: - UnavailableSpeechAnalyzerBridge

/// Fallback bridge for macOS versions before 26 Tahoe.
/// Immediately throws `STTError.backendUnavailable` when started.
private final class UnavailableSpeechAnalyzerBridge: SpeechAnalyzerBridge {
    func start() async throws {
        throw STTError.backendUnavailable(
            "SpeechAnalyzer requires macOS 26.0 or later (Tahoe). " +
            "Use WhisperKitSTT as fallback on earlier OS versions."
        )
    }
    func feed(_ chunk: AudioChunk) async throws { _ = chunk }
    func finish() async throws { }
    func partialResults() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func finalText() async throws -> String { "" }
}
