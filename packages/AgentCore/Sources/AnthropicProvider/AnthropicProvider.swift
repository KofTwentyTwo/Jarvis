import Foundation
import AgentCore
import os.log

/// Anthropic Messages API provider — hand-rolled URLSession + SSE.
///
/// Why hand-rolled (not AnthropicSDK): per RESEARCH-DELTAS D1, the SDK enum
/// lag is structural (`claude-opus-4-7` is the real model ID; SDK enums
/// won't catch up in time). URLSession accepts string model IDs directly.
/// Hand-rolling also lets us own the SSE state machine for AGENT-03 edge
/// cases (`partial_tool_use_at_disconnect`, `thinking_delta`, refusal-as-
/// first-class).
///
/// **Headers wired on every request (AGENT-02):**
/// - `anthropic-version: 2023-06-01`
/// - `anthropic-beta: extended-cache-ttl-2025-04-11`
/// - `x-api-key: <result of apiKeyProvider()>`
/// - `Content-Type: application/json`
/// - `Accept: text/event-stream`
///
/// API key is fetched **per request** via the injected closure (S-5
/// fetch-per-request pattern from Phase 1) — never cached on the actor.
public actor AnthropicProvider: LLMProvider {
    public typealias APIKeyProvider = @Sendable () async throws -> String

    private let apiKeyProvider: APIKeyProvider
    private let session: URLSession
    private let baseURL: URL

    /// Header constants — public so tests can verify exact wiring without
    /// reaching for `@testable import`.
    public static let anthropicVersion = "2023-06-01"
    public static let anthropicBeta = "extended-cache-ttl-2025-04-11"

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        apiKeyProvider: @escaping APIKeyProvider
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    public nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            let task = Task {
                await self.run(
                    messages: messages,
                    images: [],
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens,
                    cacheHints: cacheHints,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Plan 07-05 / D-18 — Anthropic Vision API multimodal stream override.
    public nonisolated func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            let task = Task {
                await self.run(
                    messages: messages,
                    images: images,
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens,
                    cacheHints: cacheHints,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Build a fully-configured URLRequest. Exposed for `@testable` use so
    /// header presence can be asserted without spinning up a transport.
    func buildURLRequest(
        body: Data,
        apiKey: String
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // AGENT-02: extended-cache-ttl-2025-04-11 unconditional on every request.
        request.setValue(Self.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return request
    }

    private func run(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async {
        let log = os.Logger(
            subsystem: "com.koftwentytwo.jarvis.AgentCore",
            category: "AnthropicProvider"
        )
        do {
            let body: Data
            do {
                body = try RequestBody.encodeMultimodal(
                    messages: messages,
                    images: images,
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens,
                    cacheHints: cacheHints
                )
            } catch {
                continuation.finish(throwing: LLMProviderError.decode(
                    reason: "request body encode failed: \(error)"
                ))
                return
            }

            let apiKey: String
            do {
                apiKey = try await apiKeyProvider()
            } catch {
                continuation.finish(throwing: LLMProviderError.transport(
                    description: "apiKeyProvider failed: \(error)"
                ))
                return
            }

            let request = buildURLRequest(body: body, apiKey: apiKey)

            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                continuation.finish(throwing: LLMProviderError.transport(
                    description: error.localizedDescription
                ))
                return
            }

            // Check HTTP status. Non-2xx → drain body, emit providerError, finish.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var bodyBuffer = Data()
                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        bodyBuffer.append(byte)
                        if bodyBuffer.count > 64 * 1024 { break } // cap
                    }
                } catch {
                    // Ignore — we already have the status code.
                }
                let bodyString = String(data: bodyBuffer, encoding: .utf8) ?? ""
                continuation.yield(.providerError(.api(
                    statusCode: http.statusCode,
                    body: bodyString
                )))
                continuation.finish()
                return
            }

            // Wire SSELineReader → SSEDecoder.
            let reader = SSELineReader(bytes: bytes)
            var state = SSEDecoder.State()
            do {
                for try await frame in reader.frames() {
                    if Task.isCancelled { break }
                    SSEDecoder.dispatch(frame: frame, state: &state) { event in
                        continuation.yield(event)
                    }
                    if state.messageStopEmitted { break }
                }
                // EOF — flush partial state if message_stop wasn't seen.
                if !state.messageStopEmitted {
                    SSEDecoder.flushOnEOF(state: &state) { event in
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            } catch {
                log.error("SSE read error: \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: LLMProviderError.transport(
                    description: error.localizedDescription
                ))
            }
        }
    }
}
