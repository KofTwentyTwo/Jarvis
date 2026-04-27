import Foundation
import OnnxRuntimeBindings

// MARK: - VADDecision

/// The speech/silence decision emitted by `SileroVAD.feed(_:)`.
///
/// Transitions are emitted ONCE at the boundary:
/// - `.speechStart` fires on the first chunk where the model crosses threshold
///   (previous chunk was silence).
/// - `.speechEnd` fires on the first chunk that falls back below threshold
///   (previous chunk was speech).
/// Steady-state chunks emit `.speech` or `.silence`.
public enum VADDecision: Sendable, Equatable {
    case speech
    case silence
    /// Emitted on the silence → speech transition.
    case speechStart
    /// Emitted on the speech → silence transition.
    case speechEnd
}

// MARK: - VADInferenceEngine (test seam)

/// Protocol allowing `SileroVAD` to be tested without real ONNX models.
///
/// Production code uses `ORTVADEngine`; tests inject `MockVADEngine`.
public protocol VADInferenceEngine: Sendable {
    /// Run one inference pass on a 512-sample chunk; returns speech probability [0, 1].
    func runInference(pcm: UnsafeBufferPointer<Float>) throws -> Float
}

/// Optional protocol exposing which opset was loaded (test seam for S4).
/// `MockVADEngine` in the test target conforms to this to expose `opsetUsed`.
public protocol TestableVADOpset {
    var opsetUsed: Int { get }
}

// MARK: - ORTVADEngine

/// Production `VADInferenceEngine` backed by `ORTSession` with Silero VAD v6.2.1.
///
/// Opset strategy (CLAUDE.md voice stack / RESEARCH-DELTAS A1):
/// - Try `silero_vad.onnx` (opset-16) first.
/// - On load failure, fall back to `silero_vad_16k_op15.onnx` (opset-15).
/// - `loadedOpset` exposes which was loaded (test seam).
///
/// Hidden state:
/// Silero VAD v6.2.1 requires the previous timestep's hidden (h) and cell (c)
/// LSTM state as model inputs. Shapes confirmed from the v6.2.1 release:
///   - `h`: [2, 1, 64]  (2 layers, batch=1, 64 hidden units)
///   - `c`: [2, 1, 64]
/// State is zeroed at init and after `reset()`.
public final class ORTVADEngine: VADInferenceEngine, @unchecked Sendable {

    // MARK: - Constants

    /// RESEARCH-DELTAS A1: chunk contract preserved from v5. 512 samples = 32 ms at 16 kHz.
    static let chunkSamples = 512
    static let sampleRate: Int32 = 16000

    // Silero v6.2.1 hidden state shapes [2, 1, 64]
    private static let hiddenShape: [NSNumber] = [2, 1, 64]
    private static let hiddenCount = 2 * 1 * 64  // 128 floats

    // MARK: - ORT state

    private let env: ORTEnv
    private let session: ORTSession
    public let loadedOpset: Int

    // MARK: - LSTM hidden state (mutable)

    nonisolated(unsafe) private var h: [Float]  // shape [2, 1, 64]
    nonisolated(unsafe) private var c: [Float]  // shape [2, 1, 64]

    // MARK: - Init

    /// Load the Silero VAD model, trying opset-16 first with opset-15 fallback.
    ///
    /// - Parameter modelDir: Directory containing `silero_vad.onnx` and/or
    ///   `silero_vad_16k_op15.onnx`.
    public init(modelDir: URL) throws {
        let opset16URL = modelDir.appendingPathComponent("silero_vad.onnx")
        let opset15URL = modelDir.appendingPathComponent("silero_vad_16k_op15.onnx")

        self.env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(1)

        var session: ORTSession?
        var loadedOpset: Int

        // Try opset-16 first (CLAUDE.md: opset-16 preferred with opset-15 fallback)
        do {
            session = try ORTSession(env: env, modelPath: opset16URL.path, sessionOptions: opts)
            loadedOpset = 16
        } catch {
            // Opset-16 load failed; try opset-15 fallback
            do {
                session = try ORTSession(env: env, modelPath: opset15URL.path, sessionOptions: opts)
                loadedOpset = 15
                // Log which opset loaded
                print("[SileroVAD] opset-16 load failed (\(error.localizedDescription)); using opset-15 fallback")
            } catch let fallbackError {
                throw VADError.modelLoadFailed(underlying: fallbackError)
            }
        }

        guard let s = session else { throw VADError.opsetUnsupported }
        self.session = s
        self.loadedOpset = loadedOpset

        // Zero-initialise LSTM hidden state
        self.h = [Float](repeating: 0, count: Self.hiddenCount)
        self.c = [Float](repeating: 0, count: Self.hiddenCount)
    }

