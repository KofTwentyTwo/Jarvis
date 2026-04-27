import Foundation
import CryptoKit

/// Verifies the SHA-256 integrity of the three openWakeWord ONNX model files.
///
/// MANIFEST.json schema (version 1):
/// ```json
/// {
///   "version": 1,
///   "models": [
///     {"filename": "melspectrogram.onnx",  "sha256": "<hex>"},
///     {"filename": "embedding_model.onnx", "sha256": "<hex>"},
///     {"filename": "hey_jarvis_v0.1.onnx", "sha256": "<hex>"}
///   ]
/// }
/// ```
///
/// ## Fail-closed discipline (T-06-02-01)
/// On hash mismatch, `verify(modelDir:)` throws `WakeWordError.modelHashMismatch` and
/// the session REFUSES to construct. Callers MUST NOT auto-redownload weights — surface
/// the error and require explicit operator action. This prevents a hostile actor from
/// swapping ONNX weights on disk and having them silently loaded into ORT.
///
/// ## Missing file
/// If a file listed in the manifest is absent, throws `WakeWordError.missingModel`.
/// Run `scripts/fetch-openwakeword-models.sh` to download the pinned weights.
///
/// ## Malformed manifest
/// If `MANIFEST.json` cannot be decoded, propagates a `DecodingError` — never silently
/// skipped.
///
/// ## Thread safety
/// `verify(modelDir:)` is a pure function (read-only I/O) — safe to call from any thread.
public enum ModelManifest {

    // MARK: - Codable schema

    private struct ManifestFile: Decodable {
        let version: Int
        let models: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
        let filename: String
        let sha256: String
    }

    // MARK: - Public API

    /// Verifies SHA-256 hashes of the ONNX files listed in `modelDir/MANIFEST.json`.
    ///
    /// Checks are run in manifest order (melspectrogram → embedding → classifier).
    /// The first failing check aborts verification — errors are not aggregated.
    ///
    /// - Parameter modelDir: Directory containing `MANIFEST.json` and the three
    ///   ONNX weight files. Typically `Resources/models/openwakeword/` from the app
    ///   bundle, or a temp directory in tests.
    /// - Throws: `WakeWordError.missingModel` if a listed file is absent from disk.
    ///           `WakeWordError.modelHashMismatch` if the computed SHA-256 differs
    ///           from the pinned value.
    ///           `DecodingError` if `MANIFEST.json` is malformed (not silently skipped).
    ///           Any `Error` from `Data(contentsOf:)` file I/O.
    public static func verify(modelDir: URL) throws {
        let manifestURL = modelDir.appendingPathComponent("MANIFEST.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ManifestFile.self, from: manifestData)

        for entry in manifest.models {
            let fileURL = modelDir.appendingPathComponent(entry.filename)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw WakeWordError.missingModel(filename: entry.filename)
            }

            let fileData = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: fileData)
            // Produce lowercase hex string: "ab12cd..." (64 chars for SHA-256)
            let computed = digest.map { String(format: "%02x", $0) }.joined()

            guard computed == entry.sha256 else {
                throw WakeWordError.modelHashMismatch(
                    filename: entry.filename,
                    expected: entry.sha256,
                    got: computed
                )
            }
        }
    }
}
