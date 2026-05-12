import XCTest
import Foundation
@testable import OllamaProvider
@testable import AgentCore

/// Unit tests for `OllamaRequestBody`.
///
/// Test R1 is the AGENT-07 critical regression guard: `ToolChoice.none`
/// MUST omit the `tools` array entirely from the native body.
final class OllamaRequestBodyTests: XCTestCase {

    // MARK: - Helpers

    /// Encode and parse back to `[String: Any]` for structural assertions.
    private func nativeDict(
        messages: [LLMMessage],
        tools: [ToolSchema] = [],
        toolChoice: ToolChoice,
        model: ModelID = .qwen25coder32b,
        maxOutputTokens: Int = 8192
    ) throws -> [String: Any] {
        let data = try OllamaRequestBody.encodeNative(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens
        )
        let raw = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(raw as? [String: Any])
    }

    private func sampleTool(name: String = "get_time") -> ToolSchema {
        ToolSchema(
            name: name,
            description: "Get the current time.",
            inputSchema: Data(#"{"type":"object","properties":{"timezone":{"type":"string"}}}"#.utf8)
        )
    }

    // MARK: - R1: AGENT-07 — .none drops tools array entirely

    func testToolChoiceNone_DropsToolsArrayEntirely_AGENT07() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [sampleTool()],
            toolChoice: .none
        )
        XCTAssertNil(dict["tools"],
            "AGENT-07 regression: ToolChoice.none MUST omit the tools key entirely; got: \(dict)")
    }

    // MARK: - R2: .auto + tools → tools array present, parameters key

    func testToolChoiceAuto_IncludesToolsArrayWithParameters() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [sampleTool()],
            toolChoice: .auto
        )
        let tools = try XCTUnwrap(dict["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_time")
        XCTAssertEqual(function["description"] as? String, "Get the current time.")
        // Critical: Ollama uses `parameters`, not `input_schema`.
        XCTAssertNotNil(function["parameters"], "Ollama tools use the `parameters` key")
        XCTAssertNil(function["input_schema"], "input_schema is Anthropic-only")
    }

    // MARK: - R3: .tool(name:) appends synthetic system hint

    func testToolChoiceTool_AppendsSyntheticSystemHint() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [sampleTool()],
            toolChoice: .tool(name: "get_time")
        )
        // tools array still present.
        XCTAssertNotNil(dict["tools"])
        // Last message is a synthetic system message hint.
        let messages = try XCTUnwrap(dict["messages"] as? [[String: Any]])
        let last = try XCTUnwrap(messages.last)
        XCTAssertEqual(last["role"] as? String, "system")
        XCTAssertEqual(last["content"] as? String, "Please use the get_time tool.")
    }

    // MARK: - R4: model string passes through

    func testModelStringPassThrough() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            toolChoice: .auto
        )
        XCTAssertEqual(dict["model"] as? String, "qwen2.5-coder:32b-instruct-q8_0")
    }

    // MARK: - R5: stream:true

    func testStreamTrueIsPresent() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            toolChoice: .auto
        )
        XCTAssertEqual(dict["stream"] as? Bool, true)
    }

    // MARK: - R6: tool result messages

    func testToolResultMessageEncoding() throws {
        let dict = try nativeDict(
            messages: [
                LLMMessage(role: .user, content: [.text("what time is it")]),
                LLMMessage(role: .assistant, content: [
                    .toolUse(id: "call_X", name: "get_time", argsJSON: Data(#"{"timezone":"UTC"}"#.utf8))
                ]),
                LLMMessage(role: .tool, content: [
                    .toolResult(toolUseId: "call_X", content: "2026-04-24T12:00:00Z")
                ], untrusted: true),
            ],
            toolChoice: .auto
        )
        let messages = try XCTUnwrap(dict["messages"] as? [[String: Any]])
        // Find the role:tool message.
        let toolMsg = try XCTUnwrap(messages.first { ($0["role"] as? String) == "tool" })
        XCTAssertEqual(toolMsg["content"] as? String, "2026-04-24T12:00:00Z")
        XCTAssertEqual(toolMsg["tool_call_id"] as? String, "call_X")

        // The assistant message should carry tool_calls.
        let asstMsg = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let calls = try XCTUnwrap(asstMsg["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        let callFn = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(callFn["name"] as? String, "get_time")
    }

    // MARK: - num_predict

    func testNumPredictPresent() throws {
        let dict = try nativeDict(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            toolChoice: .auto,
            maxOutputTokens: 4096
        )
        let options = try XCTUnwrap(dict["options"] as? [String: Any])
        XCTAssertEqual(options["num_predict"] as? Int, 4096)
    }

    // MARK: - OpenAI-compat: tool_choice serializes as string

    func testOpenAICompat_ToolChoiceNoneSerializesAsString() throws {
        let data = try OllamaRequestBody.encodeOpenAICompat(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [sampleTool()],
            toolChoice: .none,
            model: .qwen25coder32b,
            maxOutputTokens: 8192
        )
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["tool_choice"] as? String, "none",
            "OpenAI-compat: ToolChoice.none → \"none\" string (tools array can stay)")
        // OpenAI-compat path keeps tools present even on .none — different from native.
        XCTAssertNotNil(dict["tools"])
    }

    func testOpenAICompat_ToolChoiceTool_ObjectShape() throws {
        let data = try OllamaRequestBody.encodeOpenAICompat(
            messages: [LLMMessage(role: .user, content: [.text("hi")])],
            tools: [sampleTool()],
            toolChoice: .tool(name: "get_time"),
            model: .qwen25coder32b,
            maxOutputTokens: 8192
        )
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tc = try XCTUnwrap(dict["tool_choice"] as? [String: Any])
        XCTAssertEqual(tc["type"] as? String, "function")
        let function = try XCTUnwrap(tc["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_time")
    }
}