    // MARK: - VADInferenceEngine

    public func runInference(pcm: UnsafeBufferPointer<Float>) throws -> Float {
        // Build input tensor: [1, 512] float32
        let inputData = NSMutableData(bytes: pcm.baseAddress!, length: pcm.count * MemoryLayout<Float>.size)
        let inputShape: [NSNumber] = [1, NSNumber(value: pcm.count)]
        guard let inputValue = try? ORTValue(tensorData: inputData,
                                            elementType: .float,
                                            shape: inputShape) else {
            throw VADError.runFailed("Failed to create input ORTValue")
        }

        // Build hidden-state tensors
        let hData = NSMutableData(bytes: h, length: h.count * MemoryLayout<Float>.size)
        guard let hValue = try? ORTValue(tensorData: hData,
                                         elementType: .float,
                                         shape: Self.hiddenShape) else {
            throw VADError.runFailed("Failed to create h ORTValue")
        }

        let cData = NSMutableData(bytes: c, length: c.count * MemoryLayout<Float>.size)
        guard let cValue = try? ORTValue(tensorData: cData,
                                         elementType: .float,
                                         shape: Self.hiddenShape) else {
            throw VADError.runFailed("Failed to create c ORTValue")
        }

        // Build sample rate tensor: scalar int64
        var sr = Self.sampleRate
        let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        let srShape: [NSNumber] = [1]
        guard let srValue = try? ORTValue(tensorData: srData,
                                          elementType: .int64,
                                          shape: srShape) else {
            throw VADError.runFailed("Failed to create sr ORTValue")
        }

        let inputs: [String: ORTValue] = [
            "input": inputValue,
            "h": hValue,
            "c": cValue,
            "sr": srValue
        ]

        guard let outputs = try? session.run(withInputs: inputs,
                                              outputNames: ["output", "hn", "cn"],
                                              runOptions: nil) else {
            throw VADError.runFailed("ORTSession run failed")
        }

        // Extract speech probability from output tensor
        guard let outputData = try? outputs["output"]?.tensorData(),
              outputData.length >= MemoryLayout<Float>.size else {
            throw VADError.runFailed("Missing or empty output tensor")
        }
        let prob = outputData.bytes.load(as: Float.self)

        // Update hidden state
        if let hnData = try? outputs["hn"]?.tensorData(), hnData.length == Self.hiddenCount * MemoryLayout<Float>.size {
            h = Array(UnsafeBufferPointer(start: hnData.bytes.assumingMemoryBound(to: Float.self),
                                          count: Self.hiddenCount))
        }
        if let cnData = try? outputs["cn"]?.tensorData(), cnData.length == Self.hiddenCount * MemoryLayout<Float>.size {
            c = Array(UnsafeBufferPointer(start: cnData.bytes.assumingMemoryBound(to: Float.self),
                                          count: Self.hiddenCount))
        }

        return prob
    }

    /// Reset LSTM hidden state (between utterances).
    public func reset() {
        h = [Float](repeating: 0, count: Self.hiddenCount)
        c = [Float](repeating: 0, count: Self.hiddenCount)
    }
}

// MARK: - SileroVAD

