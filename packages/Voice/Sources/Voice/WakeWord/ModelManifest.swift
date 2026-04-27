import Foundation

/// Verifies the SHA-256 integrity of the three openWakeWord ONNX model files.
///
/// STUB — full implementation follows in the GREEN phase commit.
/// Tests call this type and should fail until the implementation is complete.
public enum ModelManifest {
    /// Stub: always throws ortInitFailed until implementation is complete.
    public static func verify(modelDir: URL) throws {
        throw WakeWordError.ortInitFailed
    }
}
