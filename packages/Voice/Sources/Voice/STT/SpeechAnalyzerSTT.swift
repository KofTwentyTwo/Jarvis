import Foundation

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
/// DO NOT block on `await finish()` synchronously from the VAD `.speechEnd` handler —
/// wrap in a Task so VAD events don't deadlock on the analyzer completion path (PLAN 06-03
/// anti-pattern callout).
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
                // DO NOT block here — wrap finish in a non-blocking Task
                // (PLAN 06-03 anti-pattern: DO NOT block on await analyzer.finish() synchronously)
                Task {
                    do { try await self.bridge.finish() }
                    catch { self.storeError = self.mapError(error) }
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
@available(macOS 26.0, *)
private final class LiveSpeechAnalyzerBridge: SpeechAnalyzerBridge {

    // NOTE: The `Speech` framework `SpeechAnalyzer` + `SpeechTranscriber` APIs are
    // new in macOS 26 Tahoe. Since the SDK may not expose them yet under macOS 14
    // (the deployment target set in Package.swift), we use runtime checks.
    //
    // The actual API surface is documented in PLAN 06-03 <interfaces>:
    //   SpeechAnalyzer.init(...)
    //   SpeechAnalyzer.add(modules:) async throws
    //   SpeechAnalyzer.feed(_ buffer: AVAudioPCMBuffer) async throws
    //   SpeechAnalyzer.finish() async throws
    //   SpeechTranscriber.results: AsyncStream<SpeechTranscriptionResult>
    //
    // Plan 06-05 (VoiceController) wires the live bridge with AVAudioPCMBuffer conversion.
    // For Plan 06-03, this is a structural shell; the real wiring happens in 06-05.

    nonisolated(unsafe) private var partialsContinuation: AsyncStream<String>.Continuation?
    nonisolated(unsafe) private var collectedText = ""
    nonisolated(unsafe) private var finalizationError: (any Error)?

    func start() async throws {
        // Setup happens on first feed(); placeholder for 06-05 to wire live APIs.
    }

    func feed(_ chunk: AudioChunk) async throws {
        // Convert AudioChunk → AVAudioPCMBuffer and call analyzer.feed()
        // Wired fully in Plan 06-05. Placeholder here.
        _ = chunk
    }

    func finish() async throws {
        partialsContinuation?.finish()
    }

    func partialResults() -> AsyncStream<String> {
        let (stream, cont) = AsyncStream<String>.makeStream()
        self.partialsContinuation = cont
        return stream
    }

    func finalText() async throws -> String {
        if let err = finalizationError { throw err }
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
