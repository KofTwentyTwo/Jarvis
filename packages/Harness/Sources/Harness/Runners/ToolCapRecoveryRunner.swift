import Foundation
import AgentCore
import AnthropicProvider
import OllamaProvider

/// ToolCapRecoveryRunner — Plan 08-03 Task 3, OBS-04 pillar (d).
///
/// R4-L1 regression guard for AGENT-07 (tool-cap recovery). Asserts the
/// **D-21 dual contract** that an event-count assertion alone is necessary
/// but not sufficient (researcher Pitfall 5):
///
/// 1. Event-count clause (necessary): the recovery turn yields zero
///    `.toolUseRequested` events.
/// 2. Outbound-body clause (sufficient): the captured outbound HTTP
///    request body confirms `tool_choice: {"type":"none"}` for Anthropic
///    or absence of the `tools` array entirely for Ollama (the AGENT-07
///    encoder-level invariant).
///
/// Together: even if a future refactor removes the `toolChoice` parameter
/// from `LLMProvider.stream(...)` (R4-L1 risk), clause 2 still catches
/// the regression because the encoded bytes carry the wire-level fact.
///
/// Implementation: drives a real `AnthropicProvider` / `OllamaProvider`
/// against `CapturingURLProtocol`, which both records the outbound body
/// AND serves a benign canned response (no tool_use events) so clause 1
/// can be observed.
public actor ToolCapRecoveryRunner {

    public enum Provider: String, Sendable, Codable {
        case anthropic
        case ollama
    }

    public struct CapRecoveryReport: Sendable, Codable {
        public let provider: Provider
        public let toolUseEventCount: Int
        public let recoveryRequestBody: Data
        /// D-21 clause 2:
        ///   Anthropic → `tool_choice` field equals `{"type":"none"}`.
        ///   Ollama   → `tools` key is absent on the recovery turn.
        public let toolChoiceSerializedAsNone: Bool
        /// Diagnostic: whether the `tools` array key is present in the
        /// outbound JSON. Anthropic keeps `tools` (gated by tool_choice);
        /// Ollama drops `tools` entirely on `.none` (AGENT-07).
        public let toolsArrayPresent: Bool

        public var passed: Bool {
            // Clause 1: zero tool-use events on the recovery turn.
            // Clause 2: the wire shape matches the provider's contract.
            let clause1 = toolUseEventCount == 0
            let clause2: Bool
            switch provider {
            case .anthropic:
                clause2 = toolChoiceSerializedAsNone
            case .ollama:
                clause2 = toolChoiceSerializedAsNone && !toolsArrayPresent
            }
            return clause1 && clause2
        }
    }

    public init() {}

    public func run(provider: Provider) async throws -> CapRecoveryReport {
        URLProtocol.registerClass(CapturingURLProtocol.self)
        defer { URLProtocol.unregisterClass(CapturingURLProtocol.self) }
        CapturingURLProtocol.reset()

        // Stage a benign canned response (no tool_use events) so clause 1
        // is observable. Both providers tolerate empty stream bytes — the
        // event-count assertion is what we actually care about.
        CapturingURLProtocol.cannedResponse =
            try Self.cannedNoToolUseResponse(for: provider)

        // Build a URLSession routed exclusively through CapturingURLProtocol.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let session = URLSession(configuration: config)

        // Drive a single .none turn through the real provider. Tools list
        // is non-empty so we can confirm the encoder DROPS them on Ollama
        // and KEEPS them but gates them via tool_choice on Anthropic.
        let tools: [ToolSchema] = [
            ToolSchema(
                name: "noop",
                description: "no-op",
                inputSchema: Data("{}".utf8)
            )
        ]
        let messages: [LLMMessage] = [
            LLMMessage(
                role: .system,
                content: [.text("system")]
            ),
            LLMMessage(
                role: .user,
                content: [.text("recover")]
            ),
        ]

        var toolUseCount = 0
        let model: ModelID
        switch provider {
        case .anthropic:
            model = .opus47
            let p = AnthropicProvider(
                baseURL: URL(string: "https://api.anthropic.com")!,
                session: session,
                apiKeyProvider: { "sk-ant-fixture-replay" }
            )
            let stream = p.stream(
                messages: messages,
                tools: tools,
                toolChoice: .none,
                model: model,
                maxOutputTokens: 32,
                cacheHints: nil
            )
            // Drain — even on error, we still want the captured body.
            do {
                for try await ev in stream {
                    if case .toolUseRequested = ev { toolUseCount += 1 }
                }
            } catch {
                // Transport / decode errors are acceptable here — the
                // outbound body is captured BEFORE any response is read,
                // so clause 2 remains assertible.
            }
        case .ollama:
            model = .qwen25coder32b
            let p = OllamaProvider(
                baseURL: URL(string: "http://127.0.0.1:11434")!,
                session: session
            )
            let stream = p.stream(
                messages: messages,
                tools: tools,
                toolChoice: .none,
                model: model,
                maxOutputTokens: 32,
                cacheHints: nil
            )
            do {
                for try await ev in stream {
                    if case .toolUseRequested = ev { toolUseCount += 1 }
                }
            } catch {
                // Same rationale as the Anthropic branch.
            }
        }

        // Inspect the captured outbound body. Use the LAST captured body
        // — both providers send a single POST per stream call, but if a
        // future refactor adds a preflight request, we want the body
        // that carried the messages payload.
        let body = CapturingURLProtocol.capturedBodies.last ?? Data()
        let (toolChoiceNone, toolsPresent) = inspectBody(body, provider: provider)

        return CapRecoveryReport(
            provider: provider,
            toolUseEventCount: toolUseCount,
            recoveryRequestBody: body,
            toolChoiceSerializedAsNone: toolChoiceNone,
            toolsArrayPresent: toolsPresent
        )
    }

    /// Parse the outbound JSON body and check provider-specific D-21 clause 2.
    private func inspectBody(
        _ body: Data,
        provider: Provider
    ) -> (toolChoiceNone: Bool, toolsPresent: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (false, false)
        }
        switch provider {
        case .anthropic:
            // Anthropic: tool_choice is a JSON object. .none → {type:"none"}.
            let tc = json["tool_choice"] as? [String: Any]
            let isNone = (tc?["type"] as? String) == "none"
            // Anthropic keeps the tools array on .none (gated by tool_choice).
            let toolsPresent = json["tools"] != nil
            return (isNone, toolsPresent)
        case .ollama:
            // Ollama (native /api/chat): AGENT-07 drops `tools` array entirely
            // on .none. The "serialized as none" predicate for Ollama is the
            // ABSENCE of the tools key.
            let toolsPresent = json["tools"] != nil
            let isNone = !toolsPresent
            return (isNone, toolsPresent)
        }
    }

    /// Provide a benign canned response that yields zero tool_use events.
    /// Anthropic: a minimal SSE message_start → message_stop sequence.
    /// Ollama: a single `done:true` NDJSON line.
    static func cannedNoToolUseResponse(for provider: Provider) throws -> Data {
        switch provider {
        case .anthropic:
            return Data("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_capr","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

            event: message_stop
            data: {"type":"message_stop"}

            """.utf8)
        case .ollama:
            return Data("""
            {"model":"qwen2.5-coder:32b","done":true,"done_reason":"stop"}
            """.utf8)
        }
    }
}
