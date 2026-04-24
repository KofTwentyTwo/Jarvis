import Foundation
@testable import AgentCore
@testable import AgentOrchestrator

/// Test-only `LLMProvider` with a scriptable event sequence.
///
/// Each call to `stream(...)` records the (messages, tools, toolChoice,
/// model) tuple it received and yields the events from the active script,
/// optionally throttled. Subsequent calls within the same turn (tool-use
/// loop iterations, cap-recovery, retry) consume the next entry of
/// `scripts` if `scripts.count > 1`; otherwise the single script is reused.
public actor MockLLMProvider: LLMProvider {
    public struct Script: Sendable {
        public var events: [LLMEvent]
        /// Sleep this many ns between consecutive yields. Used to keep a
        /// turn open long enough for `cancelAndSubmit` to fire.
        public var throttleBetweenEventsNs: UInt64

        public init(events: [LLMEvent], throttleBetweenEventsNs: UInt64 = 0) {
            self.events = events
            self.throttleBetweenEventsNs = throttleBetweenEventsNs
        }
    }

    public struct RecordedCall: Sendable, Equatable {
        public let messages: [LLMMessage]
        public let tools: [ToolSchema]
        public let toolChoice: ToolChoice
        public let model: ModelID
    }

    private var scripts: [Script]
    private var callIndex: Int = 0
    private var recordedCalls: [RecordedCall] = []

    public init(scripts: [Script]) {
        precondition(!scripts.isEmpty, "MockLLMProvider needs at least one script")
        self.scripts = scripts
    }

    public init(script: Script) {
        self.scripts = [script]
    }

    public func setScripts(_ next: [Script]) {
        self.scripts = next
        self.callIndex = 0
    }

    public func appendScript(_ s: Script) {
        scripts.append(s)
    }

    public func getRecordedCalls() -> [RecordedCall] {
        recordedCalls
    }

    public func resetRecordedCalls() {
        recordedCalls.removeAll()
        callIndex = 0
    }

    /// LLMProvider conformance — nonisolated so callers don't need to await
    /// just to obtain the stream. The underlying state mutation happens
    /// inside the AsyncThrowingStream's task body via actor methods.
    public nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                let scriptToRun = await self.recordCallAndSelectScript(
                    messages: messages, tools: tools,
                    toolChoice: toolChoice, model: model
                )
                for event in scriptToRun.events {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if scriptToRun.throttleBetweenEventsNs > 0 {
                        try? await Task.sleep(nanoseconds: scriptToRun.throttleBetweenEventsNs)
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func recordCallAndSelectScript(
        messages: [LLMMessage], tools: [ToolSchema],
        toolChoice: ToolChoice, model: ModelID
    ) -> Script {
        recordedCalls.append(RecordedCall(
            messages: messages, tools: tools,
            toolChoice: toolChoice, model: model
        ))
        let chosen: Script
        if callIndex < scripts.count {
            chosen = scripts[callIndex]
        } else {
            chosen = scripts.last!
        }
        callIndex += 1
        return chosen
    }
}
