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

    /// Array-typed overload for callers that cannot escape `UnsafeBufferPointer`
    /// across `await` boundaries (Swift 6 forbids the pointer leaving the sync
    /// `withUnsafeBufferPointer` closure into an async-suspended actor hop).
    /// The harness `WakeHysteresisRunner` consumes this path directly.
    /// Production audio-tap code keeps using the buffer-pointer overload to
    /// avoid the per-frame Array copy.
    ///
    /// - Parameter samples: Float32 mono samples at 16 kHz (1280 per frame).
    /// - Returns: `.fired` after `framesRequired` consecutive above-threshold frames.
    public func feed(samples: [Float]) throws -> DetectionDecision {
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

    /// Runs mel → embedding → classifier ORT pipeline for a single 1280-sample
    /// frame. The single-frame path is intentionally minimal — it accumulates
    /// audio into the mel buffer, runs mel only when enough samples are
    /// queued for the embedding model's 76-mel-frame window, then runs the
    /// classifier on the most recent 16 embeddings. Streaming state is held
    /// per-actor in `melFrameBuffer` and `embeddingBuffer`. For corpus / clip
    /// evaluation, prefer the bulk `evaluateClip(samples:)` API.
    ///
    /// ONNX I/O contract (verified via onnx graph inspection):
    /// - mel:        input "input" [B, samples] → output "output" [T, 1, X, 32]
    /// - embedding:  input "input_1" [B, 76, 32, 1] → output "conv2d_19" [B, 1, 1, 96]
    /// - classifier: input "x.1" [1, 16, 96] → output "53" [1, 1]
    private func runORT(pcmSamples: [Float]) throws -> Float {
        // Streaming path: accumulate samples, run when window is full.
        // Append to the streaming sample buffer, run mel on the appended chunk,
        // append mel frames to the streaming mel buffer, then if we have ≥76
        // mel frames accumulated, run embedding and append to embedding buffer,
        // then if we have ≥16 embeddings, run classifier and update last prob.
        let mels = try runMel(pcm: pcmSamples)
        melFrameBuffer.append(contentsOf: mels)

        // Run embedding on every new sliding window of 76 mel frames.
        // Use stride 8 (openWakeWord default) — more frequent embedding
        // updates without excessive ORT overhead.
        let embStride = 8
        while melFrameBuffer.count >= 76 + nextEmbStart {
            let window = Array(melFrameBuffer[nextEmbStart..<(nextEmbStart + 76)])
            let emb = try runEmbedding(melWindow: window)
            embeddingBuffer.append(emb)
            nextEmbStart += embStride
        }

        // Rolling-window trim (audit-2026-05-12 P1-1 / Issue #32). The
        // streaming path appended to both buffers append-only — at one
        // mel frame per 80 ms `feed` (production cadence), 24 h of
        // always-on listening accumulated ~130 MB of mel frames + ~50 MB
        // of embeddings retained forever. The leak was masked today by
        // `WakeWordDAG` cancelling on every audio-graph rebuild, but
        // closing #28 exposes it: fix one without the other and memory
        // grows unbounded across long sessions.
        //
        // Trim policy:
        //   - Keep last `76 + embStride` mel frames so the next embedding
        //     window has full context after the trim.
        //   - Keep last 16 embeddings to match the classifier's
        //     `suffix(16)` read.
        //   - When mel frames are dropped, slide `nextEmbStart` left by
        //     the same count so indexing remains valid (it indexes into
        //     `melFrameBuffer`).
        let melKeep = 76 + embStride
        if melFrameBuffer.count > melKeep {
            let drop = melFrameBuffer.count - melKeep
            melFrameBuffer.removeFirst(drop)
            // Shift `nextEmbStart` to stay aligned with the trimmed buffer.
            // Clamp at 0 in case more was dropped than the prior index.
            nextEmbStart = max(0, nextEmbStart - drop)
        }
        if embeddingBuffer.count > 16 {
            embeddingBuffer.removeFirst(embeddingBuffer.count - 16)
        }

        // Run classifier on the most recent 16 embeddings.
        guard embeddingBuffer.count >= 16 else {
            return 0  // not enough context yet — below threshold by definition
        }
        let recent = Array(embeddingBuffer.suffix(16))
        return try runClassifier(embeddings: recent)
    }

    // MARK: - Bulk clip evaluation (stateless)

    /// Evaluates a complete audio clip and returns whether the wake word was
    /// detected within it. Stateless — does not affect the streaming
    /// `feed()` buffers and resets internal scratch buffers on entry/exit.
    /// Intended for corpus / clip evaluation by the harness pillar (e).
    ///
    /// - Parameter samples: Float32 mono PCM at 16 kHz; entire clip in one buffer.
    /// - Returns: `.fired` if any classifier inference window over the clip
    ///   exceeds `threshold`; `.none` otherwise.
    public func evaluateClip(samples: [Float]) throws -> DetectionDecision {
        // Reset scratch buffers — bulk path is independent of streaming state.
        let savedMelBuffer = melFrameBuffer
        let savedEmbBuffer = embeddingBuffer
        let savedNextEmb = nextEmbStart
        defer {
            melFrameBuffer = savedMelBuffer
            embeddingBuffer = savedEmbBuffer
            nextEmbStart = savedNextEmb
        }
        melFrameBuffer = []
        embeddingBuffer = []
        nextEmbStart = 0

        guard let _ = melSession else {
            throw WakeWordError.ortInitFailed
        }

        // Mel: run once on the full clip.
        let mels = try runMel(pcm: samples)
        guard mels.count >= 76 else {
            return .none  // clip too short for even one embedding
        }

        // Embeddings: stride-8 sliding 76-frame windows over the mel buffer.
        let embStride = 8
        var embeddings: [[Float]] = []
        var i = 0
        while i + 76 <= mels.count {
            let window = Array(mels[i..<(i + 76)])
            let emb = try runEmbedding(melWindow: window)
            embeddings.append(emb)
            i += embStride
        }
        guard embeddings.count >= 16 else {
            return .none
        }

        // Classifier: stride-1 sliding 16-embedding windows. Track consecutive
        // above-threshold inferences and fire if framesRequired is reached.
        var consec = 0
        for j in 0...(embeddings.count - 16) {
            let window = Array(embeddings[j..<(j + 16)])
            let prob = try runClassifier(embeddings: window)
            if prob >= threshold {
                consec += 1
                if consec >= framesRequired {
                    return .fired
                }
            } else {
                consec = 0
            }
        }
        return .none
    }

    // MARK: - ORT stage helpers

    /// Runs the mel ONNX model on a PCM buffer and returns mel frames as
    /// [(time*X), 32] flattened into [[Float]] of length T·X with each inner
    /// array length 32.
    private func runMel(pcm: [Float]) throws -> [[Float]] {
        guard let melSess = melSession else {
            throw WakeWordError.ortInitFailed
        }
        let melData = NSMutableData(bytes: pcm,
                                    length: pcm.count * MemoryLayout<Float>.stride)
        let melInput = try ORTValue(tensorData: melData,
                                    elementType: .float,
                                    shape: [1, NSNumber(value: pcm.count)])
        let melOutputs = try melSess.run(withInputs: ["input": melInput],
                                         outputNames: ["output"],
                                         runOptions: nil)
        guard let melOutput = melOutputs["output"] else {
            throw WakeWordError.ortInitFailed
        }
        // Output shape [T, 1, X, 32] — squeeze and flatten to mel frames.
        let shape = try melOutput.tensorTypeAndShapeInfo().shape
        let counts = shape.map { Int(truncating: $0) }
        guard counts.count == 4, counts[3] == 32 else {
            throw WakeWordError.ortInitFailed
        }
        let t = counts[0], x = counts[2]
        let totalFrames = t * x
        let data = try melOutput.tensorData()
        let floatCount = totalFrames * 32
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: floatCount)
        defer { buffer.deallocate() }
        data.getBytes(buffer.baseAddress!, length: floatCount * MemoryLayout<Float>.stride)
        var frames: [[Float]] = []
        frames.reserveCapacity(totalFrames)
        for f in 0..<totalFrames {
            frames.append(Array(UnsafeBufferPointer(rebasing: buffer[(f * 32)..<((f + 1) * 32)])))
        }
        return frames
    }

    /// Runs the embedding ONNX model on a single 76-frame mel window
    /// (each frame 32 mel bands) and returns the 96-dim embedding vector.
    private func runEmbedding(melWindow: [[Float]]) throws -> [Float] {
        guard let embSess = embeddingSession, melWindow.count == 76 else {
            throw WakeWordError.ortInitFailed
        }
        // Pack [76, 32] mel frames into [1, 76, 32, 1] flat buffer.
        let flat: [Float] = melWindow.flatMap { frame -> [Float] in
            precondition(frame.count == 32, "mel frame must have 32 bands")
            return frame
        }
        let inputData = NSMutableData(bytes: flat,
                                      length: flat.count * MemoryLayout<Float>.stride)
        let input = try ORTValue(tensorData: inputData,
                                 elementType: .float,
                                 shape: [1, 76, 32, 1])
        let outputs = try embSess.run(withInputs: ["input_1": input],
                                      outputNames: ["conv2d_19"],
                                      runOptions: nil)
        guard let out = outputs["conv2d_19"] else {
            throw WakeWordError.ortInitFailed
        }
        // Output shape [1, 1, 1, 96] — extract the 96 floats.
        let data = try out.tensorData()
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: 96)
        defer { buffer.deallocate() }
        data.getBytes(buffer.baseAddress!, length: 96 * MemoryLayout<Float>.stride)
        return Array(buffer)
    }

    /// Runs the classifier ONNX model on 16 96-dim embeddings and returns
    /// the wake-word probability.
    private func runClassifier(embeddings: [[Float]]) throws -> Float {
        guard let clsSess = classifierSession, embeddings.count == 16 else {
            throw WakeWordError.ortInitFailed
        }
        let flat: [Float] = embeddings.flatMap { e -> [Float] in
            precondition(e.count == 96, "embedding must have 96 dims")
            return e
        }
        let inputData = NSMutableData(bytes: flat,
                                      length: flat.count * MemoryLayout<Float>.stride)
        let input = try ORTValue(tensorData: inputData,
                                 elementType: .float,
                                 shape: [1, 16, 96])
        let outputs = try clsSess.run(withInputs: ["x.1": input],
                                      outputNames: ["53"],
                                      runOptions: nil)
        guard let out = outputs["53"] else {
            throw WakeWordError.ortInitFailed
        }
        let data = try out.tensorData()
        var prob: Float = 0
        guard data.length >= MemoryLayout<Float>.stride else {
            throw WakeWordError.ortInitFailed
        }
        data.getBytes(&prob, length: MemoryLayout<Float>.stride)
        return prob
    }

    // MARK: - Streaming state (per-actor)

    /// Mel frames accumulated across `feed()` calls — each frame is 32 mel
    /// bands. Sliding 76-frame windows over this buffer feed the embedding
    /// stage. Trimmed periodically once `nextEmbStart` advances; in practice
    /// memory growth is bounded by the runtime use of `feed()` (which is
    /// frame-by-frame at a steady rate).
    private var melFrameBuffer: [[Float]] = []

    /// Last known position into `melFrameBuffer` from which the embedding
    /// stage will read its next 76-frame window. Advances by `embStride`
    /// (8) per embedding inference.
    private var nextEmbStart: Int = 0

    /// 96-dim embeddings accumulated across `feed()` calls. The classifier
    /// reads the most recent 16.
    private var embeddingBuffer: [[Float]] = []

    // MARK: - Test seams (internal — for Issue #32 unbounded-growth tests)

    /// Test seam: simulate the streaming-buffer append + trim path without
    /// requiring real ORT models. Mirrors the post-`runMel` /
    /// post-`runEmbedding` writes in `runORT`, then applies the same
    /// rolling-window trim. The classifier read is skipped — the caller
    /// is testing buffer bounds, not detection.
    ///
    /// Use only from tests; production must go through `feed(samples:)`.
    internal func _testInjectFrame(
        mels: [[Float]],
        embeddingsToAppend: [[Float]] = []
    ) {
        melFrameBuffer.append(contentsOf: mels)
        for emb in embeddingsToAppend {
            embeddingBuffer.append(emb)
        }
        // Mirror `runORT`'s `nextEmbStart` advance + trim, so a stream of
        // injected frames behaves like the production loop without ORT.
        let embStride = 8
        while melFrameBuffer.count >= 76 + nextEmbStart {
            nextEmbStart += embStride
        }
        let melKeep = 76 + embStride
        if melFrameBuffer.count > melKeep {
            let drop = melFrameBuffer.count - melKeep
            melFrameBuffer.removeFirst(drop)
            nextEmbStart = max(0, nextEmbStart - drop)
        }
        if embeddingBuffer.count > 16 {
            embeddingBuffer.removeFirst(embeddingBuffer.count - 16)
        }
    }

    /// Test seam: read current streaming-buffer sizes for bound assertions.
    internal var _testBufferSizes: (melFrames: Int, embeddings: Int, nextEmbStart: Int) {
        (melFrameBuffer.count, embeddingBuffer.count, nextEmbStart)
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
