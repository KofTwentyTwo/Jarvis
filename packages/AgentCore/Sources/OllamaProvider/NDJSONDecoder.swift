import Foundation
import AgentCore

/// Line-delimited-JSON state machine for Ollama `/api/chat`.
///
/// **AGENT-04 critical invariant (CLAUDE.md transport gotcha):**
/// `tool_calls` arrives on the chunk PRECEDING the terminator chunk, not
/// with it. The decoder MUST emit `.toolUseRequested` whenever `tool_calls`
/// is present on any chunk — and MUST NEVER gate the emission on the
/// terminator flag. A naive `if terminator { emit tool calls }` loses
/// every tool call silently.
///
/// Each NDJSON line is atomic JSON. Mid-stream EOF therefore cannot leave
/// a tool-use buffer half-built (unlike Anthropic's split `input_json_delta`),
/// so this decoder has no `partialToolUseAtDisconnect` semantic.
struct NDJSONDecoder {
    /// Set to `true` after `messageStart` has been yielded once.
    private(set) var emittedMessageStart = false
    /// Set to `true` once any chunk has carried a non-empty `tool_calls`
    /// array — used to drive the implicit terminator mapping when
    /// `done_reason` is missing or `"stop"` but tool calls were observed.
    private(set) var sawToolCalls = false
    /// Set to `true` once any non-empty text delta has been yielded.
    /// Combined with `sawAnyToolUseRequested`, drives `emptyResponse`
    /// detection on the terminator chunk (Task 5 / spec §2).
    private(set) var sawAnyTextDelta = false
    /// Set to `true` once at least one `toolUseRequested` event has been
    /// yielded. Mirrors `sawAnyTextDelta` for the empty-response check.
    private(set) var sawAnyToolUseRequested = false
    /// Final `prompt_eval_count` observed (Ollama only emits it on the
    /// terminator chunk in practice; keeping it as an accumulator is safe).
    private(set) var promptEvalCount: Int = 0
    /// Final `eval_count` observed (output tokens — Ollama emits on terminator).
    private(set) var evalCount: Int = 0
    /// Set to `true` once the terminator-trio (stopReason + usage + messageStop)
    /// has been emitted. The provider checks this to decide whether to call
    /// `flushOnEOF`.
    private(set) var messageStopEmitted = false

    /// Dispatch one NDJSON line into the event continuation.
    mutating func dispatch(
        line: Data,
        into yield: (LLMEvent) -> Void
    ) {
        // Empty line — ignore (Ollama never emits these but be defensive).
        if line.isEmpty { return }

        // Parse JSON. If malformed, surface a providerError and terminate.
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: line)
        } catch {
            yield(.providerError(.decode(
                reason: "NDJSON line failed to parse: \(error.localizedDescription)"
            )))
            yield(.messageStop)
            messageStopEmitted = true
            return
        }
        guard let obj = raw as? [String: Any] else {
            yield(.providerError(.decode(reason: "NDJSON line was not a JSON object")))
            yield(.messageStop)
            messageStopEmitted = true
            return
        }

        // Synthesize messageStart on first line so downstream sees the same
        // shape as Anthropic. Ollama has no native message_start event.
        if !emittedMessageStart {
            let modelStr = (obj["model"] as? String) ?? ""
            yield(.messageStart(LLMMessageStart(
                messageId: UUID().uuidString,
                model: modelStr,
                usagePrefix: nil
            )))
            emittedMessageStart = true
        }

        // 1) tool_calls present? Emit on sight — never gate on the terminator.
        //    This is the AGENT-04 invariant. Each call gets a fresh UUID
        //    (Ollama does not emit ids on /api/chat; orchestrator maps back
        //    by position when emitting tool_result).
        if let message = obj["message"] as? [String: Any],
           let calls = message["tool_calls"] as? [[String: Any]],
           !calls.isEmpty {
            for call in calls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let argsJSON: Data
                if let args = function["arguments"] {
                    // Ollama native emits arguments as a JSON object.
                    if let str = args as? String {
                        // String form: validate it parses as JSON before
                        // forwarding — orchestrator escalates on this kind
                        // (Task 5 / spec §2).
                        let strData = Data(str.utf8)
                        do {
                            _ = try JSONSerialization.jsonObject(
                                with: strData,
                                options: [.allowFragments]
                            )
                            argsJSON = strData
                        } catch {
                            yield(.providerError(.malformedToolCall(
                                reason: "tool_calls[].function.arguments string failed to parse as JSON: \(error.localizedDescription)"
                            )))
                            yield(.messageStop)
                            messageStopEmitted = true
                            return
                        }
                    } else {
                        do {
                            argsJSON = try JSONSerialization.data(
                                withJSONObject: args,
                                options: [.sortedKeys]
                            )
                        } catch {
                            yield(.providerError(.malformedToolCall(
                                reason: "tool_calls[].function.arguments object failed to re-encode: \(error.localizedDescription)"
                            )))
                            yield(.messageStop)
                            messageStopEmitted = true
                            return
                        }
                    }
                } else {
                    argsJSON = Data("{}".utf8)
                }
                let id = UUID().uuidString
                yield(.toolUseBuffering(toolUseId: id))
                yield(.toolUseRequested(ToolUseRequest(
                    id: id,
                    name: name,
                    argsJSON: argsJSON
                )))
                sawAnyToolUseRequested = true
            }
            sawToolCalls = true
        }

        // 2) text content delta?
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            yield(.textDelta(content))
            sawAnyTextDelta = true
        }

        // 3) usage accumulators (Ollama only fills these on the terminator
        //    chunk, but accumulate defensively).
        if let p = obj["prompt_eval_count"] as? Int { promptEvalCount = p }
        if let e = obj["eval_count"] as? Int { evalCount = e }

        // 4) terminator?
        if let term = obj["done"] as? Bool, term {
            let reason: StopReason
            switch obj["done_reason"] as? String {
            case "stop":
                reason = sawToolCalls ? .toolUse : .endTurn
            case "length":
                reason = .maxTokens
            case "tool_calls":
                reason = .toolUse
            case .some, nil:
                reason = sawToolCalls ? .toolUse : .endTurn
            }
            yield(.stopReason(reason))
            yield(.usage(TurnUsage(
                inputTokens: promptEvalCount,
                outputTokens: evalCount,
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: 0
            )))
            // Empty-response detection (Task 5 / spec §2): if the terminator
            // arrives with zero textDelta AND zero toolUseRequested, surface
            // `.emptyResponse` so the orchestrator can escalate to Anthropic.
            // The providerError MUST precede messageStop so consumers that
            // break on messageStop still observe it.
            if !sawAnyTextDelta && !sawAnyToolUseRequested {
                yield(.providerError(.emptyResponse))
            }
            yield(.messageStop)
            messageStopEmitted = true
        }
    }

    /// Called when the AsyncSequence of bytes ends WITHOUT seeing a
    /// terminator chunk. Emits the truncated-stream trio.
    mutating func flushOnEOF(into yield: (LLMEvent) -> Void) {
        if messageStopEmitted { return }
        // If we haven't even seen a message_start, synthesize one — the
        // orchestrator's invariant is that every turn has the trio.
        if !emittedMessageStart {
            yield(.messageStart(LLMMessageStart(
                messageId: UUID().uuidString,
                model: "",
                usagePrefix: nil
            )))
            emittedMessageStart = true
        }
        yield(.stopReason(.streamTruncated))
        yield(.usage(TurnUsage(
            inputTokens: promptEvalCount,
            outputTokens: evalCount,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0
        )))
        yield(.messageStop)
        messageStopEmitted = true
    }
}
