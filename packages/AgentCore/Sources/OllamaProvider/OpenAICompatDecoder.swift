import Foundation
import AgentCore

/// SSE state machine for Ollama's OpenAI-compatible endpoint
/// (`/v1/chat/completions`).
///
/// Distinct from the Anthropic SSE decoder because:
/// - Frame shape is `data: {...}\n\n` with no `event:` field.
/// - Tool calls arrive **atomically** (`choices[0].delta.tool_calls` is a
///   complete object), unlike Anthropic which splits args across deltas.
/// - The terminator is the literal `data: [DONE]` sentinel, not a typed event.
/// - `arguments` may be a JSON-encoded **string** (OpenAI convention) rather
///   than an object (Ollama native). Decoder accepts both.
struct OpenAICompatDecoder {
    private(set) var emittedMessageStart = false
    private(set) var messageStopEmitted = false
    private(set) var capturedStopReason: StopReason?
    /// Buffer per call_id for any future split arguments — OpenAI rarely
    /// splits but the spec allows it.
    private(set) var toolCallArgBuffers: [String: Data] = [:]
    private(set) var toolCallNames: [String: String] = [:]
    /// Insertion order of call_ids so we emit toolUseRequested deterministically.
    private(set) var toolCallOrder: [String] = []

    /// Dispatch one SSE line (raw, including the `data: ` prefix when present).
    mutating func dispatch(
        line: String,
        into yield: (LLMEvent) -> Void
    ) {
        if line.isEmpty { return }
        // Comments / heartbeats start with ":". Ignore.
        if line.hasPrefix(":") { return }
        // Per SSE spec other field types could appear; we only handle `data:`.
        guard line.hasPrefix("data:") else { return }

        // Strip "data:" and any single leading space.
        var payload = String(line.dropFirst(5))
        if payload.first == " " { payload.removeFirst() }

        if payload == "[DONE]" {
            // Flush any buffered tool calls before stop.
            flushPendingToolCalls(into: yield)
            if !emittedMessageStart {
                yield(.messageStart(LLMMessageStart(
                    messageId: UUID().uuidString, model: "", usagePrefix: nil
                )))
                emittedMessageStart = true
            }
            let reason = capturedStopReason ?? .endTurn
            yield(.stopReason(reason))
            yield(.usage(.zero))
            yield(.messageStop)
            messageStopEmitted = true
            return
        }

        // Parse JSON payload.
        guard let raw = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let obj = raw as? [String: Any] else {
            yield(.providerError(.decode(reason: "OpenAI-compat SSE payload not JSON: \(payload)")))
            return
        }

        // Synthesize messageStart on first JSON frame.
        if !emittedMessageStart {
            let modelStr = (obj["model"] as? String) ?? ""
            yield(.messageStart(LLMMessageStart(
                messageId: UUID().uuidString,
                model: modelStr,
                usagePrefix: nil
            )))
            emittedMessageStart = true
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        // delta.content
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                yield(.textDelta(content))
            }
            // delta.tool_calls
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let id = (call["id"] as? String) ?? UUID().uuidString
                    if toolCallOrder.contains(id) == false {
                        toolCallOrder.append(id)
                    }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String {
                            toolCallNames[id] = name
                        }
                        if let args = function["arguments"] {
                            // OpenAI emits arguments as a JSON-encoded string.
                            // Ollama's compat layer may emit either string or object.
                            let chunk: Data
                            if let str = args as? String {
                                chunk = Data(str.utf8)
                            } else {
                                chunk = (try? JSONSerialization.data(
                                    withJSONObject: args,
                                    options: [.sortedKeys]
                                )) ?? Data()
                            }
                            toolCallArgBuffers[id, default: Data()].append(chunk)
                        }
                    }
                }
            }
        }

        // finish_reason
        if let reason = first["finish_reason"] as? String {
            switch reason {
            case "stop": capturedStopReason = .endTurn
            case "length": capturedStopReason = .maxTokens
            case "tool_calls": capturedStopReason = .toolUse
            default: capturedStopReason = .endTurn
            }
            // Flush accumulated tool calls now that finish_reason is known.
            flushPendingToolCalls(into: yield)
        }
    }

    /// Called when the byte stream ends without a `[DONE]` sentinel.
    mutating func flushOnEOF(into yield: (LLMEvent) -> Void) {
        if messageStopEmitted { return }
        flushPendingToolCalls(into: yield)
        if !emittedMessageStart {
            yield(.messageStart(LLMMessageStart(
                messageId: UUID().uuidString, model: "", usagePrefix: nil
            )))
            emittedMessageStart = true
        }
        yield(.stopReason(.streamTruncated))
        yield(.usage(.zero))
        yield(.messageStop)
        messageStopEmitted = true
    }

    /// Emit toolUseBuffering + toolUseRequested for any buffered calls and
    /// clear the buffers (so we don't re-emit on `[DONE]`).
    private mutating func flushPendingToolCalls(into yield: (LLMEvent) -> Void) {
        guard !toolCallOrder.isEmpty else { return }
        for id in toolCallOrder {
            guard let name = toolCallNames[id] else { continue }
            let args = toolCallArgBuffers[id] ?? Data("{}".utf8)
            yield(.toolUseBuffering(toolUseId: id))
            yield(.toolUseRequested(ToolUseRequest(
                id: id, name: name, argsJSON: args
            )))
        }
        toolCallOrder.removeAll()
        toolCallNames.removeAll()
        toolCallArgBuffers.removeAll()
    }
}
