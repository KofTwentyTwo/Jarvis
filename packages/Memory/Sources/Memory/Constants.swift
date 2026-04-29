import Foundation

/// Single-source-of-truth constants for the Memory subsystem.
///
/// MEM-02 invariant: embeddingDim is the canonical embedding length used by
/// the schema (facts_vec virtual table column type), the EmbeddingClient
/// (response-length runtime assertion), and the Extractor (prompt
/// construction). Every consumer MUST reference MemoryConstants.embeddingDim
/// rather than re-declare a local copy. A dimension drift between the
/// schema and the embedding client returns silent garbage rows from vector
/// queries — see RESEARCH section 3 Pitfall P2.
///
/// The companion test EmbeddingDimSymbolTests.testEmbeddingDimIsSingleSymbol
/// asserts there is no literal embedding-dimension constant defined outside
/// this file. Re-declaring an integer named EMBEDDING_DIM (or any equivalent
/// shadow) anywhere else in the workspace fails that test. Refer to the
/// canonical symbol `MemoryConstants.embeddingDim` from every consumer.
public enum MemoryConstants {
    /// nomic-embed-text produces 768-dimensional float32 embeddings.
    /// Hard-pinned: a model swap requires a vec0 rebuild migration (Open Q
    /// 6, deferred to backlog).
    public static let embeddingDim: Int = 768
}
