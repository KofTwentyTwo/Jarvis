import Foundation
import AgentCore
import os.log

/// Hand-rolled Anthropic SSE state machine. Covers every AGENT-03 edge case:
/// - `message_stop` (NOT `message_delta`) is the canonical close.
/// - `ping` events are swallowed (zero LLMEvents emitted).
/// - `thinking_delta` routes to its own LLMEvent case.
/// - `stop_reason: "refusal"` maps to `.refusal` (first-class, not a warning).
/// - `input_json_delta` chunks are concatenated; one `.toolUseRequested` is
///   emitted on `content_block_stop` with the assembled JSON.
/// - Empty `partial_json` chunks are skipped (never appended).
/// - Mid-stream EOF mid-tool-args emits `.partialToolUseAtDisconnect`,
///   `.stopReason(.streamTruncated)`, `.messageStop` in that order.
struct SSEDecoder: Sendable {
    /// Mutable state held across frames within one stream.
    struct State {
        var currentToolUseId: String? = nil
        var currentToolUseName: String? = nil
        var currentToolUseBuffer: Data = Data()
        var capturedStopReason: StopReason? = nil
        var capturedUsage: TurnUsage? = nil
        var messageId: String? = nil
        var model: String? = nil
        var messageStopEmitted: Bool = false
    }

    private static let log = os.Logger(
        subsystem: "com.koftwentytwo.jarvis.AgentCore",
        category: "AnthropicSSE"
    )

    /// Dispatch one SSE frame. Returns `true` if `message_stop` was emitted
    /// (signaling the caller can stop reading the stream).
    static func dispatch(
        frame: SSEFrame,
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        switch frame.event {
        case "message_start":
            handleMessageStart(data: frame.data, state: &state, emit: emit)
        case "content_block_start":
            handleContentBlockStart(data: frame.data, state: &state, emit: emit)
        case "content_block_delta":
            handleContentBlockDelta(data: frame.data, state: &state, emit: emit)
        case "content_block_stop":
            handleContentBlockStop(state: &state, emit: emit)
        case "message_delta":
            // Captures stop_reason + output_tokens. Does NOT close.
            handleMessageDelta(data: frame.data, state: &state)
        case "message_stop":
            handleMessageStop(state: &state, emit: emit)
        case "ping":
            // Swallow — zero LLMEvents emitted.
            return
        case "error":
            handleErrorEvent(data: frame.data, emit: emit)
        default:
            // Unknown event name — log warning, continue. Don't throw.
            Self.log.warning("SSEDecoder: unknown event '\(frame.event, privacy: .public)'")
        }
    }

    /// Called when the underlying byte stream ends without seeing
    /// `message_stop`. If we were buffering a tool-use, emit
    /// `.partialToolUseAtDisconnect` first; then emit a synthesized
    /// `.stopReason(.streamTruncated)` + `.messageStop`.
    static func flushOnEOF(state: inout State, emit: (LLMEvent) -> Void) {
        guard !state.messageStopEmitted else { return }

        if let id = state.currentToolUseId {
            let req = ToolUseRequest(
                id: id,
                name: state.currentToolUseName ?? "",
                argsJSON: state.currentToolUseBuffer
            )
            emit(.partialToolUseAtDisconnect(req))
            state.currentToolUseId = nil
            state.currentToolUseName = nil
            state.currentToolUseBuffer = Data()
        }
        emit(.stopReason(.streamTruncated))
        emit(.usage(state.capturedUsage ?? .zero))
        emit(.messageStop)
        state.messageStopEmitted = true
    }

    // MARK: - Per-event handlers

    private static func handleMessageStart(
        data: Data,
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            log.warning("SSEDecoder: malformed message_start payload")
            return
        }
        let messageId = (message["id"] as? String) ?? ""
        let model = (message["model"] as? String) ?? ""
        state.messageId = messageId
        state.model = model

