import Foundation

/// Plan 07-05 / D-17 — pure low-confidence heuristic, testable in isolation.
///
/// Returns `true` when EITHER:
///   1. The response (after trimming whitespace) is shorter than
///      `config.lowConfidenceMinChars`.
///   2. The response (lowercased) contains any phrase from
///      `config.lowConfidenceSubstrings` (case-insensitive contains).
///
/// The substring set + length threshold are read from the passed-in config —
/// the function does not fall back to hard-coded defaults if the config is
/// non-default. This is the property `testHeuristicReadsFromConfigNotMagic
/// Constants` exercises.
public enum VisionEscalationHeuristic {
    public static func evaluateLowConfidence(
        _ text: String,
        config: VisionRouterConfig
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < config.lowConfidenceMinChars {
            return true
        }
        let lower = trimmed.lowercased()
        for sub in config.lowConfidenceSubstrings {
            if lower.contains(sub.lowercased()) {
                return true
            }
        }
        return false
    }
}
