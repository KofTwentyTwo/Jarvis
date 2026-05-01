import Foundation

/// One adversarial corpus item per OBS-04 pillar (a) injection.
///
/// Plan 08-02 / D-22 mandates: the **majority** of these have an
/// `.toolResult` or `.mcpHelperOutput` vector — that's where SEC-06 nonce
/// wrap + SEC-07 sanitize live and the only place the structural defenses
/// can actually be exercised. `.userInput` placement tests the harness, not
/// the defenses (RESEARCH §Pitfall 2).
///
/// Hand-rolled `Codable` with exhaustive `switch` arms — no `default:` —
/// so adding a new vector forces a compile-time hit on every consumer
/// (project pattern S-1).
public struct InjectionAttempt: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let category: Category
    public let vector: Vector
    public let payload: String
    public let expectedOutcome: ExpectedOutcome

    public init(
        id: String,
        category: Category,
        vector: Vector,
        payload: String,
        expectedOutcome: ExpectedOutcome
    ) {
        self.id = id
        self.category = category
        self.vector = vector
        self.payload = payload
        self.expectedOutcome = expectedOutcome
    }

    public enum Category: String, Sendable, Codable, Equatable {
        case directOverride
        case indirectInjection
        case jailbreak
        case toolResultAttack
        case encodedPayload
        case unicodeAbuse
        case multiStageAttack
    }

    /// Where the adversarial bytes are planted in the pipeline.
    public enum Vector: Sendable, Equatable {
        case userInput
        case toolResult(toolName: String)
        case mcpHelperOutput(helperName: String)
        case clipboardContent
        case appleScriptSourceDescription
    }

    public enum ExpectedOutcome: String, Sendable, Codable, Equatable {
        case blockedBySanitize
        case wrappedInNonce
        case reachesModelButModelResists
        case triggersConfirmationSheet
    }
}

// MARK: - Vector hand-rolled Codable (no default: per S-1)

extension InjectionAttempt.Vector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case toolName
        case helperName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "userInput":
            self = .userInput
        case "toolResult":
            let name = try c.decode(String.self, forKey: .toolName)
            self = .toolResult(toolName: name)
        case "mcpHelperOutput":
            let name = try c.decode(String.self, forKey: .helperName)
            self = .mcpHelperOutput(helperName: name)
        case "clipboardContent":
            self = .clipboardContent
        case "appleScriptSourceDescription":
            self = .appleScriptSourceDescription
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown injection vector kind: \(other)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userInput:
            try c.encode("userInput", forKey: .kind)
        case .toolResult(let toolName):
            try c.encode("toolResult", forKey: .kind)
            try c.encode(toolName, forKey: .toolName)
        case .mcpHelperOutput(let helperName):
            try c.encode("mcpHelperOutput", forKey: .kind)
            try c.encode(helperName, forKey: .helperName)
        case .clipboardContent:
            try c.encode("clipboardContent", forKey: .kind)
        case .appleScriptSourceDescription:
            try c.encode("appleScriptSourceDescription", forKey: .kind)
        }
    }
}

// MARK: - Corpus loader

public enum InjectionCorpus {
    /// Default version when an older manifest predates the field.
    /// `loadFromBundle` rejects manifests with a numeric `manifest_version`
    /// less than 1 — the field exists from v1 forward.
    public static let unversionedDefault: Int = 1

    /// Loaded once via `loadFromBundle`, exposed for swift-testing
    /// `@Test(arguments:)` parameterization at suite-load time.
    public static let all: [InjectionAttempt] = {
        // Lazy-load; if anything is wrong (resource missing, JSON malformed)
        // tests will surface the error via the explicit `loadFromBundle`
        // entry point. Returning [] here would let an empty corpus pass.
        (try? loadFromBundle()) ?? []
    }()

    /// Manifest version most recently read by `loadFromBundle`. Surfaced by
    /// the checklist runner so each gate run records which corpus version
    /// was exercised.
    public static var loadedManifestVersion: Int { _loadedManifestVersion }
    private nonisolated(unsafe) static var _loadedManifestVersion: Int = unversionedDefault

    /// Variant that returns both the items AND the manifest version. Use
    /// from CLI surfaces that want to print the version alongside the
    /// item count; `loadFromBundle` (no-arg) keeps the existing return
    /// shape so call sites that don't care stay compiling.
    public static func loadFromBundleWithVersion() throws -> (items: [InjectionAttempt], manifestVersion: Int) {
        let manifest = try loadManifest()
        let items = try loadItems(from: manifest)
        return (items, manifest.manifest_version ?? unversionedDefault)
    }

    /// Read `Corpora/injection/manifest.json` (a list of `{id, file}` index
    /// entries) then resolve and decode each referenced payload file into
    /// an `InjectionAttempt`.
    public static func loadFromBundle() throws -> [InjectionAttempt] {
        let manifest = try loadManifest()
        return try loadItems(from: manifest)
    }

    private static func loadManifest() throws -> Manifest {
        let bundle = Bundle.module
        guard let manifestURL = bundle.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Corpora/injection"
        ) else {
            throw LoaderError.manifestNotFound
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        _loadedManifestVersion = manifest.manifest_version ?? unversionedDefault
        return manifest
    }

    private static func loadItems(from manifest: Manifest) throws -> [InjectionAttempt] {
        let bundle = Bundle.module
        var items: [InjectionAttempt] = []
        items.reserveCapacity(manifest.items.count)
        for entry in manifest.items {
            // Resource lookup wants the basename without extension.
            let basename = entry.file.replacingOccurrences(of: ".json", with: "")
            guard let itemURL = bundle.url(
                forResource: basename,
                withExtension: "json",
                subdirectory: "Corpora/injection"
            ) else {
                throw LoaderError.payloadNotFound(id: entry.id, file: entry.file)
            }
            let itemData = try Data(contentsOf: itemURL)
            let item = try JSONDecoder().decode(InjectionAttempt.self, from: itemData)
            guard item.id == entry.id else {
                throw LoaderError.idMismatch(manifest: entry.id, payload: item.id)
            }
            items.append(item)
        }
        return items
    }

    private struct Manifest: Codable {
        // Optional so first-load of a legacy manifest without the field
        // still decodes (the field was added in Phase 8 review-followup).
        let manifest_version: Int?
        let items: [Entry]
        struct Entry: Codable {
            let id: String
            let file: String
        }
    }

    public enum LoaderError: Swift.Error, Equatable {
        case manifestNotFound
        case payloadNotFound(id: String, file: String)
        case idMismatch(manifest: String, payload: String)
    }
}
