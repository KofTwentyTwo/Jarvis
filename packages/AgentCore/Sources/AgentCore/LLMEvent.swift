import Foundation

/// Streaming event yielded by an `LLMProvider`. Exactly ten cases.
///
/// Per AGENT-03 (research §3) the SSE state machine emits:
/// - `messageStart` once at the start of a turn,
/// - `textDelta` / `thinkingDelta` per content_block_delta,
/// - `toolUseBuffering` once when a tool_use block starts (UI hint),
/// - `toolUseRequested` ONCE per tool_use block at content_block_stop,
/// - `partialToolUseAtDisconnect` if the stream EOFs mid-tool-args,
/// - `stopReason` + `usage` + `messageStop` as the canonical close trio.
///
/// `messageStop` (NOT `message_delta`) is the canonical terminator —
/// `message_delta` only captures `stop_reason` and partial usage.
public enum LLMEvent: Sendable {
    case messageStart(LLMMessageStart)
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseRequested(ToolUseRequest)
    case toolUseBuffering(toolUseId: String)
    case partialToolUseAtDisconnect(ToolUseRequest)
    case stopReason(StopReason)
    case usage(TurnUsage)
    case providerError(LLMProviderError)
    case messageStop
}

/// Mapped from Anthropic's `stop_reason` field. Five cases.
///
/// - `refusal` is **first-class** (not a warning) per CLAUDE.md Opus 4.7
///   footguns — orchestrator surfaces it to the HUD.
/// - `streamTruncated` is emitted on mid-stream EOF before `message_stop`.
public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case streamTruncated
}

/// One assembled tool-use request, ready for the orchestrator to dispatch.
///
/// `argsJSON` is the concatenated `input_json_delta` buffer, byte-for-byte.
/// Decode via `JSONSerialization` or a typed `Decodable` shape per tool.
public struct ToolUseRequest: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argsJSON: Data

    public init(id: String, name: String, argsJSON: Data) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
    }
}

/// Per-turn token accounting. All counters mirror Anthropic's `usage` object.
///
/// `cacheCreationInputTokens` and `cacheReadInputTokens` are the prompt-cache
/// telemetry knobs surfaced via DevOverlay (Plan 04-05).
public struct TurnUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public static let zero = TurnUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationInputTokens: 0,
        cacheReadInputTokens: 0
    )
}

/// Surfaced in the first event of every turn. `usagePrefix` is Anthropic's
/// initial usage block (input tokens + cache hits known at request time).
public struct LLMMessageStart: Sendable, Equatable {
    public let messageId: String
    public let model: String
    public let usagePrefix: TurnUsage?

    public init(messageId: String, model: String, usagePrefix: TurnUsage?) {
        self.messageId = messageId
        self.model = model
        self.usagePrefix = usagePrefix
    }
}
