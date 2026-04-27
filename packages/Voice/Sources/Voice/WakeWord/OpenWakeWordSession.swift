import Foundation
import OnnxRuntimeBindings  // product: onnxruntime from microsoft/onnxruntime-swift-package-manager

/// Three-stage openWakeWord pipeline: mel-spectrogram → embedding → classifier.
///
/// Each stage runs in a SEPARATE ORTSession — do NOT share sessions across stages.
/// Thread-safety rationale: `ORTSession.run` is synchronous and not thread-safe
/// (RESEARCH §1). Actor isolation ensures only one call is in-flight at a time.
///
/// ## Hysteresis (VOICE-01)
/// `feed` returns `.fired` only after `framesRequired` consecutive frames exceed
/// `threshold`. A single below-threshold frame resets the counter to zero.
/// Default framesRequired: 4 ≈ 320 ms at 80 ms/frame (RESEARCH §1, CLAUDE.md voice stack).
///
/// ## Anti-patterns (RESEARCH §1)
/// - DO NOT share a single ORTSession across mel/embedding/classifier stages.
/// - DO NOT block the AVAudioEngine tap thread on ORTSession.run — read from
///   the ring on a dedicated Task (see WakeWordDAG).
/// - DO NOT auto-redownload weights on hash mismatch — fail closed (T-06-02-01).
public actor OpenWakeWordSession {

    // MARK: - Public init (production — requires model files on disk)

    /// Creates the session, verifying model hashes then initialising three ORT sessions.
    ///
    /// - Parameters:
    ///   - modelDir: Directory containing `MANIFEST.json` + three ONNX files.
    ///   - threshold: Classifier probability threshold. Default 0.5.
    ///   - framesRequired: Consecutive above-threshold frames required to fire.
    ///     Default 4 ≈ 320 ms hysteresis (VOICE-01).
    /// - Throws: `WakeWordError.modelHashMismatch` / `.missingModel` if manifest
    ///   verification fails. `WakeWordError.ortInitFailed` if ORT init throws.
    public init(modelDir: URL, threshold: Float = 0.5, framesRequired: Int = 4) throws {
        // Step 1: manifest SHA-256 verification — fail closed (T-06-02-01)
        // NEVER auto-redownload on mismatch; surface the error.
        try ModelManifest.verify(modelDir: modelDir)

        // Step 2: initialise ORT — one session per stage (RESEARCH §1)
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let melPath = modelDir.appendingPathComponent("melspectrogram.onnx").path
            let embPath = modelDir.appendingPathComponent("embedding_model.onnx").path
            let jarPath = modelDir.appendingPathComponent("hey_jarvis_v0.1.onnx").path

            self.melSession = try ORTSession(env: env, modelPath: melPath, sessionOptions: nil)
            self.embeddingSession = try ORTSession(env: env, modelPath: embPath, sessionOptions: nil)
            self.classifierSession = try ORTSession(env: env, modelPath: jarPath, sessionOptions: nil)
        } catch {
            throw WakeWordError.ortInitFailed
        }

        self.threshold = threshold
        self.framesRequired = framesRequired
        self.scriptedClassifier = nil
    }

    // MARK: - Internal test init (scripted — bypasses ORT)

    /// Test-only initialiser that bypasses ORT inference.
    ///
    /// The `scriptedClassifier` closure receives the raw PCM input array and returns
    /// a classifier probability. The hysteresis logic is fully exercised without
    /// loading any model files.
    ///
    /// - Note: `internal` to prevent production use of this test seam.
    internal init(
        scriptedClassifier: @escaping @Sendable ([Float]) -> Float,
        threshold: Float = 0.5,
        framesRequired: Int = 4  // default 4 anchors VOICE-01 320 ms hysteresis
    ) {
        self.melSession = nil
        self.embeddingSession = nil
        self.classifierSession = nil
        self.threshold = threshold
        self.framesRequired = framesRequired
        self.scriptedClassifier = scriptedClassifier
    }

    // MARK: - Public feed API

    /// Feeds one frame of 16 kHz mono PCM audio through the pipeline.
    ///
    /// The caller is responsible for providing 1280 samples (80 ms at 16 kHz —
    /// one mel frame). The scripted path ignores buffer contents.
    ///
    /// Hysteresis logic (see `runHysteresis` for implementation):
    /// - above threshold: counter++ → if counter >= framesRequired: reset+fire
    /// - below threshold: counter resets to zero
    ///
    /// - Parameter pcm16k: Float32 mono samples at 16 kHz.
    /// - Returns: `.fired` after `framesRequired` consecutive above-threshold frames.
    /// - Throws: `WakeWordError.ortInitFailed` if ORT sessions are absent (scripted
    ///   path is used via `feedTest()`, not through this method).
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> DetectionDecision {
        let samples = Array(pcm16k)
        return try runHysteresis(pcmSamples: samples)
    }

    // MARK: - Internal test helper

    /// Feeds an empty frame through the scripted classifier path.
    ///
    /// Used by `WakeWordHysteresisTests.feedAll` to avoid the Swift 6 restriction
    /// that `UnsafeBufferPointer` cannot escape a synchronous closure when the
    /// actor method is `async`. The scripted classifier ignores the buffer anyway.
    internal func feedTest() throws -> DetectionDecision {
        return try runHysteresis(pcmSamples: [])
    }

    // MARK: - Private state

    private let threshold: Float
    private let framesRequired: Int     // default: 4 — VOICE-01 ≥4-frame hysteresis
    private var consecutive: Int = 0   // count of consecutive above-threshold frames

    // ORT sessions — one per stage (RESEARCH §1: NO sharing)
    private let melSession: ORTSession?
    private let embeddingSession: ORTSession?
    private let classifierSession: ORTSession?

    // Test seam: non-nil only when constructed via the scripted init
    private let scriptedClassifier: (@Sendable ([Float]) -> Float)?

    // MARK: - Hysteresis core (shared by feed and feedTest)

    private func runHysteresis(pcmSamples: [Float]) throws -> DetectionDecision {
        let prob: Float

        if let scripted = scriptedClassifier {
            // Test path: scripted closure returns the next probability
            prob = scripted(pcmSamples)
        } else {
            // Production path: run three ORT stages
            prob = try runORT(pcmSamples: pcmSamples)
        }

        // Hysteresis counter logic (VOICE-01: framesRequired: 4 ≈ 320 ms)
        if prob >= threshold {
            consecutive += 1
            if consecutive >= framesRequired {
                consecutive = 0
                return .fired
            }
        } else {
            consecutive = 0
        }
        return .none
    }

    /// Runs mel → embedding → classifier ORT pipeline.
    /// Called only from the production path (scriptedClassifier == nil).
    private func runORT(pcmSamples: [Float]) throws -> Float {
        guard let melSess = melSession,
              let embSess = embeddingSession,
              let clsSess = classifierSession else {
            throw WakeWordError.ortInitFailed
        }

        // Mel stage: input shape [1, frames]
        let frameCount = NSNumber(value: pcmSamples.count)
        let melData = NSMutableData(bytes: pcmSamples,
                                    length: pcmSamples.count * MemoryLayout<Float>.stride)
        let melInput = try ORTValue(tensorData: melData,
                                    elementType: .float,
                                    shape: [1, frameCount])
        let melOutputs = try melSess.run(withInputs: ["input": melInput],
                                          outputNames: ["output"],
                                          runOptions: nil)
        guard let melOutput = melOutputs["output"] else {
            throw WakeWordError.ortInitFailed
        }

        // Embedding stage
        let embOutputs = try embSess.run(withInputs: ["input": melOutput],
                                          outputNames: ["output"],
                                          runOptions: nil)
        guard let embOutput = embOutputs["output"] else {
            throw WakeWordError.ortInitFailed
        }

        // Classifier stage
        let clsOutputs = try clsSess.run(withInputs: ["input": embOutput],
                                          outputNames: ["output"],
                                          runOptions: nil)
        guard let clsOutput = clsOutputs["output"] else {
            throw WakeWordError.ortInitFailed
        }

        // Extract scalar probability from classifier output
        let clsData = try clsOutput.tensorData()
        guard clsData.length >= MemoryLayout<Float>.stride else {
            throw WakeWordError.ortInitFailed
        }
        var prob: Float = 0
        clsData.getBytes(&prob, length: MemoryLayout<Float>.stride)
        return prob
    }
}

// MARK: - Supporting types

/// The result of a single wake-word frame evaluation.
public enum DetectionDecision: Sendable, Equatable {
    case none
    case fired
}

/// Wake-word events emitted on `WakeWordDAG.wakeWordStream`.
public enum WakeWordEvent: Sendable, Equatable {
    case fired(at: Date)
}
