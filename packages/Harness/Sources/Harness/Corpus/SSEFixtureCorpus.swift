import Foundation

/// One Anthropic SSE fixture entry — the `.sse` file under
/// `Corpora/sse-anthropic/` plus the expected projected event sequence.
///
/// The expected sequence is a list of case-name tags
/// (`messageStart`, `textDelta`, `toolUseBuffering`, `toolUseRequested`,
/// `partialToolUseAtDisconnect`, `thinkingDelta`, `stopReason`, `usage`,
/// `messageStop`, `providerError`) — exactly the projection produced by
/// `LLMEventTag.tag(for:)` in `SSEFixtureRunner`. Comparing tags rather than
/// full `LLMEvent` values keeps the manifest portable across LLMEvent payload
/// changes while still verifying the structural sequence and pillar coverage.
public struct SSEFixture: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let description: String
    public let fileName: String
    public let expectedEventCount: Int
    public let expectedEventTags: [String]

    public init(
        id: String,
        description: String,
        fileName: String,
        expectedEventCount: Int,
        expectedEventTags: [String]
    ) {
        self.id = id
        self.description = description
        self.fileName = fileName
        self.expectedEventCount = expectedEventCount
        self.expectedEventTags = expectedEventTags
    }
}

/// SSE fixture corpus loader. Reads `Corpora/sse-anthropic/manifest.json`
/// (a flat array of `SSEFixture`).
public enum SSEFixtureCorpus {
    public static let all: [SSEFixture] = {
        (try? loadManifest()) ?? []
    }()

    public static func loadManifest() throws -> [SSEFixture] {
        guard let url = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Corpora/sse-anthropic"
        ) else {
            throw LoaderError.manifestNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SSEFixture].self, from: data)
    }

    /// Resolve the on-disk URL of a fixture's `.sse` file inside the bundle.
    public static func url(for fixture: SSEFixture) throws -> URL {
        let basename = fixture.fileName.replacingOccurrences(of: ".sse", with: "")
        guard let url = Bundle.module.url(
            forResource: basename,
            withExtension: "sse",
            subdirectory: "Corpora/sse-anthropic"
        ) else {
            throw LoaderError.fixtureNotFound(id: fixture.id, file: fixture.fileName)
        }
        return url
    }

    public enum LoaderError: Swift.Error, Equatable {
        case manifestNotFound
        case fixtureNotFound(id: String, file: String)
    }
}
