import Foundation
import AgentCore

/// Hand-rolled JSON encoder for Ollama request bodies.
///
/// Two shapes:
/// - `encodeNative` → `/api/chat` NDJSON streaming (default).
/// - `encodeOpenAICompat` → `/v1/chat/completions` SSE streaming (feature flag).
///
/// **AGENT-07 critical invariant:** `ToolChoice.none` on the native path causes
/// the `tools` array to be **omitted entirely** from the request body — not
/// `{type:"none"}`. Cap-recovery turns rely on this; a regression means the
/// model sees its tools again and loops.
///
/// Per CLAUDE.md, only `qwen2.5-coder:32b` is wired through `ModelID` —
/// Qwen3 / Qwen3.5 / Gemma 4 tool-calling is broken upstream
/// (Ollama issues #14493, #14601, #14745, #15315).
enum OllamaRequestBody {

    /// Encode `/api/chat` (NDJSON) request body.
    static func encodeNative(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool = true
    ) throws -> Data {
        // For .tool(name:), append a best-effort system hint at the END of
        // messages — Ollama has no first-class tool_choice.force.
        var effectiveMessages = messages
        if case .tool(let name) = toolChoice {
            effectiveMessages.append(LLMMessage(
                role: .system,
                content: [.text("Please use the \(name) tool.")]
            ))
        }

        // AGENT-07: drop tools array entirely on .none.
        let encodedTools: [EncodedNativeTool]?
        switch toolChoice {
        case .none:
            encodedTools = nil
        case .auto, .any, .tool:
            encodedTools = tools.isEmpty ? nil : try tools.map(encodeNativeTool)
        }

        let body = OllamaNativeRequestBody(
            model: model.rawValue,
            messages: effectiveMessages.map(encodeNativeMessage),
            tools: encodedTools,
            stream: stream,
            options: OllamaOptions(numPredict: maxOutputTokens)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// Encode `/v1/chat/completions` (OpenAI-compat SSE) request body.
    static func encodeOpenAICompat(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool = true
    ) throws -> Data {
        // OpenAI-compat path: tool_choice is its own field; tools array stays.
        let encodedTools = tools.isEmpty ? nil : try tools.map(encodeOpenAITool)
        let body = OllamaOpenAICompatBody(
            model: model.rawValue,
            messages: messages.map(encodeOpenAIMessage),
            tools: encodedTools,
            toolChoice: encodeOpenAIToolChoice(toolChoice),
            stream: stream,
            maxTokens: maxOutputTokens
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    // MARK: - Native (/api/chat) encoders

    private static func encodeNativeTool(_ schema: ToolSchema) throws -> EncodedNativeTool {
        let raw = try JSONSerialization.jsonObject(with: schema.inputSchema)
        guard let value = JSONValue(any: raw) else {
            throw EncodeError.invalidToolSchema(schema.name)
        }
        return EncodedNativeTool(
            type: "function",
            function: EncodedNativeToolFunction(
                name: schema.name,
                description: schema.description,
                parameters: value
            )
        )
    }

    private static func encodeNativeMessage(_ msg: LLMMessage) -> EncodedNativeMessage {
        let role: String
        switch msg.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .tool: role = "tool"
        }

        // Ollama native shape:
        // - assistant with tool_use blocks → {role:assistant, content:"...", tool_calls:[...]}
        // - tool result → {role:tool, content:"<string>", tool_call_id:"<id>"}
        // - everything else → concat text blocks into content string.
        var textParts: [String] = []
        var toolCalls: [EncodedNativeToolCall] = []
        var toolCallId: String? = nil

        for block in msg.content {
            switch block {
            case .text(let t):
                textParts.append(t)
            case .toolUse(let id, let name, let argsJSON):
                let args: JSONValue = (try? JSONSerialization.jsonObject(with: argsJSON))
                    .flatMap(JSONValue.init(any:)) ?? .object([:])
                toolCalls.append(EncodedNativeToolCall(
                    id: id,
                    type: "function",
                    function: EncodedNativeToolCallFunction(name: name, arguments: args)
                ))
            case .toolResult(let id, let content):
                textParts.append(content)
                toolCallId = id
            }
        }

        return EncodedNativeMessage(
            role: role,
            content: textParts.joined(),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            toolCallId: toolCallId
        )
    }

    // MARK: - OpenAI-compat encoders

    private static func encodeOpenAITool(_ schema: ToolSchema) throws -> EncodedNativeTool {
        // Same shape as native — both use {type:function, function:{name, description, parameters}}.
        try encodeNativeTool(schema)
    }

    private static func encodeOpenAIToolChoice(_ choice: ToolChoice) -> EncodedOpenAIToolChoice {
        switch choice {
        case .auto: return .string("auto")
        case .none: return .string("none")
        case .any: return .string("required")  // OpenAI shape for "must call a tool"
        case .tool(let name): return .object(name: name)
        }
    }

    private static func encodeOpenAIMessage(_ msg: LLMMessage) -> EncodedNativeMessage {
        // OpenAI-compat uses the same shape as native; reuse.
        encodeNativeMessage(msg)
    }

    enum EncodeError: Error, Sendable, Equatable {
        case invalidToolSchema(String)
    }
}

// MARK: - Native body

private struct OllamaNativeRequestBody: Encodable {
    let model: String
    let messages: [EncodedNativeMessage]
    let tools: [EncodedNativeTool]?
    let stream: Bool
    let options: OllamaOptions

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        if let tools { try c.encode(tools, forKey: .tools) }
        try c.encode(stream, forKey: .stream)
        try c.encode(options, forKey: .options)
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, options
    }
}

private struct OllamaOptions: Encodable {
    let numPredict: Int
    enum CodingKeys: String, CodingKey { case numPredict = "num_predict" }
}

private struct EncodedNativeMessage: Encodable {
    let role: String
    let content: String
    let toolCalls: [EncodedNativeToolCall]?
    let toolCallId: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if let toolCalls { try c.encode(toolCalls, forKey: .toolCalls) }
        if let toolCallId { try c.encode(toolCallId, forKey: .toolCallId) }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

private struct EncodedNativeToolCall: Encodable {
    let id: String
    let type: String
    let function: EncodedNativeToolCallFunction
}

private struct EncodedNativeToolCallFunction: Encodable {
    let name: String
    let arguments: JSONValue
}

private struct EncodedNativeTool: Encodable {
    let type: String
    let function: EncodedNativeToolFunction
}

private struct EncodedNativeToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - OpenAI-compat body

private struct OllamaOpenAICompatBody: Encodable {
    let model: String
    let messages: [EncodedNativeMessage]
    let tools: [EncodedNativeTool]?
    let toolChoice: EncodedOpenAIToolChoice
    let stream: Bool
    let maxTokens: Int

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        if let tools { try c.encode(tools, forKey: .tools) }
        try c.encode(toolChoice, forKey: .toolChoice)
        try c.encode(stream, forKey: .stream)
        try c.encode(maxTokens, forKey: .maxTokens)
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

/// OpenAI tool_choice is either a string ("auto"/"none"/"required") or an
/// object `{"type":"function","function":{"name":"..."}}`.
enum EncodedOpenAIToolChoice: Encodable {
    case string(String)
    case object(name: String)

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try single.encode(s)
        case .object(let name):
            try single.encode(OpenAIToolChoiceObject(
                type: "function",
                function: OpenAIToolChoiceFunction(name: name)
            ))
        }
    }

    private struct OpenAIToolChoiceObject: Encodable {
        let type: String
        let function: OpenAIToolChoiceFunction
    }

    private struct OpenAIToolChoiceFunction: Encodable {
        let name: String
    }
}

// MARK: - Tagged JSON value (mirrors AnthropicProvider's, kept private here)

indirect enum JSONValue: Encodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any: Any) {
        if any is NSNull { self = .null; return }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue); return
            }
            let dv = n.doubleValue
            if dv.rounded() == dv, dv.isFinite,
               dv >= Double(Int.min), dv <= Double(Int.max) {
                self = .int(Int(dv))
            } else {
                self = .double(dv)
            }
            return
        }
        if let s = any as? String { self = .string(s); return }
        if let arr = any as? [Any] {
            let mapped = arr.compactMap(JSONValue.init(any:))
            guard mapped.count == arr.count else { return nil }
            self = .array(mapped); return
        }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                guard let mv = JSONValue(any: v) else { return nil }
                out[k] = mv
            }
            self = .object(out); return
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
