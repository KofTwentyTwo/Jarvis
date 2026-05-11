import XCTest
import Foundation
import AgentCore
@testable import Memory

/// Plan 07-02 Task 3: MemoryPrompts + MemoryTools + MemoryExtractor.
final class MemoryExtractorTests: XCTestCase {

    // MARK: - MockLLMProvider

    final class MockLLMProvider: LLMProvider, @unchecked Sendable {
        let lock = NSLock()
        private var _capturedModel: ModelID?
        private var _capturedToolChoice: ToolChoice?
        private var _capturedMessages: [LLMMessage] = []
        private var _capturedTools: [ToolSchema] = []
        var scriptedEvents: [LLMEvent] = []
        var throwOnFirst: Error?

        var capturedModel: ModelID? {
            lock.lock(); defer { lock.unlock() }
            return _capturedModel
        }
        var capturedToolChoice: ToolChoice? {
            lock.lock(); defer { lock.unlock() }
            return _capturedToolChoice
        }
        var capturedMessages: [LLMMessage] {
            lock.lock(); defer { lock.unlock() }
            return _capturedMessages
        }
        var capturedTools: [ToolSchema] {
            lock.lock(); defer { lock.unlock() }
            return _capturedTools
        }

        func stream(
            messages: [LLMMessage],
            tools: [ToolSchema],
            toolChoice: ToolChoice,
            model: ModelID,
            maxOutputTokens: Int,
            cacheHints: CacheHints?
        ) -> AsyncThrowingStream<LLMEvent, Error> {
            lock.lock()
            _capturedMessages = messages
            _capturedTools = tools
            _capturedToolChoice = toolChoice
            _capturedModel = model
            let events = scriptedEvents
            let willThrow = throwOnFirst
            lock.unlock()

            return AsyncThrowingStream { continuation in
                if let err = willThrow {
                    continuation.finish(throwing: err)
                    return
                }
                for e in events {
                    continuation.yield(e)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - MemoryPrompts shape

    func testMem0SystemPromptShape() {
        let prompt = MemoryPrompts.mem0System(priorFacts: [])
        // Required content
        let mustContain = ["memory extractor", "ADD", "UPDATE", "NOOP",
                           "durable personal facts",
                           "preferences", "relationships", "decisions", "project state"]
        for term in mustContain {
            XCTAssertTrue(prompt.contains(term),
                          "Prompt missing required term: \(term)\n--- prompt ---\n\(prompt)")
        }
        // Required exclusions are explicitly named
        let mustExclude = ["trivia", "ephemeral state", "question content"]
        for term in mustExclude {
            XCTAssertTrue(prompt.contains(term),
                          "Prompt must explicitly call out the excluded term: \(term)")
        }
    }

    func testMem0SystemPromptIncludesPriorFacts() {
        let priors: [Fact] = [
            Fact(id: 17, subject: "Sarah", predicate: "works_at", object: "Acme",
                 sourceTurnId: 1, validFrom: 1, createdAt: 1),
            Fact(id: 18, subject: "James", predicate: "prefers", object: "dark mode",
                 sourceTurnId: 2, validFrom: 2, createdAt: 2),
        ]
        let prompt = MemoryPrompts.mem0System(priorFacts: priors)
        XCTAssertTrue(prompt.contains("Sarah"))
        XCTAssertTrue(prompt.contains("Acme"))
        XCTAssertTrue(prompt.contains("[17]"))
        XCTAssertTrue(prompt.contains("[18]"))
    }

    func testMem0SystemPromptCapsAt4KB() {
        // 100 long facts blow past 4 KB; the renderer must truncate.
        let priors: [Fact] = (0..<100).map { i in
            let s = String(repeating: "x", count: 80)
            return Fact(id: Int64(i), subject: s, predicate: "p", object: "o",
                        sourceTurnId: 0, validFrom: 0, createdAt: 0)
        }
        let prompt = MemoryPrompts.mem0System(priorFacts: priors)
        // The cap is on the priors body; total prompt is bounded near 4 KB + boilerplate.
        XCTAssertLessThan(prompt.utf8.count, 6000,
                          "Prompt body should be bounded by the priors cap.")
    }

    func testFormatUserPrompt() {
        let s = MemoryPrompts.format(user: "I prefer dark mode", assistant: "Got it.")
        XCTAssertTrue(s.contains("I prefer dark mode"))
        XCTAssertTrue(s.contains("Got it."))
        XCTAssertTrue(s.contains("USER"))
        XCTAssertTrue(s.contains("ASSISTANT"))
    }

    // MARK: - MemoryTools schema

    func testApplyMemoryOpsToolSchema() throws {
        XCTAssertEqual(MemoryTools.applyMemoryOps.name, "apply_memory_ops")

        guard let schema = try JSONSerialization.jsonObject(with: MemoryTools.applyMemoryOps.inputSchema) as? [String: Any],
              let props = schema["properties"] as? [String: Any],
              let ops = props["ops"] as? [String: Any]
        else {
            return XCTFail("schema missing properties.ops")
        }
        XCTAssertEqual(ops["type"] as? String, "array")

        guard let items = ops["items"] as? [String: Any],
              let itemProps = items["properties"] as? [String: Any]
        else {
            return XCTFail("items.properties missing")
        }

        let expectedFields = ["op", "subject", "predicate", "object", "supersedes_fact_id"]
        for f in expectedFields {
            XCTAssertNotNil(itemProps[f], "items.properties.\(f) missing")
        }

        // Top-level required: ["ops"]
        XCTAssertEqual(schema["required"] as? [String], ["ops"])

        // Per-item required: ["op"]
        XCTAssertEqual(items["required"] as? [String], ["op"])
    }

    // MARK: - MemoryExtractor

    func testExtractorReturnsParsedOpsOnHappyPath() async throws {
        let mock = MockLLMProvider()
        let argsJSON = try JSONSerialization.data(withJSONObject: ["ops": [
            ["op": "ADD", "subject": "Sarah", "predicate": "works_at", "object": "Acme"]
        ]])
        let toolReq = ToolUseRequest(id: "t1", name: "apply_memory_ops", argsJSON: argsJSON)
        mock.scriptedEvents = [.toolUseRequested(toolReq), .messageStop]

        let extractor = MemoryExtractor(provider: mock)
        let ops = try await extractor.extract(
            userText: "Sarah works at Acme.",
            assistantText: "Noted.",
            priorActiveFacts: []
        )
        XCTAssertEqual(ops.count, 1)
        guard case let .add(s, p, o, _) = ops[0] else {
            return XCTFail("expected ADD")
        }
        XCTAssertEqual(s, "Sarah")
        XCTAssertEqual(p, "works_at")
        XCTAssertEqual(o, "Acme")
    }

    func testExtractorReturnsEmptyOnNoToolCall() async throws {
        let mock = MockLLMProvider()
        mock.scriptedEvents = [.textDelta("free-form text"), .messageStop]

        let extractor = MemoryExtractor(provider: mock)
        let ops = try await extractor.extract(
            userText: "What's the weather?",
            assistantText: "Sunny.",
            priorActiveFacts: []
        )
        XCTAssertTrue(ops.isEmpty,
                      "No apply_memory_ops tool call must be treated as NOOP (empty ops list).")
    }

    func testExtractorPropagatesProviderErrors() async {
        struct DummyError: Error {}
        let mock = MockLLMProvider()
        mock.throwOnFirst = DummyError()

        let extractor = MemoryExtractor(provider: mock)
        do {
            _ = try await extractor.extract(
                userText: "u", assistantText: "a", priorActiveFacts: []
            )
            XCTFail("expected DummyError to propagate")
        } catch is DummyError {
            // expected
        } catch {
            XCTFail("expected DummyError, got \(error)")
        }
    }

    func testExtractorUsesQwen36() async throws {
        let mock = MockLLMProvider()
        mock.scriptedEvents = [.messageStop]

        let extractor = MemoryExtractor(provider: mock)
        _ = try await extractor.extract(
            userText: "u", assistantText: "a", priorActiveFacts: []
        )
        XCTAssertEqual(mock.capturedModel, ModelID.qwen36)
    }

    func testExtractorCallsToolChoiceAuto() async throws {
        let mock = MockLLMProvider()
        mock.scriptedEvents = [.messageStop]

        let extractor = MemoryExtractor(provider: mock)
        _ = try await extractor.extract(
            userText: "u", assistantText: "a", priorActiveFacts: []
        )
        XCTAssertEqual(mock.capturedToolChoice, .auto)
    }

    func testExtractorAdvertisesApplyMemoryOpsTool() async throws {
        let mock = MockLLMProvider()
        mock.scriptedEvents = [.messageStop]

        let extractor = MemoryExtractor(provider: mock)
        _ = try await extractor.extract(
            userText: "u", assistantText: "a", priorActiveFacts: []
        )
        XCTAssertEqual(mock.capturedTools.count, 1)
        XCTAssertEqual(mock.capturedTools.first?.name, "apply_memory_ops")
    }
}