        var prefix: TurnUsage? = nil
        if let usage = message["usage"] as? [String: Any] {
            prefix = TurnUsage(
                inputTokens: (usage["input_tokens"] as? Int) ?? 0,
                outputTokens: (usage["output_tokens"] as? Int) ?? 0,
                cacheCreationInputTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                cacheReadInputTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0
            )
            state.capturedUsage = prefix
        }
        emit(.messageStart(LLMMessageStart(
            messageId: messageId,
            model: model,
            usagePrefix: prefix
        )))
    }

    private static func handleContentBlockStart(
        data: Data,
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["content_block"] as? [String: Any] else {
            log.warning("SSEDecoder: malformed content_block_start payload")
            return
        }
        let blockType = block["type"] as? String ?? ""
        switch blockType {
        case "tool_use":
            let id = (block["id"] as? String) ?? ""
            let name = (block["name"] as? String) ?? ""
            state.currentToolUseId = id
            state.currentToolUseName = name
            state.currentToolUseBuffer = Data()
            emit(.toolUseBuffering(toolUseId: id))
        case "text", "thinking":
            // No-op — deltas will follow.
            return
        default:
            log.warning("SSEDecoder: unknown content_block type '\(blockType, privacy: .public)'")
        }
    }

    private static func handleContentBlockDelta(
        data: Data,
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = json["delta"] as? [String: Any] else {
            log.warning("SSEDecoder: malformed content_block_delta payload")
            return
        }
        let deltaType = delta["type"] as? String ?? ""
        switch deltaType {
        case "text_delta":
            if let text = delta["text"] as? String {
                emit(.textDelta(text))
            }
        case "input_json_delta":
            // Skip empty partial_json chunks — never append "" to the buffer.
            if let partial = delta["partial_json"] as? String, !partial.isEmpty {
                state.currentToolUseBuffer.append(Data(partial.utf8))
            }
        case "thinking_delta":
            if let thinking = delta["thinking"] as? String {
                emit(.thinkingDelta(thinking))
            }
        default:
            log.warning("SSEDecoder: unknown delta type '\(deltaType, privacy: .public)'")
        }
    }

    private static func handleContentBlockStop(
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        // If we were buffering a tool_use block, emit the assembled request
        // exactly once and reset state.
        if let id = state.currentToolUseId {
            let req = ToolUseRequest(
                id: id,
                name: state.currentToolUseName ?? "",
                argsJSON: state.currentToolUseBuffer
            )
            emit(.toolUseRequested(req))
            state.currentToolUseId = nil
            state.currentToolUseName = nil
            state.currentToolUseBuffer = Data()
        }
    }

    private static func handleMessageDelta(data: Data, state: inout State) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let delta = json["delta"] as? [String: Any],
           let stopRaw = delta["stop_reason"] as? String {
            state.capturedStopReason = mapStopReason(stopRaw)
        }
        if let usage = json["usage"] as? [String: Any] {
            // message_delta carries final output_tokens; merge with what
            // message_start already set (input/cache tokens are in prefix).
            let outputTokens = (usage["output_tokens"] as? Int) ?? 0
            let prior = state.capturedUsage ?? .zero
            state.capturedUsage = TurnUsage(
                inputTokens: prior.inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: prior.cacheCreationInputTokens,
                cacheReadInputTokens: prior.cacheReadInputTokens
            )
        }
    }

    private static func handleMessageStop(
        state: inout State,
        emit: (LLMEvent) -> Void
    ) {
        emit(.stopReason(state.capturedStopReason ?? .endTurn))
        emit(.usage(state.capturedUsage ?? .zero))
        emit(.messageStop)
        state.messageStopEmitted = true
    }

    private static func handleErrorEvent(data: Data, emit: (LLMEvent) -> Void) {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 error body>"
        emit(.providerError(.api(statusCode: -1, body: body)))
    }

    /// Map Anthropic `stop_reason` strings. Unknown values log a warning
    /// and map to `.endTurn` rather than throwing.
    static func mapStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        default:
            log.warning("SSEDecoder: unknown stop_reason '\(raw, privacy: .public)'")
            return .endTurn
        }
    }
}
