/// Errors produced by the wake-word pipeline.
///
/// Fail-closed discipline: DO NOT auto-redownload on hash mismatch — surface the
/// error to the caller and require explicit operator action. (VOICE-01 / T-06-02-01)
public enum WakeWordError: Error, Sendable, Equatable {
    /// The SHA-256 hash of `filename` on disk does not match the pinned value in
    /// MANIFEST.json. The session refuses to construct to avoid running untrusted
    /// ONNX weights. Never auto-redownload — fail closed.
    case modelHashMismatch(filename: String, expected: String, got: String)

    /// The file `filename` is absent from the model directory. Run
    /// `scripts/fetch-openwakeword-models.sh` to download the weights.
    case missingModel(filename: String)

    /// ONNX Runtime environment or session initialisation failed unexpectedly.
    case ortInitFailed
}
