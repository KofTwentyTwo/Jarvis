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

    // MARK: - Multimodal encoders (Plan 07-05 / D-18)
    //
    // The OpenAI vision request shape:
    //   {"role":"user","content":[
    //     {"type":"text","text":"..."},
    //     {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}
    //   ]}
    // Both `gemma4:31b` via Ollama and `Qwen3.5-35B-A3B-VL` via vllm-mlx
    // accept this shape; vllm-mlx is OpenAI-compat at the wire level.
    //
    // These encoders pivot the trailing user message from the string-content
    // form to the array-of-content-blocks form when `images` is non-empty.

    /// Native /api/chat multimodal encoder. When images is empty, falls back
    /// to the existing `encodeNative` path byte-for-byte.
    static func encodeNativeMultimodal(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool = true
    ) throws -> Data {
        if images.isEmpty {
            return try encodeNative(
                messages: messages, tools: tools, toolChoice: toolChoice,
                model: model, maxOutputTokens: maxOutputTokens, stream: stream
            )
        }
        return try encodeMultimodalCommon(
            messages: messages,
            images: images,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            stream: stream,
            isOpenAICompat: false
        )
    }

    /// OpenAI-compat /v1/chat/completions multimodal encoder. When images is
    /// empty, falls back to the existing `encodeOpenAICompat` path byte-for-byte.
    static func encodeOpenAICompatMultimodal(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool = true
    ) throws -> Data {
        if images.isEmpty {
            return try encodeOpenAICompat(
                messages: messages, tools: tools, toolChoice: toolChoice,
                model: model, maxOutputTokens: maxOutputTokens, stream: stream
            )
        }
        return try encodeMultimodalCommon(
            messages: messages,
            images: images,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            stream: stream,
            isOpenAICompat: true
        )
    }

    private static func encodeMultimodalCommon(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool,
        isOpenAICompat: Bool
    ) throws -> Data {
        // Encode the messages with the multimodal content shape — the trailing
        // user message gets array-of-content-blocks instead of a flat string.
        var encoded = messages.map(encodeMultimodalMessage)
        // Inject image blocks into the last user message.
        if let lastIdx = encoded.lastIndex(where: { $0.role == "user" }) {
            let existing = encoded[lastIdx]
            let extraBlocks = images.map(encodeOpenAIVisionImageBlock)
            encoded[lastIdx] = EncodedMultimodalMessage(
                role: existing.role,
                content: existing.content + extraBlocks,
                toolCalls: existing.toolCalls,
                toolCallId: existing.toolCallId
            )
        } else {
            // Defensive fallback — append a fresh user message.
            encoded.append(EncodedMultimodalMessage(
                role: "user",
                content: images.map(encodeOpenAIVisionImageBlock),
                toolCalls: nil,
                toolCallId: nil
            ))
        }

        if isOpenAICompat {
            let encodedTools = tools.isEmpty ? nil : try tools.map(encodeOpenAITool)
            let body = OllamaOpenAICompatMultimodalBody(
                model: model.rawValue,
                messages: encoded,
                tools: encodedTools,
                toolChoice: encodeOpenAIToolChoice(toolChoice),
                stream: stream,
                maxTokens: maxOutputTokens
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(body)
        } else {
            // Native /api/chat path: drop tools on .none (AGENT-07).
            let encodedTools: [EncodedNativeTool]?
            switch toolChoice {
            case .none: encodedTools = nil
            case .auto, .any, .tool:
                encodedTools = tools.isEmpty ? nil : try tools.map(encodeNativeTool)
            }
            // Append .tool(name) hint message if applicable, mirroring single-modal.
            if case .tool(let name) = toolChoice {
                encoded.append(EncodedMultimodalMessage(
                    role: "system",
                    content: [.text("Please use the \(name) tool.")],
                    toolCalls: nil,
                    toolCallId: nil
                ))
            }
            let body = OllamaNativeMultimodalRequestBody(
                model: model.rawValue,
                messages: encoded,
                tools: encodedTools,
                stream: stream,
                options: OllamaOptions(numPredict: maxOutputTokens)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(body)
        }
    }

    private static func encodeMultimodalMessage(_ msg: LLMMessage) -> EncodedMultimodalMessage {
        let role: String
        switch msg.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .tool: role = "tool"
        }
        var blocks: [EncodedOpenAIVisionContentBlock] = []
        var toolCalls: [EncodedNativeToolCall] = []
        var toolCallId: String? = nil
        for block in msg.content {
            switch block {
            case .text(let t):
                blocks.append(.text(t))
            case .toolUse(let id, let name, let argsJSON):
                let args: JSONValue = (try? JSONSerialization.jsonObject(with: argsJSON))
                    .flatMap(JSONValue.init(any:)) ?? .object([:])
                toolCalls.append(EncodedNativeToolCall(
                    id: id,
                    type: "function",
                    function: EncodedNativeToolCallFunction(name: name, arguments: args)
                ))
            case .toolResult(let id, let content):
                blocks.append(.text(content))
                toolCallId = id
            }
        }
        return EncodedMultimodalMessage(
            role: role,
            content: blocks,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            toolCallId: toolCallId
        )
    }

    /// SOLE producer of the OpenAI-compat data-URL image_url block.
    /// Reference: OpenAI Vision API request shape.
    private static func encodeOpenAIVisionImageBlock(_ image: ImageBlock) -> EncodedOpenAIVisionContentBlock {
        .imageURL(url: "data:\(image.mediaType);base64,\(image.data.base64EncodedString())")
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

struct OllamaOptions: Encodable {
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

struct EncodedNativeToolCall: Encodable {
    let id: String
    let type: String
    let function: EncodedNativeToolCallFunction
}

struct EncodedNativeToolCallFunction: Encodable {
    let name: String
    let arguments: JSONValue
}

struct EncodedNativeTool: Encodable {
    let type: String
    let function: EncodedNativeToolFunction
}

struct EncodedNativeToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - Multimodal body shapes (Plan 07-05 / D-18)

/// User-message content block in OpenAI-vision format. Either a text-only
/// block or a data-URL image_url block.
enum EncodedOpenAIVisionContentBlock: Encodable {
    case text(String)
    case imageURL(url: String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .imageURL(let url):
            try c.encode("image_url", forKey: .type)
            try c.encode(ImageURLEnvelope(url: url), forKey: .imageURL)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURLEnvelope: Encodable {
        let url: String
    }
}

struct EncodedMultimodalMessage: Encodable {
    let role: String
    let content: [EncodedOpenAIVisionContentBlock]
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

struct OllamaNativeMultimodalRequestBody: Encodable {
    let model: String
    let messages: [EncodedMultimodalMessage]
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

struct OllamaOpenAICompatMultimodalBody: Encodable {
    let model: String
    let messages: [EncodedMultimodalMessage]
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
