import Foundation
import AgentCore
import os.log

/// Ollama LLM provider — hand-rolled URLSession + line-stream decoder.
///
/// **Two transports:**
/// - Native `/api/chat` NDJSON (default) — the documented Ollama gotcha
///   applies: `tool_calls` arrives on the chunk PRECEDING the terminator
///   (CLAUDE.md transport gotcha; AGENT-04). `NDJSONDecoder` enforces this.
/// - OpenAI-compat `/v1/chat/completions` SSE (behind `useOpenAICompat`)
///   for parity with other OpenAI-compat clients; tool_calls arrive
///   atomically per `OpenAICompatDecoder`.
///
/// Loopback-only — `baseURL.host` validation lives in `OllamaConfig`
/// (Phase 1, AGENT-05). This actor passes the URL through verbatim.
///
/// Per CLAUDE.md / RESEARCH-DELTAS D3, the only ModelID surface for Ollama
/// is `qwen2.5-coder:32b`. Qwen3 / Qwen3.5 / Gemma 4 tool-calling is
/// upstream-broken and must not be wired in via constants.
public actor OllamaProvider: LLMProvider {
    private let baseURL: URL
    private let session: URLSession
    private let useOpenAICompat: Bool

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        useOpenAICompat: Bool = false
    ) {
        self.baseURL = baseURL
        self.session = session
        self.useOpenAICompat = useOpenAICompat
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
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async {
        let log = os.Logger(
            subsystem: "com.koftwentytwo.jarvis.AgentCore",
            category: "OllamaProvider"
        )
        do {
            let path = useOpenAICompat ? "/v1/chat/completions" : "/api/chat"
            var request = URLRequest(url: baseURL.appending(path: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: Data
            if useOpenAICompat {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                body = try OllamaRequestBody.encodeOpenAICompat(
                    messages: messages,
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens
                )
            } else {
                request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                body = try OllamaRequestBody.encodeNative(
                    messages: messages,
                    tools: tools,
                    toolChoice: toolChoice,
                    model: model,
                    maxOutputTokens: maxOutputTokens
                )
            }
            request.httpBody = body

            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                continuation.finish(throwing: LLMProviderError.transport(
                    description: error.localizedDescription
                ))
                return
            }

            // Non-2xx → drain a capped body, surface .api(...).
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                var bodyBuffer = Data()
                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        bodyBuffer.append(byte)
                        if bodyBuffer.count > 64 * 1024 { break }
                    }
                } catch {
                    // ignore — status code already known
                }
                let bodyString = String(data: bodyBuffer, encoding: .utf8) ?? ""
                continuation.yield(.providerError(.api(
                    statusCode: http.statusCode,
                    body: bodyString
                )))
                continuation.finish()
                return
            }

            do {
                if useOpenAICompat {
                    var decoder = OpenAICompatDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty { continue }
                        decoder.dispatch(line: line) { continuation.yield($0) }
                        if decoder.messageStopEmitted { break }
                    }
                    if !decoder.messageStopEmitted {
                        decoder.flushOnEOF { continuation.yield($0) }
                    }
                } else {
                    var decoder = NDJSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty { continue }
                        decoder.dispatch(line: Data(line.utf8)) { continuation.yield($0) }
                        if decoder.messageStopEmitted { break }
                    }
                    if !decoder.messageStopEmitted {
                        decoder.flushOnEOF { continuation.yield($0) }
                    }
                }
                continuation.finish()
            } catch {
                log.error("stream read error: \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: LLMProviderError.transport(
                    description: error.localizedDescription
                ))
            }
        } catch {
            continuation.finish(throwing: LLMProviderError.decode(
                reason: "request body encode failed: \(error)"
            ))
        }
    }
}
