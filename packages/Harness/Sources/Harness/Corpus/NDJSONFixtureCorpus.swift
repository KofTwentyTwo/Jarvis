import Foundation

/// One Ollama fixture entry. Both native `/api/chat` NDJSON and
/// `/v1/chat/completions` OpenAI-compat SSE shapes ship in the same corpus
/// directory; `transport` selects which `OllamaProvider` decoder path the
/// runner exercises.
public struct NDJSONFixture: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let description: String
    public let fileName: String
    public let transport: Transport
    public let expectedEventCount: Int
    public let expectedEventTags: [String]

    public enum Transport: String, Sendable, Codable, Equatable {
        case native            // `/api/chat` line-delimited JSON
        case openAICompat      // `/v1/chat/completions` SSE (`data: ...`)
    }

    public init(
        id: String,
        description: String,
        fileName: String,
        transport: Transport,
        expectedEventCount: Int,
        expectedEventTags: [String]
    ) {
        self.id = id
        self.description = description
        self.fileName = fileName
        self.transport = transport
        self.expectedEventCount = expectedEventCount
        self.expectedEventTags = expectedEventTags
    }
}

public enum NDJSONFixtureCorpus {
    public static let all: [NDJSONFixture] = {
        (try? loadManifest()) ?? []
    }()

    public static func loadManifest() throws -> [NDJSONFixture] {
        guard let url = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Corpora/ndjson-ollama"
        ) else {
            throw LoaderError.manifestNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([NDJSONFixture].self, from: data)
    }

    public static func url(for fixture: NDJSONFixture) throws -> URL {
        let basename = fixture.fileName.replacingOccurrences(of: ".ndjson", with: "")
        guard let url = Bundle.module.url(
            forResource: basename,
            withExtension: "ndjson",
            subdirectory: "Corpora/ndjson-ollama"
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
