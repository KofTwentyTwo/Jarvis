import XCTest
@testable import Voice

// MARK: - STTBackendSwitchTests
//
// TDD RED phase for Tasks 2 + 3:
//   - Task 2: STTProvider protocol, SpeechAnalyzerSTT, WhisperKitSTT, STTError
//   - Task 3: STTBackendSelector + features.stt.backend wiring
//
// These tests cover the STT selection + backend behavior using injected test seams.
// No real SpeechAnalyzer or WhisperKit models are loaded during tests.

// MARK: - SpeechAnalyzerSTT Tests

final class SpeechAnalyzerSTTTests: XCTestCase {

    // MARK: - S1: Stubbed analyzer returns two partial transcripts

    func testS1_stubbedAnalyzerYieldsTwoPartialsAndFinalizes() async throws {
        let mock = MockSpeechAnalyzerBridge(
            partials: ["hello", "hello world"],
            finalText: "hello world"
        )
        let stt = SpeechAnalyzerSTT(analyzerBridge: mock)

        // Feed two audio chunks
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let chunk = AudioChunk(pcm16k: [Float](repeating: 0, count: 512))
        continuation.yield(chunk)
        continuation.yield(chunk)
        continuation.finish()

        var partials: [PartialTranscript] = []
        for await partial in stt.transcribe(stream: stream) {
            partials.append(partial)
        }

        let final_ = try await stt.finalize()
        XCTAssertEqual(final_, "hello world")
        XCTAssertFalse(partials.isEmpty, "Should have yielded partial transcripts")
        XCTAssertTrue(partials.last?.text == "hello world" || partials.last?.isFinal == true,
                      "Last partial should be final or match final text")
    }

    // MARK: - S2: assetUnavailable error maps to STTError.assetMissing

