import Foundation

/// Field-name allowlist consulted by `DriftClassifier` to decide whether a
/// recorded-vs-actual divergence is expected (IDs, timestamps, sampling
/// nondeterminism) or unexpected (real regression).
///
/// Plan 08-01 / D-20: the `alwaysExcluded` set inherits the OBS-02 exclusion
/// list verbatim. The `nondeterministicUnderSampling` set starts empty and is
/// populated empirically when the golden-corpus replays surface false
/// positives (08-02 onward).
public struct ExclusionList: Sendable, Codable, Equatable {
    /// Fields whose drift is always expected (IDs, timestamps, nonces).
    /// Inherits OBS-02 list verbatim per D-20.
    public let alwaysExcluded: Set<String>

    /// Fields whose drift is expected ONLY if recording temperature > 0.
    /// Seed empty per D-20; populated empirically when golden replays surface
    /// false positives (e.g., `textDelta` content under `temperature > 0`,
    /// `embedding` vectors).
    public let nondeterministicUnderSampling: Set<String>

    public init(
        alwaysExcluded: Set<String>,
        nondeterministicUnderSampling: Set<String>
    ) {
        self.alwaysExcluded = alwaysExcluded
        self.nondeterministicUnderSampling = nondeterministicUnderSampling
    }

    /// OBS-02 default — the eight fields enumerated by the replay-log writer
    /// at recording time as inherently nondeterministic across runs.
    public static let obs02Default = ExclusionList(
        alwaysExcluded: [
            "row_id",
            "session_id",
            "turn_id",
            "tool_use_id",
            "message_id",
            "ts",
            "monotonic_ns",
            "turn_nonce",
        ],
        nondeterministicUnderSampling: []
    )

    /// Load an exclusion list from a JSON sidecar file (e.g.,
    /// `Corpora/replay-golden/exclusions.json`).
    public static func load(from url: URL) throws -> ExclusionList {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExclusionList.self, from: data)
    }
}
