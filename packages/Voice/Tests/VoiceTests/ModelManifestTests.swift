import XCTest
import Foundation
@testable import Voice

/// Tests for ModelManifest SHA-256 verification (VOICE-01 weight pinning).
///
/// Fixture files live at Tests/VoiceTests/Fixtures/WakeWord/ — small synthetic
/// byte sequences whose SHA-256 hashes match the fixture MANIFEST.json.
final class ModelManifestTests: XCTestCase {

    // MARK: - Fixture setup

    private var fixtureDir: URL {
        // Locate Fixtures/WakeWord relative to this test file's source location.
        // __FILE__ expansion gives the compile-time path; at runtime we look for the
        // fixtures via Bundle.module (SPM test bundle) or a relative path from the
        // test binary's working directory.
        let here = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // VoiceTests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("WakeWord")
        return here
    }

    // MARK: - M1: All hashes match — verify succeeds

    func testM1_allHashesMatch_verifySucceeds() throws {
        // Arrange: fixtureDir contains MANIFEST.json + three ONNX stubs whose
        // SHA-256s match those in the manifest.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureDir.path),
                      "Fixture dir missing: \(fixtureDir.path)")

        // Act + Assert: no throw
        XCTAssertNoThrow(try ModelManifest.verify(modelDir: fixtureDir))
    }

    // MARK: - M2: Tampered file — throws modelHashMismatch

    func testM2_tamperedEmbeddingModel_throwsHashMismatch() throws {
        // Arrange: write a temp dir with a modified embedding_model.onnx
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try copyFixtures(from: fixtureDir, to: tmp)

        // Tamper: overwrite embedding bytes
        let tamperedURL = tmp.appendingPathComponent("embedding_model.onnx")
        try "TAMPERED_CONTENT".data(using: .utf8)!.write(to: tamperedURL)

        // Act
        do {
            try ModelManifest.verify(modelDir: tmp)
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
        // Arrange: temp dir without hey_jarvis_v0.1.onnx
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try copyFixtures(from: fixtureDir, to: tmp,
                         excluding: ["hey_jarvis_v0.1.onnx"])

        // Act
        do {
            try ModelManifest.verify(modelDir: tmp)
            XCTFail("Expected missingModel but verify succeeded")
        } catch let WakeWordError.missingModel(filename) {
            XCTAssertEqual(filename, "hey_jarvis_v0.1.onnx")
        } catch {
            XCTFail("Expected WakeWordError.missingModel but got: \(error)")
        }
    }

    // MARK: - M4: Malformed MANIFEST.json — throws a decoding error

    func testM4_malformedManifest_throwsDecodingError() throws {
        // Arrange: temp dir with a corrupt MANIFEST.json
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try copyFixtures(from: fixtureDir, to: tmp)
        let manifestURL = tmp.appendingPathComponent("MANIFEST.json")
        try "{ invalid json !!".data(using: .utf8)!.write(to: manifestURL)

        // Act: expect a DecodingError (JSONDecoder failure)
        XCTAssertThrowsError(try ModelManifest.verify(modelDir: tmp)) { error in
            // Should be a Swift DecodingError or similar JSON parse error
            XCTAssertFalse(error is WakeWordError,
                           "Expected JSON decoding error, not WakeWordError, got: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManifestTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func copyFixtures(from source: URL, to destination: URL,
                               excluding: [String] = []) throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: source.path)
        for item in items where !excluding.contains(item) {
            let src = source.appendingPathComponent(item)
            let dst = destination.appendingPathComponent(item)
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