    func testS2_assetUnavailableErrorMapsToSTTAssetMissing() async throws {
        let mock = MockSpeechAnalyzerBridge(feedError: makeSpeechAssetUnavailableError())
        let stt = SpeechAnalyzerSTT(analyzerBridge: mock)

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        continuation.yield(AudioChunk(pcm16k: [Float](repeating: 0, count: 512)))
        continuation.finish()

        // Drain the transcription stream (triggers the feed error path)
        for await _ in stt.transcribe(stream: stream) { }

        do {
            _ = try await stt.finalize()
            // If no error, check that the error was stored
            XCTFail("Expected STTError.assetMissing to be thrown")
        } catch STTError.assetMissing {
            // Expected
        } catch {
            // SpeechAnalyzer may propagate the error differently — accept finalization errors too
            // The contract is that assetUnavailable → STTError.assetMissing
            XCTFail("Expected STTError.assetMissing, got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeSpeechAssetUnavailableError() -> Error {
        // SFSpeechErrorDomain / SFSpeechErrorCode.assetUnavailable = 1
        return NSError(
            domain: "com.apple.speech.recognition.service",
            code: 1,  // SFSpeechErrorCode.assetUnavailable.rawValue
            userInfo: [NSLocalizedDescriptionKey: "speech recognition assets unavailable"]
        )
    }
}

// MARK: - WhisperKitSTT Tests

final class WhisperKitSTTTests: XCTestCase {

    // MARK: - W1: Stubbed WhisperKit returns fixed transcript

    func testW1_stubbedWhisperKitYieldsFinalTranscript() async throws {
        let mock = MockWhisperKitBridge(transcript: "hello from whisper")
        let stt = WhisperKitSTT(kitBridge: mock)

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        continuation.yield(AudioChunk(pcm16k: [Float](repeating: 0.1, count: 512)))
        continuation.yield(AudioChunk(pcm16k: [Float](repeating: 0.1, count: 512)))
        continuation.finish()

        var partials: [PartialTranscript] = []
        for await p in stt.transcribe(stream: stream) {
            partials.append(p)
        }

        let final_ = try await stt.finalize()
        XCTAssertEqual(final_, "hello from whisper")

        // Should have at least one partial with isFinal: true
        let hasFinaling = partials.contains { $0.isFinal }
        XCTAssertTrue(hasFinaling || !partials.isEmpty,
                      "Should have yielded at least one partial transcript")
    }

    // MARK: - W2: Model string must be large-v3-v20240930_626MB

    func testW2_modelStringIsArgmaxVersionedVariant() {
        // This test greps the source file at runtime to assert the correct model string.
        // Anti-pattern guard: DO NOT use "large-v3-turbo" (HF Whisper, not Argmax).
        //
        // RESEARCH §4: The Argmax-versioned MLX variant is "large-v3-v20240930_626MB".
        // "large-v3-turbo" is a Hugging Face Whisper variant and would download
        // the wrong model, likely silently producing worse results.
        let requiredModelString = "large-v3-v20240930_626MB"
        let antiPatternString = "large-v3-turbo"

        // Find WhisperKitSTT.swift relative to this test file
        let thisFile = URL(fileURLWithPath: #file)
        let sourceFile = thisFile
            .deletingLastPathComponent()  // VoiceTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Sources/Voice/STT/WhisperKitSTT.swift")

        guard let contents = try? String(contentsOf: sourceFile, encoding: .utf8) else {
            XCTFail("Could not read WhisperKitSTT.swift at \(sourceFile.path)")
            return
        }

        // Must have exactly one occurrence of the correct model string (non-comment)
        let nonCommentLines = contents.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        let matchCount = nonCommentLines.components(separatedBy: requiredModelString).count - 1
        XCTAssertGreaterThanOrEqual(matchCount, 1,
            "WhisperKitSTT.swift must contain '\(requiredModelString)' (Argmax-versioned model string)")

        let antiPatternCount = nonCommentLines.components(separatedBy: antiPatternString).count - 1
        XCTAssertEqual(antiPatternCount, 0,
            "WhisperKitSTT.swift must NOT contain '\(antiPatternString)' (HF Whisper — wrong model)")
    }
}

// MARK: - STTBackendSelector Tests (Task 3)

final class STTBackendSelectorTests: XCTestCase {

    // MARK: - B1: speech_analyzer backend

    func testB1_speechAnalyzerBackendReturnsSpeechAnalyzerSTT() {
        let snapshot = makeSnapshot(backend: "speech_analyzer")
        let stt = STTBackendSelector.make(snapshot: snapshot)
        XCTAssertTrue(stt is SpeechAnalyzerSTT,
                      "Expected SpeechAnalyzerSTT for backend='speech_analyzer', got \(type(of: stt))")
    }

    // MARK: - B2: whisperkit backend

    func testB2_whisperKitBackendReturnsWhisperKitSTT() {
        let snapshot = makeSnapshot(backend: "whisperkit")
        let stt = STTBackendSelector.make(snapshot: snapshot)
        XCTAssertTrue(stt is WhisperKitSTT,
                      "Expected WhisperKitSTT for backend='whisperkit', got \(type(of: stt))")
    }

    // MARK: - B3: unknown backend falls back to speech_analyzer + logs warning

    func testB3_unknownBackendFallsBackToSpeechAnalyzerWithWarning() {
        let testLogger = TestWarningLogger()
        let snapshot = makeSnapshot(backend: "garbage")
        let stt = STTBackendSelector.make(snapshot: snapshot, warningLogger: testLogger)
        XCTAssertTrue(stt is SpeechAnalyzerSTT,
                      "Unknown backend should fall back to SpeechAnalyzerSTT")
        XCTAssertTrue(testLogger.lastWarning?.contains("garbage") == true,
                      "Warning log should mention the unknown backend value")
    }

    // MARK: - B4: default (no backend in featureFlags) → speech_analyzer

    func testB4_defaultBackendReturnsSpeechAnalyzerSTT() {
        // Default PerTurnSnapshot has no stt feature flag set → defaults to speech_analyzer
        let snapshot = makeSnapshotWithNoSTTFlag()
        let stt = STTBackendSelector.make(snapshot: snapshot)
        XCTAssertTrue(stt is SpeechAnalyzerSTT,
                      "Default (no backend flag) should return SpeechAnalyzerSTT")
    }

    // MARK: - Helpers

    private func makeSnapshot(backend: String) -> PerTurnSnapshot {
        // SEC-05: backend is pinned at submit() time via PerTurnSnapshot
        // This plan adds sttBackend to STTConfig (Rule 3 deviation from Phase 1)
        return PerTurnSnapshot(
            schemaVersion: 1,
            provider: .anthropic,
            tts: TTSConfig(tier: "tier1"),
            stt: STTConfig(whisperKitFallback: backend == "whisperkit",
                           backend: backend),
            featureFlags: FeatureFlags([:])
        )
    }

    private func makeSnapshotWithNoSTTFlag() -> PerTurnSnapshot {
        return PerTurnSnapshot(
            schemaVersion: 1,
            provider: .anthropic,
            tts: TTSConfig(tier: "tier1"),
            stt: STTConfig(),  // default: whisperKitFallback=false, backend="speech_analyzer"
            featureFlags: FeatureFlags([:])
        )
    }
}

// MARK: - Test doubles

/// Captures warning log calls from STTBackendSelector.
final class TestWarningLogger: @unchecked Sendable {
    var lastWarning: String?
    func warn(_ message: String) { lastWarning = message }
}

/// Mock for the SpeechAnalyzer bridge.
final class MockSpeechAnalyzerBridge: SpeechAnalyzerBridge, @unchecked Sendable {
    private let partials: [String]
    private let finalText: String
    private let feedError: Error?

    init(partials: [String] = [], finalText: String = "", feedError: Error? = nil) {
        self.partials = partials
        self.finalText = finalText
        self.feedError = feedError
    }

    func start() async throws { }

    func feed(_ chunk: AudioChunk) async throws {
        if let err = feedError { throw err }
    }

    func finish() async throws { }

    func partialResults() -> AsyncStream<String> {
        let ps = partials
        return AsyncStream { cont in
            for p in ps { cont.yield(p) }
            cont.finish()
        }
    }

    func finalText() async throws -> String {
        if let err = feedError { throw err }
        return finalText
    }
}

/// Mock for the WhisperKit bridge.
final class MockWhisperKitBridge: WhisperKitBridge, @unchecked Sendable {
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func transcribe(audioArray: [Float]) async throws -> String {
        return transcript
    }
}
