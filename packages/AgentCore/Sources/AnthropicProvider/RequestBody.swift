import Foundation
import AgentCore

/// Hand-rolled JSON encoder for Anthropic `/v1/messages` request body.
///
/// Avoids `[String: Any]` dictionaries (not `Sendable`, not type-safe).
/// Uses `Codable` wrapper structs with custom `encode(to:)` for the
/// polymorphic shapes (tool_choice, content blocks, system blocks).
///
/// Wire-format reference: research §3 — Anthropic Messages API request
/// shape with `system`/`messages`/`tools`/`tool_choice` fields.
enum RequestBody {
    /// Encode a request body for the Anthropic Messages API.
    ///
    /// Anthropic splits the system role to a top-level `system` field; we
    /// extract `messages[0]` if `role == .system`, otherwise `system` is
    /// absent.
    static func encode(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) throws -> Data {
        try encodeMultimodal(
            messages: messages,
            images: [],
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            cacheHints: cacheHints
        )
    }

    /// Plan 07-05 / D-18: encode a multimodal request body for the Anthropic
    /// Vision API. When `images` is non-empty, the trailing user message's
    /// content array is augmented with `image_block` entries (text first,
    /// images after — Anthropic accepts either order; we test the chosen one).
    ///
    /// SOLE PRODUCER of the Anthropic image_block JSON shape:
    ///   `{type:image, source:{type:base64, media_type:..., data:...}}`
    static func encodeMultimodal(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) throws -> Data {
        // Split system message off the front if present.
        var systemMessages: [LLMMessage] = []
        var conversationMessages: [LLMMessage] = []
        for msg in messages {
            if msg.role == .system {
                systemMessages.append(msg)
            } else {
                conversationMessages.append(msg)
            }
        }

        var encodedConv = conversationMessages.map(encodeConversationMessage)
        // Inject image content blocks into the LAST user message in the
        // conversation. If there is no user message, append a fresh one
        // carrying only the images (defensive — should not happen because
        // FrameAttachController always pairs a frame with user text).
        if !images.isEmpty {
            let imageBlocks = images.map(encodeImageContentBlock)
            if let lastIdx = encodedConv.lastIndex(where: { $0.role == "user" }) {
                let existing = encodedConv[lastIdx]
                encodedConv[lastIdx] = EncodedMessage(
                    role: existing.role,
                    content: existing.content + imageBlocks
                )
            } else {
                encodedConv.append(EncodedMessage(role: "user", content: imageBlocks))
            }
        }

        let body = AnthropicRequestBody(
            model: model.rawValue,
            maxTokens: maxOutputTokens,
            system: systemMessages.isEmpty
                ? nil
                : encodeSystem(systemMessages, cacheHints: cacheHints),
            messages: encodedConv,
            tools: tools.isEmpty ? nil : try tools.map(encodeTool),
            toolChoice: encodeToolChoice(toolChoice)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    // MARK: - image_block (Anthropic Vision API)
    //
    // Reference: https://docs.anthropic.com/en/docs/build-with-claude/vision
    //   {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"<b64>"}}
    static func encodeImageContentBlock(_ image: ImageBlock) -> EncodedContentBlock {
        EncodedContentBlock(
            type: "image",
            text: nil,
            id: nil,
            name: nil,
            input: nil,
            toolUseId: nil,
            content: nil,
            source: EncodedImageSource(
                type: "base64",
                mediaType: image.mediaType,
                data: image.data.base64EncodedString()
            )
        )
    }

    // MARK: - tool_choice

    static func encodeToolChoice(_ choice: ToolChoice) -> EncodedToolChoice {
        switch choice {
        case .auto: return EncodedToolChoice(type: "auto", name: nil)
        case .none: return EncodedToolChoice(type: "none", name: nil)
        case .any: return EncodedToolChoice(type: "any", name: nil)
        case .tool(let name): return EncodedToolChoice(type: "tool", name: name)
        }
    }

    // MARK: - cache_control

    static func encodeCacheControl(_ hints: CacheHints?) -> EncodedCacheControl? {
        guard let hints else { return nil }
        switch hints.systemPromptTTL {
        case .ephemeral5m:
            // 5m is the Anthropic default — no cache_control marker needed.
            // Returning nil keeps the field absent from JSON.
            return nil
        case .extended1h:
            return EncodedCacheControl(type: "ephemeral", ttl: "1h")
        }
    }

    // MARK: - system blocks

    static func encodeSystem(
        _ messages: [LLMMessage],
        cacheHints: CacheHints?
    ) -> [EncodedSystemBlock] {
        // Concatenate text content from all system messages into discrete
        // blocks. We only attach `cache_control` to the FIRST block (per
        // Anthropic's prompt-cache pattern — mark the breakpoint).
        var blocks: [EncodedSystemBlock] = []
        let cacheControl = encodeCacheControl(cacheHints)
        for (msgIndex, msg) in messages.enumerated() {
            for block in msg.content {
                guard case .text(let text) = block else { continue }
                let isFirst = blocks.isEmpty && msgIndex == 0
                blocks.append(EncodedSystemBlock(
                    type: "text",
                    text: text,
                    cacheControl: isFirst ? cacheControl : nil
                ))
            }
        }
        return blocks
    }

    // MARK: - conversation messages

    static func encodeConversationMessage(_ msg: LLMMessage) -> EncodedMessage {
        let role: String
        switch msg.role {
        case .user, .tool: role = "user"      // Anthropic represents tool_results as user messages
        case .assistant: role = "assistant"
        case .system: role = "user"           // shouldn't happen — extracted above
        }
        let blocks = msg.content.map(encodeContentBlock)
        return EncodedMessage(role: role, content: blocks)
    }

    static func encodeContentBlock(_ block: LLMMessage.ContentBlock) -> EncodedContentBlock {
        switch block {
        case .text(let text):
            return EncodedContentBlock(
                type: "text", text: text,
                id: nil, name: nil, input: nil,
                toolUseId: nil, content: nil, source: nil
            )
        case .toolUse(let id, let name, let argsJSON):
            // Decode argsJSON bytes to a JSON object and re-emit inline.
            let inputObject = (try? JSONSerialization.jsonObject(with: argsJSON))
                .flatMap { JSONValue(any: $0) } ?? JSONValue.object([:])
            return EncodedContentBlock(
                type: "tool_use", text: nil,
                id: id, name: name, input: inputObject,
                toolUseId: nil, content: nil, source: nil
            )
        case .toolResult(let toolUseId, let content):
            return EncodedContentBlock(
                type: "tool_result", text: nil,
                id: nil, name: nil, input: nil,
                toolUseId: toolUseId, content: content, source: nil
            )
        }
    }

    // MARK: - tools

    static func encodeTool(_ schema: ToolSchema) throws -> EncodedTool {
        // Decode the inputSchema bytes back to a JSON object so it embeds
        // inline (NOT as a double-encoded string).
        let raw = try JSONSerialization.jsonObject(with: schema.inputSchema)
        guard let value = JSONValue(any: raw) else {
            throw EncodeError.invalidToolSchema(schema.name)
        }
        return EncodedTool(
            name: schema.name,
            description: schema.description,
            inputSchema: value
        )
    }

    enum EncodeError: Error, Sendable, Equatable {
        case invalidToolSchema(String)
    }
}

// MARK: - Encoded value types

struct AnthropicRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: [EncodedSystemBlock]?
    let messages: [EncodedMessage]
    let tools: [EncodedTool]?
    let toolChoice: EncodedToolChoice

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
    }
}

