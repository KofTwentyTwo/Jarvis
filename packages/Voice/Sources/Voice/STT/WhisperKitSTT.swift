import Foundation
import OSLog
import WhisperKit

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "WhisperKitSTT")

// MARK: - WhisperKitBridge (test seam)

/// Protocol bridging the WhisperKit transcription API.
///
/// Production code creates a `LiveWhisperKitBridge`; tests inject `MockWhisperKitBridge`.
/// This seam avoids loading real model weights during unit tests.
public protocol WhisperKitBridge: Sendable {
    /// Transcribe an array of 16 kHz mono Float32 samples.
    func transcribe(audioArray: [Float]) async throws -> String
}

// MARK: - WhisperKitSTT

/// Fallback STT provider using WhisperKit from argmax-oss-swift v0.18.0.
///
/// Model string is the Argmax-versioned MLX variant per RESEARCH §4 — see `modelName`.
///
/// ANTI-PATTERN GUARD: DO NOT change the model string to the HF Whisper variant.
/// The HF Whisper large-v3 turbo variant is NOT the Argmax MLX variant.
/// Using the wrong model string downloads a completely different model (~3x larger).
/// The W2 unit test enforces this as a grep gate.
///
/// Async init: `WhisperKit(model:)` is async throws. `WhisperKitSTT` defers model loading
/// until first `transcribe()` call via `LazyWhisperKitBridge`, keeping `STTBackendSelector.make`
/// synchronous (Rule: selector is always synchronous).
///
/// Feature flag: enabled by `FeatureFlag.whisperKitSTTEnabled` in `PerTurnSnapshot.featureFlags`.
public final class WhisperKitSTT: STTProvider {

    // MARK: - Model string (load-bearing)

    /// Argmax-versioned MLX model string (RESEARCH §4 / RESEARCH-DELTAS D5).
    ///
    /// Grep gate: exactly 1 non-comment occurrence of this string in the file.
    public static let modelName = "large-v3-v20240930_626MB"

    // MARK: - State

    private let bridge: any WhisperKitBridge
    nonisolated(unsafe) private var audioBuffer: [Float] = []
    nonisolated(unsafe) private var finishedTranscript: String = ""
    nonisolated(unsafe) private var streamContinuation: AsyncStream<PartialTranscript>.Continuation?
    nonisolated(unsafe) private var processingTask: Task<Void, Never>?

    // MARK: - Init

    /// Production init using the lazy-loading real WhisperKit bridge.
    ///
    /// Model loading is deferred to first transcription call so this init
    /// is synchronous — required for `STTBackendSelector.make` to be synchronous.
    public init() {
        self.bridge = LazyWhisperKitBridge(modelName: Self.modelName)
    }

    /// Test-seam init: inject a custom bridge.
    init(kitBridge: any WhisperKitBridge) {
        self.bridge = kitBridge
    }

    // MARK: - STTProvider

    public func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        audioBuffer = []
        let (asyncStream, continuation) = AsyncStream<PartialTranscript>.makeStream()
        self.streamContinuation = continuation

        processingTask = Task { [weak self] in
            guard let self else { return }

            // Buffer all audio chunks (~500 ms windows then transcribe)
            var windowBuffer: [Float] = []
            let windowSize = 16_000 / 2  // ~500 ms at 16 kHz

            for await chunk in stream {
                windowBuffer.append(contentsOf: chunk.pcm16k)
                self.audioBuffer.append(contentsOf: chunk.pcm16k)

                if windowBuffer.count >= windowSize {
                    // Transcribe the accumulated window.
                    // P2-7 (audit 2026-05-04 code-style): catch + log instead
                    // of silent try?. The fallback STT path is allowed to fail
                    // back to assetMissing, but failures should be diagnosable.
                    // T-06-05-03: never log transcript content — only the error.
                    do {
                        let text = try await self.bridge.transcribe(audioArray: windowBuffer)
                        if !text.isEmpty {
                            continuation.yield(PartialTranscript(text: text, isFinal: false))
                        }
                    } catch {
                        logger.warning("WhisperKitSTT: window transcribe failed: \(String(describing: error))")
                    }
                    windowBuffer = []
                }
            }

            // Flush remaining audio
            if !windowBuffer.isEmpty {
                do {
                    let text = try await self.bridge.transcribe(audioArray: windowBuffer)
                    if !text.isEmpty {
                        continuation.yield(PartialTranscript(text: text, isFinal: false))
                    }
                } catch {
                    logger.warning("WhisperKitSTT: tail transcribe failed: \(String(describing: error))")
                }
            }

            // Final transcription of the full buffer for accuracy
            if !self.audioBuffer.isEmpty {
                do {
                    let finalText = try await self.bridge.transcribe(audioArray: self.audioBuffer)
                    self.finishedTranscript = finalText
                    continuation.yield(PartialTranscript(text: finalText, isFinal: true))
                } catch {
                    logger.warning("WhisperKitSTT: final transcribe failed: \(String(describing: error))")
                }
            }

            continuation.finish()
        }

        return asyncStream
    }

    public func finalize() async throws -> String {
        await processingTask?.value
        return finishedTranscript
    }
}

// MARK: - LazyWhisperKitBridge

/// Defers async `WhisperKit(model:)` init until first transcription call.
///
/// Pattern: `STTBackendSelector.make` is synchronous; WhisperKit's init is async throws.
/// `LazyWhisperKitBridge` wraps the async init in a lazy property accessed on first use.
/// Documented inline per PLAN 06-03 requirement.
private final class LazyWhisperKitBridge: WhisperKitBridge, @unchecked Sendable {
    private let modelName: String
    private var _kit: WhisperKit?
    private var initError: (any Error)?

    init(modelName: String) {
        self.modelName = modelName
    }

    /// Lazily initialise `WhisperKit` on first call.
    private func kit() async throws -> WhisperKit {
        if let err = initError { throw err }
        if let k = _kit { return k }
        do {
            let k = try await WhisperKit(model: modelName)
            _kit = k
            return k
        } catch {
            initError = error
            throw error
        }
    }

    func transcribe(audioArray: [Float]) async throws -> String {
        let k = try await kit()
        let results = try await k.transcribe(audioArray: audioArray)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
