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
        /// Plan 08-02 Task 2 — Ollama `/v1/chat/completions` OpenAI-compat
        /// SSE transport. Routes through the same `OllamaProvider` actor
        /// with `useOpenAICompat: true` so the `OpenAICompatDecoder` (not
        /// `NDJSONDecoder`) consumes the bytes.
        case ollamaOpenAICompat
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

        // Per-instance unique host so multiple MockLLMProviders running
        // concurrently (parallel swift-testing tests) cannot trample each
        // other's fixture registration. The protocol's registry is keyed by
        // the HTTP request's host. (Plan 08-02 Task 2 fix — the original
        // single-global state lost fixture identity under parallel test
        // execution.)
        let token = UUID().uuidString.lowercased()
        let host = "fixture-\(token).test"
        FixtureURLProtocol.register(host: host, fixtureURL: fixtureURL, kind: kind)

        switch kind {
        case .anthropicSSE:
            self.underlying = AnthropicProvider(
                baseURL: URL(string: "https://\(host)")!,
                session: session,
                apiKeyProvider: { "sk-ant-fixture-replay" }
            )
        case .ollamaNDJSON:
            self.underlying = OllamaProvider(
                baseURL: URL(string: "http://\(host)")!,
                session: session
            )
        case .ollamaOpenAICompat:
            self.underlying = OllamaProvider(
                baseURL: URL(string: "http://\(host)")!,
                session: session,
                useOpenAICompat: true
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
/// keyed by the request's host. Each `MockLLMProvider` instance picks a
/// per-process-unique host (`fixture-<uuid>.test`) so parallel
/// swift-testing tests don't trample each other's fixture registration.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry {
        let fixtureURL: URL
        let kind: MockLLMProvider.FixtureKind
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Entry] = [:]

    static func register(host: String, fixtureURL: URL, kind: MockLLMProvider.FixtureKind) {
        lock.lock()
        defer { lock.unlock() }
        registry[host] = Entry(fixtureURL: fixtureURL, kind: kind)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host
        Self.lock.lock()
        let entry = host.flatMap { Self.registry[$0] }
        Self.lock.unlock()

        guard let entry = entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let fixtureURL = entry.fixtureURL
        let kind = entry.kind

        do {
            let data = try Data(contentsOf: fixtureURL)
            let contentType: String
            switch kind {
            case .anthropicSSE: contentType = "text/event-stream"
            case .ollamaNDJSON: contentType = "application/x-ndjson"
            case .ollamaOpenAICompat: contentType = "text/event-stream"
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
