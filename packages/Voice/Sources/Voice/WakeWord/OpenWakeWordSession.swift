import Foundation
import OnnxRuntimeBindings  // product: onnxruntime from microsoft/onnxruntime-swift-package-manager

/// STUB — RED phase. Tests reference this type but it always returns .none.
/// Full implementation follows in the GREEN commit.
public actor OpenWakeWordSession {

    public init(modelDir: URL, threshold: Float = 0.5, framesRequired: Int = 4) throws {
        try ModelManifest.verify(modelDir: modelDir)
        self.threshold = threshold
        self.framesRequired = framesRequired
        self.consecutive = 0
        self.scriptedClassifier = nil
        // ORT sessions not initialised in stub
        self.melSession = nil
        self.embeddingSession = nil
        self.classifierSession = nil
    }

    internal init(
        scriptedClassifier: @escaping @Sendable ([Float]) -> Float,
        threshold: Float = 0.5,
        framesRequired: Int = 4
    ) {
        self.threshold = threshold
        self.framesRequired = framesRequired
        self.consecutive = 0
        self.scriptedClassifier = scriptedClassifier
        self.melSession = nil
        self.embeddingSession = nil
        self.classifierSession = nil
    }

    /// STUB: always returns .none — hysteresis not implemented.
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> DetectionDecision {
        return .none
    }

    internal func feedTest() throws -> DetectionDecision {
        return .none
    }

    private let threshold: Float
    private let framesRequired: Int
    private var consecutive: Int
    private let melSession: ORTSession?
    private let embeddingSession: ORTSession?
    private let classifierSession: ORTSession?
    private let scriptedClassifier: (@Sendable ([Float]) -> Float)?
}

public enum DetectionDecision: Sendable, Equatable {
    case none
    case fired
}

public enum WakeWordEvent: Sendable, Equatable {
    case fired(at: Date)
}
