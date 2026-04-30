// ChecklistManifest.swift
//
// Phase 8 Plan 04 / OBS-04 pillar (h). Hand-rolled Codable for the closed
// set of mechanization types (D-16). The decoder REJECTS manifests where a
// grep-style item is missing `expected_count` (D-17 silent-green guard).
//
// Pattern source: PATTERNS.md §S-1 (hand-rolled Codable, exhaustive switch,
// no `default:` over OUR enums). The `init(from:)` switches over the YAML
// type-discriminator string — that switch DOES carry a `default:` arm
// because String is open-ended, but the arm THROWS rather than silently
// accepting an unknown discriminator. Adding a new MechanizationType case
// requires adding a new String → case mapping; both must move together.

import Foundation
import Yams

/// Subset of plist scalar shapes encountered in app `Info.plist` files.
/// `plist_check` items declare an expected scalar; YAML supports bool /
/// string / int natively so we ride those three cases.
public enum PlistValue: Sendable, Codable, Equatable {
    case bool(Bool)
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "PlistValue must be Bool, Int, or String"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

/// Closed set of checklist mechanizations (D-16). Hand-rolled Codable so
/// the type-discriminator is explicit YAML text.
public enum MechanizationType: Sendable, Equatable {
    case swiftTest(suite: String, test: String)
    case script(path: String, args: [String])
    case grepNegative(file: String, pattern: String, expectedCount: Int)
    case grepPositive(file: String, pattern: String, expectedCount: Int)
    case plistCheck(file: String, key: String, expectedValue: PlistValue)
    case codesignGrep(identity: String, pattern: String, expectedCount: Int)
    case manual(description: String)
}

extension MechanizationType: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, suite, test, path, args, file, pattern, key
        case expectedCount = "expected_count"
        case expectedValue = "expected_value"
        case identity, description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "swift_test":
            self = .swiftTest(
                suite: try container.decode(String.self, forKey: .suite),
                test: try container.decode(String.self, forKey: .test)
            )
        case "script":
            self = .script(
                path: try container.decode(String.self, forKey: .path),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? []
            )
        case "grep_negative":
            guard container.contains(.expectedCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expectedCount,
                    in: container,
                    debugDescription: "D-17: expected_count required on grep_negative item"
                )
            }
            self = .grepNegative(
                file: try container.decode(String.self, forKey: .file),
                pattern: try container.decode(String.self, forKey: .pattern),
                expectedCount: try container.decode(Int.self, forKey: .expectedCount)
            )
        case "grep_positive":
            guard container.contains(.expectedCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expectedCount,
                    in: container,
                    debugDescription: "D-17: expected_count required on grep_positive item"
                )
            }
            self = .grepPositive(
                file: try container.decode(String.self, forKey: .file),
                pattern: try container.decode(String.self, forKey: .pattern),
                expectedCount: try container.decode(Int.self, forKey: .expectedCount)
            )
        case "plist_check":
            self = .plistCheck(
                file: try container.decode(String.self, forKey: .file),
                key: try container.decode(String.self, forKey: .key),
                expectedValue: try container.decode(PlistValue.self, forKey: .expectedValue)
            )
        case "codesign_grep":
            guard container.contains(.expectedCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expectedCount,
                    in: container,
                    debugDescription: "D-17: expected_count required on codesign_grep item"
                )
            }
            self = .codesignGrep(
                identity: try container.decode(String.self, forKey: .identity),
                pattern: try container.decode(String.self, forKey: .pattern),
                expectedCount: try container.decode(Int.self, forKey: .expectedCount)
            )
        case "MANUAL", "manual":
            self = .manual(description: try container.decode(String.self, forKey: .description))
        default:
            // The discriminator is a String, so the switch needs a default
            // arm. We THROW here rather than silently accept — adding a new
            // mechanization case requires adding a new branch to the switch
            // above. The S-1 invariant (compile-time exhaustiveness on our
            // own enums) is preserved at the encode-side switch below.
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown mechanization type '\(type)'. Allowed: swift_test|script|grep_negative|grep_positive|plist_check|codesign_grep|MANUAL"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .swiftTest(let suite, let test):
            try container.encode("swift_test", forKey: .type)
            try container.encode(suite, forKey: .suite)
            try container.encode(test, forKey: .test)
        case .script(let path, let args):
            try container.encode("script", forKey: .type)
            try container.encode(path, forKey: .path)
            if !args.isEmpty { try container.encode(args, forKey: .args) }
        case .grepNegative(let file, let pattern, let expectedCount):
            try container.encode("grep_negative", forKey: .type)
            try container.encode(file, forKey: .file)
            try container.encode(pattern, forKey: .pattern)
            try container.encode(expectedCount, forKey: .expectedCount)
        case .grepPositive(let file, let pattern, let expectedCount):
            try container.encode("grep_positive", forKey: .type)
            try container.encode(file, forKey: .file)
            try container.encode(pattern, forKey: .pattern)
            try container.encode(expectedCount, forKey: .expectedCount)
        case .plistCheck(let file, let key, let expectedValue):
            try container.encode("plist_check", forKey: .type)
            try container.encode(file, forKey: .file)
            try container.encode(key, forKey: .key)
            try container.encode(expectedValue, forKey: .expectedValue)
        case .codesignGrep(let identity, let pattern, let expectedCount):
            try container.encode("codesign_grep", forKey: .type)
            try container.encode(identity, forKey: .identity)
            try container.encode(pattern, forKey: .pattern)
            try container.encode(expectedCount, forKey: .expectedCount)
        case .manual(let description):
            try container.encode("MANUAL", forKey: .type)
            try container.encode(description, forKey: .description)
        }
    }
}

/// One row in a `checklist.yaml` manifest.
public struct ChecklistItem: Sendable, Codable, Equatable {
    public let id: String
    public let description: String
    public let mechanization: MechanizationType

    public init(id: String, description: String, mechanization: MechanizationType) {
        self.id = id
        self.description = description
        self.mechanization = mechanization
    }
}

/// One per-phase manifest.
public struct ChecklistManifest: Sendable, Codable, Equatable {
    public let phase: String
    public let items: [ChecklistItem]

    public init(phase: String, items: [ChecklistItem]) {
        self.phase = phase
        self.items = items
    }

    /// Load and decode a `checklist.yaml` from disk. Yams parses the YAML
    /// into a Foundation object tree, which we then serialize to JSON and
    /// hand to JSONDecoder — this lets us reuse the hand-rolled Codable
    /// init above unchanged.
    public static func load(yamlURL: URL) throws -> ChecklistManifest {
        let text = try String(contentsOf: yamlURL, encoding: .utf8)
        guard let yaml = try Yams.load(yaml: text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "YAML at \(yamlURL.path) parsed to nil"
            ))
        }
        let json = try JSONSerialization.data(withJSONObject: yaml)
        return try JSONDecoder().decode(ChecklistManifest.self, from: json)
    }
}
