import XCTest
import Foundation
@testable import AnthropicProvider
import AgentCore

/// Plan 07-05 / Task 2 — Anthropic image_block JSON encoding (T3 path).
///
/// Behaviors verified:
/// 1. The multimodal request body contains the exact Anthropic Vision API
///    `image_block` shape: `{type:image, source:{type:base64, media_type, data}}`.
/// 2. `media_type` is sourced from `ImageBlock.mediaType` (not hard-coded).
/// 3. The image content block sits AFTER the text content block (deterministic
///    order; Anthropic accepts either, we test the chosen one).
/// 4. With `images: []`, the multimodal encoder produces a body byte-for-byte
///    identical to the single-modal encoder (regression-protection for
///    schema drift).
final class AnthropicImageBlockEncodingTests: XCTestCase {

    // Tiny fixture — the bytes don't need to be a valid JPEG for base64
    // round-trip testing. JPEG SOI marker + a few payload bytes.
    private let fixtureBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private var fixtureBase64: String { fixtureBytes.base64EncodedString() }

    // MARK: - Test 1: image_block shape

    func testMultimodalBodyContainsImageBlockShape() throws {
        let imageBlock = ImageBlock(mediaType: "image/jpeg", data: fixtureBytes)
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text("describe this")])
        ]
        let body = try RequestBody.encodeMultimodal(
            messages: messages,
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let topMessages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(topMessages.count, 1)
        let userMsg = topMessages[0]
        let content = userMsg["content"] as! [[String: Any]]
        // Find the image block.
        let imageBlocks = content.filter { ($0["type"] as? String) == "image" }
        XCTAssertEqual(imageBlocks.count, 1, "exactly one image block")
        let imgBlock = imageBlocks[0]
        let source = imgBlock["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, fixtureBase64)
    }

    // MARK: - Test 2: media_type is sourced from ImageBlock.mediaType

    func testMediaTypeIsSourcedFromImageBlock() throws {
        let imageBlock = ImageBlock(mediaType: "image/png", data: fixtureBytes)
        let body = try RequestBody.encodeMultimodal(
            messages: [LLMMessage(role: .user, content: [.text("desc")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let topMessages = json["messages"] as! [[String: Any]]
        let content = topMessages[0]["content"] as! [[String: Any]]
        let imgBlock = content.first { ($0["type"] as? String) == "image" }!
        let source = imgBlock["source"] as! [String: Any]
        XCTAssertEqual(source["media_type"] as? String, "image/png",
            "media_type must come from ImageBlock.mediaType, not be hard-coded")
    }

    // MARK: - Test 3: deterministic order — text first, then image

    func testTextBlockPrecedesImageBlock() throws {
        let imageBlock = ImageBlock(mediaType: "image/jpeg", data: fixtureBytes)
        let body = try RequestBody.encodeMultimodal(
            messages: [LLMMessage(role: .user, content: [.text("question")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let topMessages = json["messages"] as! [[String: Any]]
        let content = topMessages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2, "text + image")
        XCTAssertEqual(content[0]["type"] as? String, "text", "text block first")
        XCTAssertEqual(content[1]["type"] as? String, "image", "image block second")
    }

    // MARK: - Test 4: empty images produces same body as single-modal path

    func testEmptyImagesProducesSameBodyAsSingleModal() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text("hello")])
        ]
        let single = try RequestBody.encode(
            messages: messages,
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 256,
            cacheHints: nil
        )
        let multi = try RequestBody.encodeMultimodal(
            messages: messages,
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 256,
            cacheHints: nil
        )
        XCTAssertEqual(single, multi,
            "encodeMultimodal with empty images must be byte-identical to encode()")
    }
}
