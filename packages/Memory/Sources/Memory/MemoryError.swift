import Foundation

/// Errors thrown by the Memory subsystem.
public enum MemoryError: Error, Sendable {
    /// sqlite3_load_extension returned non-OK or vec0.dylib is missing from Bundle.module.
    case vecLoadFailed(String)
    /// SELECT vec_version() returned no rows or a non-string value at open time.
    case vecVersionMissing
    /// Embedding response length did not match MemoryConstants.embeddingDim (MEM-02 runtime check).
    case dimensionMismatch(expected: Int, actual: Int)
    /// Embedding response shape was malformed (embeddings array empty / wrong type).
    case embeddingShapeError(String)
    /// HTTP error from Ollama /api/embed.
    case embeddingHTTP(statusCode: Int)
    /// Transport error (URLError, network down) on /api/embed.
    case embeddingTransportFailed(String)
    /// Best-effort applyOp / supersede transaction failed; caller logs but does not propagate.
    case applyOpFailed(underlying: any Error)
    /// Session has been finished/cancelled.
    case cancelled
}
