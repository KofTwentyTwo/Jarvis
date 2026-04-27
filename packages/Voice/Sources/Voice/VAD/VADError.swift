/// Errors thrown by `SileroVAD` and `ContractParityProbe`.
public enum VADError: Error, Sendable {
    /// The caller provided a chunk with the wrong sample count.
    ///
    /// RESEARCH-DELTAS A1: Silero VAD v6.2.1 preserves the 512-sample / 32 ms / 16 kHz
    /// chunk contract from v5. Any deviation is a caller error, not a model error.
    case invalidChunkSize(got: Int, expected: Int)

    /// ONNX model file failed to load.
    case modelLoadFailed(underlying: Error)

    /// Neither opset-16 nor opset-15 model is available.
    case opsetUnsupported

    /// ORT inference run failed.
    case runFailed(String)
}
