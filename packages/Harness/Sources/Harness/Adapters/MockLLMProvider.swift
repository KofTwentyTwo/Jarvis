import Foundation
import AgentCore
import AnthropicProvider
import OllamaProvider

/// `LLMProvider` conformer that drives the REAL Anthropic / Ollama provider
/// stack against fixture bytes by way of a `URLProtocol`-stubbed
/// `URLSession`. Fixture bytes flow through the same `SSELineReader`/
/// `SSEDecoder` (Anthropic) or NDJSON decoder (Ollama) the production
/// pipeline uses — the byte-level contract is genuinely exercised, not
/// short-circuited.
///
/// Anti-pattern guard (PATTERNS.md §2.4 / RESEARCH §Common Pitfalls #2): a
/// vacuous canned-response mock would let injection corpora pass without
/// touching the structural defenses (SEC-06 nonce wrap + SEC-07 sanitize live
/// upstream of the LLM, but the SSE byte-shape contract still has to hold for
/// the orchestrator to behave correctly).
///
/// Usage (Plan 08-01 Task 3 + downstream plans):
///
/// ```swift
/// let mock = MockLLMProvider(fixtureURL: url, kind: .anthropicSSE)
/// // Pass `mock` into `AgentOrchestrator` exactly like a live provider.
/// ```
public actor MockLLMProvider: LLMProvider {
    public enum FixtureKind: Sendable {
        case anthropicSSE
        case ollamaNDJSON
    }

    private let fixtureURL: URL
    private let kind: FixtureKind
    /// Underlying real provider — selected by `kind` at init. Concrete type
    /// is `AnthropicProvider` or `OllamaProvider`; both conform to
    /// `LLMProvider`. We hold the existential to keep the dispatch logic
    /// trivial.
    private let underlying: any LLMProvider

    public init(fixtureURL: URL, kind: FixtureKind) {
        self.fixtureURL = fixtureURL
        self.kind = kind

        // Build a URLSession that routes every request to the fixture-replay
        // URLProtocol. The protocol returns the fixture bytes verbatim with
        // the right Content-Type for each kind.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        FixtureURLProtocol.register(fixtureURL: fixtureURL, kind: kind)

        switch kind {
        case .anthropicSSE:
            self.underlying = AnthropicProvider(
                baseURL: URL(string: "https://api.anthropic.com")!,
                session: session,
                apiKeyProvider: { "sk-ant-fixture-replay" }
            )
        case .ollamaNDJSON:
            self.underlying = OllamaProvider(
                baseURL: URL(string: "http://127.0.0.1:11434")!,
                session: session
            )
        }
    }

    public nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        underlying.stream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            cacheHints: cacheHints
        )
    }
}

// MARK: - URLProtocol fixture replay

/// `URLProtocol` subclass that returns fixture bytes for every request,
/// keyed by the most recently registered `(fixtureURL, kind)` pair. Single
/// global pair is sufficient for `MockLLMProvider`'s use case (one provider
/// per session, one fixture per provider).
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtureURL: URL?
    nonisolated(unsafe) private static var kind: MockLLMProvider.FixtureKind?

    static func register(fixtureURL: URL, kind: MockLLMProvider.FixtureKind) {
        lock.lock()
        defer { lock.unlock() }
        Self.fixtureURL = fixtureURL
        Self.kind = kind
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let url = Self.fixtureURL
        let kind = Self.kind
        Self.lock.unlock()

        guard let fixtureURL = url, let kind = kind else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fixtureURL)
            let contentType: String
            switch kind {
            case .anthropicSSE: contentType = "text/event-stream"
            case .ollamaNDJSON: contentType = "application/x-ndjson"
            }
            let response = HTTPURLResponse(
                url: request.url ?? fixtureURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
