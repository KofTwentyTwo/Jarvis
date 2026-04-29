import Foundation
import JarvisLogging
import Logging

/// Local-only embedding client (MEM-03) — POSTs to Ollama's `/api/embed`
/// endpoint (the current one; the older `/api/embed` + "dings" variant is
/// deprecated per RESEARCH §4) for the `nomic-embed-text` model.
///
/// Loopback enforcement (MEM-04 / CONTEXT.md "no non-localhost egress"):
/// the constructor REJECTS any baseURL whose host is not 127.0.0.1,
/// localhost, or ::1. The wiring layer (AppDelegate.installMemory in Plan
/// 07-06) constructs the client with the loopback default; explicit
/// non-loopback hosts are rejected at init time, so the network sandbox
/// invariant is enforced before a single byte hits the wire.
///
/// Dimension validation (MEM-02): every response is validated against
/// `MemoryConstants.embeddingDim`. A model swap to a different dimension
/// (e.g. `mxbai-embed-large` 1024-dim) silently corrupts vector queries
/// per RESEARCH P2 — better to throw early.
public actor OllamaEmbeddingClient {

    public static let allowedLoopbackHosts: Set<String> = [
        "127.0.0.1", "localhost", "::1",
    ]

    public static let defaultBaseURL: URL = URL(string: "http://127.0.0.1:11434")!

    private let baseURL: URL
    private let session: URLSession
    private let model: String
    private let logger: Logger

    public init(
        baseURL: URL = OllamaEmbeddingClient.defaultBaseURL,
        session: URLSession = .shared,
        model: String = "nomic-embed-text"
    ) throws {
        try Self.assertLoopback(baseURL)
        self.baseURL = baseURL
        self.session = session
        self.model = model
        self.logger = Logger(label: "memory.embed")
    }

    /// Compute the embedding for a single input string. Returns a `[Float]`
    /// of length `MemoryConstants.embeddingDim` (768 for `nomic-embed-text`)
    /// or throws on transport / HTTP / shape / dimension errors.
    public func embed(_ input: String) async throws -> [Float] {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedBody(model: model, input: input))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MemoryError.embeddingTransportFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MemoryError.embeddingHTTP(statusCode: http.statusCode)
        }

        let decoded: EmbedResponse
        do {
            decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        } catch {
            throw MemoryError.embeddingShapeError("decode failed: \(error.localizedDescription)")
        }
        guard let first = decoded.embeddings.first else {
            throw MemoryError.embeddingShapeError("empty embeddings array")
        }
        guard first.count == MemoryConstants.embeddingDim else {
            throw MemoryError.dimensionMismatch(
                expected: MemoryConstants.embeddingDim,
                actual: first.count
            )
        }
        return first
    }

    // MARK: - Loopback guard

    /// Network sandbox invariant: throw if the baseURL host is anything
    /// other than 127.0.0.1, localhost, or ::1. CONTEXT.md "no non-localhost
    /// egress".
    public static func assertLoopback(_ url: URL) throws {
        // Strip square brackets from IPv6 literal like [::1].
        var host = url.host ?? ""
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let normalized = host.lowercased()
        guard allowedLoopbackHosts.contains(normalized) else {
            throw MemoryError.embeddingNonLoopbackHost(host)
        }
    }
}

private struct EmbedBody: Encodable {
    let model: String
    let input: String
}

private struct EmbedResponse: Decodable {
    let embeddings: [[Float]]
}
