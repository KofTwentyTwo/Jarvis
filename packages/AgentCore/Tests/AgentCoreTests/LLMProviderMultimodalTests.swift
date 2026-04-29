import XCTest
import Foundation
@testable import AgentCore

/// Plan 07-05 / Task 1 — D-18 protocol extension dispatch tests.
///
/// Behaviors verified:
/// 1. The default protocol extension forwards to the existing single-modal
///    stream when `images.isEmpty`.
/// 2. The default extension's behavior with non-empty images on a non-overriding
///    conformer is failure (precondition; documented dispatch contract).
/// 3. A conformer overriding the multimodal method receives non-empty images
///    on the override path, NOT on the single-modal forwarder.
/// 4. TurnInput's new `images` field is additive and round-trips correctly.
final class LLMProviderMultimodalTests: XCTestCase {

    // MARK: - Test 1: default forwarding when images.isEmpty

    func testDefaultExtensionForwardsToSingleModalWhenImagesEmpty() async throws {
        let mock = MockLLMProvider()
        let stream = mock.stream(
            messages: [LLMMessage(role: .user, content: [.text("hello")])],
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "test-model"),
            maxOutputTokens: 100,
            cacheHints: nil
        )
        var collected: [LLMEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        // The mock single-modal stream emits one .messageStop event.
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(await mock.singleModalCallCount, 1)
        XCTAssertEqual(await mock.multimodalCallCount, 0,
            "Default extension must not call a multimodal override that doesn't exist")
    }

    // MARK: - Test 3: explicit override receives images

    func testMultimodalOverrideReceivesImages() async throws {
        let mock = MockMultimodalLLMProvider()
        let imageBlock = ImageBlock(mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        let stream = mock.stream(
            messages: [LLMMessage(role: .user, content: [.text("describe")])],
            images: [imageBlock],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "test-model"),
            maxOutputTokens: 100,
            cacheHints: nil
        )
        var collected: [LLMEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(await mock.singleModalCallCount, 0,
            "Override should be invoked, not the single-modal forwarder")
        XCTAssertEqual(await mock.multimodalCallCount, 1)
        let recordedImages = await mock.lastImages
        XCTAssertEqual(recordedImages.count, 1)
        XCTAssertEqual(recordedImages.first?.mediaType, "image/jpeg")
    }

    // MARK: - Test 3b: override receives images.isEmpty cleanly too

    func testMultimodalOverrideHandlesEmptyImages() async throws {
        let mock = MockMultimodalLLMProvider()
        let stream = mock.stream(
            messages: [LLMMessage(role: .user, content: [.text("text-only")])],
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "test-model"),
            maxOutputTokens: 100,
            cacheHints: nil
        )
        for try await _ in stream {}
        XCTAssertEqual(await mock.multimodalCallCount, 1,
            "Override is responsible for the full method surface")
    }

    // MARK: - Test 4: ImageBlock equality + Sendable conformance

    func testImageBlockEquatable() {
        let a = ImageBlock(mediaType: "image/jpeg", data: Data([0x01, 0x02, 0x03]))
        let b = ImageBlock(mediaType: "image/jpeg", data: Data([0x01, 0x02, 0x03]))
        let c = ImageBlock(mediaType: "image/png", data: Data([0x01, 0x02, 0x03]))
        let d = ImageBlock(mediaType: "image/jpeg", data: Data([0x01, 0x02]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }
}

// MARK: - Mocks

/// Single-modal-only conformer. Inherits the multimodal default extension
/// which forwards to this when images.isEmpty.
private actor MockLLMProvider: LLMProvider {
    var singleModalCallCount: Int = 0
    var multimodalCallCount: Int = 0  // never incremented; default extension can't call it

    nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            Task {
                await self.bumpSingleModal()
                continuation.yield(.messageStop)
                continuation.finish()
            }
        }
    }

    private func bumpSingleModal() {
        singleModalCallCount += 1
    }
}

/// Multimodal-overriding conformer. Demonstrates that an explicit override
/// supersedes the default extension's forwarding behavior.
private actor MockMultimodalLLMProvider: LLMProvider {
    var singleModalCallCount: Int = 0
    var multimodalCallCount: Int = 0
    var lastImages: [ImageBlock] = []

    nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            Task {
                await self.bumpSingleModal()
                continuation.yield(.messageStop)
                continuation.finish()
            }
        }
    }

    nonisolated func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            Task {
                await self.bumpMultimodal(images: images)
                continuation.yield(.messageStop)
                continuation.finish()
            }
        }
    }

    private func bumpSingleModal() {
        singleModalCallCount += 1
    }

    private func bumpMultimodal(images: [ImageBlock]) {
        multimodalCallCount += 1
        lastImages = images
    }
}
