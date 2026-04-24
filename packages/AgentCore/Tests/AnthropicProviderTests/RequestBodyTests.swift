import XCTest
import Foundation
@testable import AnthropicProvider
@testable import AgentCore

final class RequestBodyTests: XCTestCase {
    // MARK: - R1: 1h cache TTL on system prompt

    /// `ModelID.opus47` + `CacheHints(.extended1h)` → JSON includes
    /// `"model":"claude-opus-4-7"` AND
    /// `"cache_control":{"type":"ephemeral","ttl":"1h"}` on the first system block.
    func testExtended1hCacheControl() throws {
        let body = try RequestBody.encode(
            messages: [
                LLMMessage(role: .system, content: [.text("You are Jarvis.")]),
                LLMMessage(role: .user, content: [.text("hi")]),
            ],
            tools: [],
            toolChoice: .auto,
            model: .opus47,
            maxOutputTokens: 1024,
            cacheHints: CacheHints(systemPromptTTL: .extended1h)
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"model\":\"claude-opus-4-7\""))
        XCTAssertTrue(str.contains("\"ttl\":\"1h\""))
        XCTAssertTrue(str.contains("\"type\":\"ephemeral\""))
    }

    // MARK: - R2: no cache_control without hints

    func testNoCacheControlWithoutHints() throws {
        let body = try RequestBody.encode(
            messages: [
                LLMMessage(role: .system, content: [.text("Sys")]),
                LLMMessage(role: .user, content: [.text("hi")]),
            ],
            tools: [],
            toolChoice: .auto,
            model: .opus47,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(str.contains("cache_control"),
                       "cache_control must be absent when cacheHints is nil")
    }

    func testEphemeral5mProducesNoCacheControl() throws {
        let body = try RequestBody.encode(
            messages: [LLMMessage(role: .system, content: [.text("Sys")])],
            tools: [],
            toolChoice: .auto,
            model: .opus47,
            maxOutputTokens: 1024,
            cacheHints: CacheHints(systemPromptTTL: .ephemeral5m)
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(str.contains("cache_control"),
                       "5m is the default — no cache_control marker")
    }

    // MARK: - R3 + R4: tool_choice serialization

    func testToolChoiceNoneSerialization() throws {
        let body = try RequestBody.encode(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [],
            toolChoice: .none,
            model: .opus47,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"tool_choice\":{\"type\":\"none\"}"),
                      "ToolChoice.none must serialize to {\"type\":\"none\"}; got: \(str)")
    }

    func testToolChoiceAutoAnyToolSerialization() throws {
        // .auto
        let autoBody = try RequestBody.encode(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [],
            toolChoice: .auto,
            model: .opus47, maxOutputTokens: 1024, cacheHints: nil
        )
        XCTAssertTrue((String(data: autoBody, encoding: .utf8) ?? "")
            .contains("\"tool_choice\":{\"type\":\"auto\"}"))

        // .any
        let anyBody = try RequestBody.encode(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [],
            toolChoice: .any,
            model: .opus47, maxOutputTokens: 1024, cacheHints: nil
        )
        XCTAssertTrue((String(data: anyBody, encoding: .utf8) ?? "")
            .contains("\"tool_choice\":{\"type\":\"any\"}"))

        // .tool(name:)
        let toolBody = try RequestBody.encode(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [],
            toolChoice: .tool(name: "get_time"),
            model: .opus47, maxOutputTokens: 1024, cacheHints: nil
        )
        let toolStr = String(data: toolBody, encoding: .utf8) ?? ""
        XCTAssertTrue(toolStr.contains("\"name\":\"get_time\""))
        XCTAssertTrue(toolStr.contains("\"type\":\"tool\""))
    }

    // MARK: - R5: tools.input_schema passed through as JSON object (not string)

    func testToolInputSchemaAsObjectNotString() throws {
        let schema = #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        let tool = ToolSchema(
            name: "get_weather",
            description: "Returns the weather",
            inputSchema: Data(schema.utf8)
        )
        let body = try RequestBody.encode(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [tool],
            toolChoice: .auto,
            model: .opus47, maxOutputTokens: 1024, cacheHints: nil
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        // input_schema should be a JSON object, not a stringified blob:
        // expect `"input_schema":{` (object opener) NOT `"input_schema":"`.
        XCTAssertTrue(str.contains("\"input_schema\":{"),
                      "input_schema must be inline JSON object; got: \(str)")
        XCTAssertFalse(str.contains("\"input_schema\":\"{"),
                       "input_schema must NOT be double-encoded as a string")
        // The inner schema fields should appear:
        XCTAssertTrue(str.contains("\"properties\""))
        XCTAssertTrue(str.contains("\"city\""))
    }

    // MARK: - Bonus: header wiring on AnthropicProvider

    func testAnthropicProviderBuildsRequestWithBetaHeader() async {
        let provider = AnthropicProvider(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKeyProvider: { "sk-ant-FAKE" }
        )
        let body = Data("{}".utf8)
        let req = await provider.buildURLRequest(body: body, apiKey: "sk-ant-FAKE")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"),
                       "extended-cache-ttl-2025-04-11")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-FAKE")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }
}