/// Silero VAD v6.2.1 actor: feeds 512-sample (32 ms / 16 kHz) chunks and emits
/// speech/silence decisions with transition events.
///
/// RESEARCH-DELTAS A1: the 512-sample / 32 ms / 16 kHz chunk contract is preserved
/// between Silero v5 and v6.2.1 (confirmed by `ContractParityProbe`).
///
/// Usage:
/// ```swift
/// let vad = try SileroVAD(modelDir: url)
/// // or for tests:
/// let vad = SileroVAD(engine: mockEngine)
/// ```
///
/// Thread safety: `SileroVAD` is NOT an actor — it is designed to be owned by a
/// single consuming task (e.g. the WakeWord DAG task from Plan 06-02). Concurrent
/// `feed` calls are not safe. `reset()` must also be called from the same context.
public final class SileroVAD: @unchecked Sendable {

    // MARK: - Constants

    /// RESEARCH-DELTAS A1: chunk contract preserved from v5.
    public static let requiredChunkSize = 512

    /// Default speech/silence threshold (Silero recommended).
    public let threshold: Float

    // MARK: - State

    private let engine: any VADInferenceEngine
    private var wasSpeech: Bool = false

    /// Test seam: which opset was loaded (16 or 15).
    public let loadedOpset: Int

    // MARK: - Init (production — real ONNX model)

    /// Load the Silero VAD model from `modelDir`.
    ///
    /// Tries opset-16 (`silero_vad.onnx`) first; falls back to opset-15
    /// (`silero_vad_16k_op15.onnx`) on load error. Logs which opset is in use.
    public init(modelDir: URL, threshold: Float = 0.5) throws {
        let ortEngine = try ORTVADEngine(modelDir: modelDir)
        self.engine = ortEngine
        self.loadedOpset = ortEngine.loadedOpset
        self.threshold = threshold
    }

    // MARK: - Init (test seam)

    /// Initialise with an injected inference engine (test use only).
    ///
    /// `loadedOpset` is derived from `engine.loadedOpset` if the engine exposes
    /// that property (see `TestableVADEngine`); defaults to 16 otherwise.
    init(engine: any VADInferenceEngine, threshold: Float = 0.5) {
        self.engine = engine
        self.threshold = threshold
        if let seamed = engine as? (any VADInferenceEngine & TestableVADOpset) {
            self.loadedOpset = seamed.opsetUsed
        } else {
            self.loadedOpset = 16
        }
    }

    // MARK: - Core API

    /// Feed exactly 512 samples (32 ms at 16 kHz) and receive a VAD decision.
    ///
    /// - Parameter pcm16k: Pointer to exactly 512 Float32 samples at 16 kHz mono.
    /// - Returns: `.silence`, `.speech`, `.speechStart`, or `.speechEnd`.
    /// - Throws: `VADError.invalidChunkSize` if `pcm16k.count != 512`.
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> VADDecision {
        guard pcm16k.count == Self.requiredChunkSize else {
            throw VADError.invalidChunkSize(got: pcm16k.count, expected: Self.requiredChunkSize)
        }

        let prob = try engine.runInference(pcm: pcm16k)
        let isSpeech = prob >= threshold

        let decision: VADDecision
        switch (wasSpeech, isSpeech) {
        case (false, true):  decision = .speechStart
        case (true, true):   decision = .speech
        case (true, false):  decision = .speechEnd
        case (false, false): decision = .silence
        }

        wasSpeech = isSpeech
        return decision
    }

    /// Reset hidden state and `wasSpeech` flag (between utterances).
    ///
    /// Call between processing separate audio segments to prevent the tail of one
    /// segment from affecting the head of the next.
    public func reset() {
        wasSpeech = false
        if let ortEngine = engine as? ORTVADEngine {
            ortEngine.reset()
        }
        // MockVADEngine has no state to reset beyond the SileroVAD wasSpeech flag.
    }
}

// MARK: - MockVADEngine (available in tests via @testable import)

// NOTE: MockVADEngine is defined in SileroContractTests.swift (test target).
// SileroVAD.init(engine:) is `internal` visibility — available via @testable import.