struct EncodedToolChoice: Encodable, Equatable {
    let type: String
    let name: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let name {
            try container.encode(name, forKey: .name)
        }
    }

    enum CodingKeys: String, CodingKey { case type, name }
}

struct EncodedCacheControl: Encodable, Equatable {
    let type: String
    let ttl: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(ttl, forKey: .ttl)
    }

    enum CodingKeys: String, CodingKey { case type, ttl }
}

struct EncodedSystemBlock: Encodable {
    let type: String
    let text: String
    let cacheControl: EncodedCacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }
}

struct EncodedMessage: Encodable {
    let role: String
    let content: [EncodedContentBlock]
}

struct EncodedContentBlock: Encodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let toolUseId: String?
    let content: String?
    /// Plan 07-05 / D-18: present only when `type == "image"` (Anthropic
    /// Vision API image_block).
    let source: EncodedImageSource?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content, source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text { try container.encode(text, forKey: .text) }
        if let id { try container.encode(id, forKey: .id) }
        if let name { try container.encode(name, forKey: .name) }
        if let input { try container.encode(input, forKey: .input) }
        if let toolUseId { try container.encode(toolUseId, forKey: .toolUseId) }
        if let content { try container.encode(content, forKey: .content) }
        if let source { try container.encode(source, forKey: .source) }
    }
}

/// Plan 07-05 / D-18: Anthropic Vision API image_block source field.
/// Reference: https://docs.anthropic.com/en/docs/build-with-claude/vision
struct EncodedImageSource: Encodable, Equatable {
    let type: String       // always "base64" for now; URL-source is a future option
    let mediaType: String  // e.g. "image/jpeg"
    let data: String       // base64-encoded image bytes

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

struct EncodedTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

/// Tagged JSON value — used for embedding arbitrary JSON shapes
/// (tool input_schema, tool_use input) without going through
/// `[String: Any]`.
indirect enum JSONValue: Encodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any: Any) {
        if any is NSNull {
            self = .null
            return
        }
        // NSNumber covers Int, Double, Bool — disambiguate by underlying type.
        if let n = any as? NSNumber {
            // CFBoolean is bridged from Bool — check first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
                return
            }
            // Distinguish int vs double by whether the double fits in int.
            let dv = n.doubleValue
            if dv.rounded() == dv, dv.isFinite,
               dv >= Double(Int.min), dv <= Double(Int.max) {
                self = .int(Int(dv))
            } else {
                self = .double(dv)
            }
            return
        }
        if let s = any as? String {
            self = .string(s)
            return
        }
        if let arr = any as? [Any] {
            let mapped = arr.compactMap(JSONValue.init(any:))
            guard mapped.count == arr.count else { return nil }
            self = .array(mapped)
            return
        }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                guard let mv = JSONValue(any: v) else { return nil }
                out[k] = mv
            }
            self = .object(out)
            return
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}
