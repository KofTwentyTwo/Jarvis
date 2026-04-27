import XCTest
import Foundation
import CryptoKit
@testable import Voice

/// Tests for ModelManifest SHA-256 verification (VOICE-01 weight pinning).
///
/// Fixtures are created in-memory (temp directories) so no SPM resource
/// declarations are needed and tests run without network access.
///
/// Fixture SHA-256 values are computed from known byte strings (see `makeGoodFixtures`).
final class ModelManifestTests: XCTestCase {

    // MARK: - Fixture bytes (deterministic — same bytes every run)

    private static let melBytes   = "FAKE_MEL_ONNX_v1".data(using: .utf8)!
    private static let embBytes   = "FAKE_EMB_ONNX_v1".data(using: .utf8)!
    private static let jarBytes   = "FAKE_JAR_ONNX_v1".data(using: .utf8)!

    private static func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let melSha = sha256hex(melBytes)
    private static let embSha = sha256hex(embBytes)
    private static let jarSha = sha256hex(jarBytes)

    // MARK: - M1: All hashes match — verify succeeds

    func testM1_allHashesMatch_verifySucceeds() throws {
        let dir = try makeGoodFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNoThrow(try ModelManifest.verify(modelDir: dir))
    }

    // MARK: - M2: Tampered file — throws modelHashMismatch

    func testM2_tamperedEmbeddingModel_throwsHashMismatch() throws {
        let dir = try makeGoodFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Tamper embedding_model.onnx
        let tamperedURL = dir.appendingPathComponent("embedding_model.onnx")
        try "TAMPERED_CONTENT".data(using: .utf8)!.write(to: tamperedURL)

        do {
            try ModelManifest.verify(modelDir: dir)
            XCTFail("Expected modelHashMismatch but verify succeeded")
        } catch let WakeWordError.modelHashMismatch(filename, expected, got) {
            XCTAssertEqual(filename, "embedding_model.onnx")
            XCTAssertFalse(expected.isEmpty)
            XCTAssertFalse(got.isEmpty)
            XCTAssertNotEqual(expected, got)
        } catch {
            XCTFail("Expected WakeWordError.modelHashMismatch but got: \(error)")
        }
    }

    // MARK: - M3: Missing file — throws missingModel

    func testM3_missingJarvisModel_throwsMissingModel() throws {
        let dir = try makeGoodFixtures(excluding: ["hey_jarvis_v0.1.onnx"])
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try ModelManifest.verify(modelDir: dir)
            XCTFail("Expected missingModel but verify succeeded")
        } catch let WakeWordError.missingModel(filename) {
            XCTAssertEqual(filename, "hey_jarvis_v0.1.onnx")
        } catch {
            XCTFail("Expected WakeWordError.missingModel but got: \(error)")
        }
    }

    // MARK: - M4: Malformed MANIFEST.json — throws a decoding error

    func testM4_malformedManifest_throwsDecodingError() throws {
        let dir = try makeGoodFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Overwrite MANIFEST.json with garbage JSON
        let manifestURL = dir.appendingPathComponent("MANIFEST.json")
        try "{ invalid json !!".data(using: .utf8)!.write(to: manifestURL)

        XCTAssertThrowsError(try ModelManifest.verify(modelDir: dir)) { error in
            XCTAssertFalse(error is WakeWordError,
                           "Expected JSON decoding error, not WakeWordError — got: \(error)")
        }
    }

    // MARK: - Fixture builder

    /// Creates a temp directory with MANIFEST.json + three ONNX stubs whose hashes match.
    private func makeGoodFixtures(excluding: [String] = []) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManifestTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "version": 1,
            "models": [
                ["filename": "melspectrogram.onnx",  "sha256": Self.melSha],
                ["filename": "embedding_model.onnx", "sha256": Self.embSha],
                ["filename": "hey_jarvis_v0.1.onnx", "sha256": Self.jarSha],
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                       options: .prettyPrinted)
        try manifestData.write(to: tmp.appendingPathComponent("MANIFEST.json"))

        let files: [(String, Data)] = [
            ("melspectrogram.onnx",  Self.melBytes),
            ("embedding_model.onnx", Self.embBytes),
            ("hey_jarvis_v0.1.onnx", Self.jarBytes),
        ]
        for (name, data) in files where !excluding.contains(name) {
            try data.write(to: tmp.appendingPathComponent(name))
        }
        return tmp
    }
}
