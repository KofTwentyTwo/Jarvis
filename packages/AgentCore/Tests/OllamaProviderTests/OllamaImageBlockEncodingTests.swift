import XCTest
import Foundation
@testable import OllamaProvider
import AgentCore

/// Plan 07-05 / Task 3 — OpenAI-compat image_url JSON encoding (T1 + T2 paths).
///
/// Both `gemma4:31b` via Ollama (`/api/chat` native and `/v1/chat/completions`
/// OpenAI-compat) AND `Qwen3.5-35B-A3B-VL` via vllm-mlx (which speaks
/// OpenAI-compat) consume this same encoding. The shape:
///
///   `{"type":"image_url","image_url":{"url":"data:<mediaType>;base64,<b64>"}}`
final class OllamaImageBlockEncodingTests: XCTestCase {

    private let fixtureBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private var fixtureBase64: String { fixtureBytes.base64EncodedString() }

    // MARK: - Test 1: data-URL shape (native /api/chat)

    func testNativeMultimodalBodyContainsDataURLImageBlock() throws {
        let imageBlock = ImageBlock(mediaType: "image/jpeg", data: fixtureBytes)
        let body = try OllamaRequestBody.encodeNativeMultimodal(
            messages: [LLMMessage(role: .user, content: [.text("describe")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "gemma4:31b"),
            maxOutputTokens: 256
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let userMsg = messages.last!
        let content = userMsg["content"] as! [[String: Any]]
        let imgBlocks = content.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imgBlocks.count, 1)
        let imgUrl = imgBlocks[0]["image_url"] as! [String: Any]
        let url = imgUrl["url"] as! String
        XCTAssertEqual(url, "data:image/jpeg;base64,\(fixtureBase64)",
            "OpenAI-compat data-URL shape: data:<mediaType>;base64,<b64>")
    }

    // MARK: - Test 2: OpenAI-compat path produces identical image_url shape

    func testOpenAICompatMultimodalBodyContainsDataURLImageBlock() throws {
        let imageBlock = ImageBlock(mediaType: "image/png", data: fixtureBytes)
        let body = try OllamaRequestBody.encodeOpenAICompatMultimodal(
            messages: [LLMMessage(role: .user, content: [.text("describe")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "Qwen/Qwen3.5-35B-A3B-VL"),
            maxOutputTokens: 256
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let userMsg = messages.last!
        let content = userMsg["content"] as! [[String: Any]]
        let imgBlocks = content.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imgBlocks.count, 1)
        let imgUrl = imgBlocks[0]["image_url"] as! [String: Any]
        let url = imgUrl["url"] as! String
        XCTAssertEqual(url, "data:image/png;base64,\(fixtureBase64)",
            "media_type derived from ImageBlock.mediaType, not hard-coded")
    }

    // MARK: - Test 3: text precedes image_url

    func testTextContentPrecedesImageURL() throws {
        let imageBlock = ImageBlock(mediaType: "image/jpeg", data: fixtureBytes)
        let body = try OllamaRequestBody.encodeOpenAICompatMultimodal(
            messages: [LLMMessage(role: .user, content: [.text("question")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "gemma4:31b"),
            maxOutputTokens: 256
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let content = messages.last!["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
    }

    // MARK: - Test 4: empty images regression-protect

    func testEmptyImagesNativeMatchesSingleModal() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text("hello")])
        ]
        let single = try OllamaRequestBody.encodeNative(
            messages: messages,
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "qwen2.5-coder:32b"),
            maxOutputTokens: 256
        )
        let multi = try OllamaRequestBody.encodeNativeMultimodal(
            messages: messages,
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "qwen2.5-coder:32b"),
            maxOutputTokens: 256
        )
        XCTAssertEqual(single, multi)
    }

    func testEmptyImagesOpenAICompatMatchesSingleModal() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text("hello")])
        ]
        let single = try OllamaRequestBody.encodeOpenAICompat(
            messages: messages,
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "qwen2.5-coder:32b"),
            maxOutputTokens: 256
        )
        let multi = try OllamaRequestBody.encodeOpenAICompatMultimodal(
            messages: messages,
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "qwen2.5-coder:32b"),
            maxOutputTokens: 256
        )
        XCTAssertEqual(single, multi)
    }
}
