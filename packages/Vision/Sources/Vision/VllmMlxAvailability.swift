import Foundation

/// Plan 07-05 / Task 4 — single source of truth for whether T2 (vllm-mlx) is
/// reachable on this install at this moment.
///
/// Combines three gates:
///   1. `@available(macOS 26)` runtime version guard.
///   2. The configured `binaryURL` exists on disk.
///   3. The `features.vision.tier2` feature flag is enabled.
///
/// When this returns `false`, `VisionRouter.evaluatePostResponse(...)`
/// transparently demotes any T2 escalation to "use T1 result". The router
/// NEVER falls through to cloud (T3) without an explicit user opt-in phrase
/// — even when T2 is unavailable.
public enum VllmMlxAvailability {
    public struct Configuration: Sendable, Equatable {
        public let binaryURL: URL
        public let featureFlagEnabled: Bool

        public init(binaryURL: URL, featureFlagEnabled: Bool) {
            self.binaryURL = binaryURL
            self.featureFlagEnabled = featureFlagEnabled
        }
    }

    public static func isAvailable(
        configuration: Configuration,
        fileManager: FileManager = .default
    ) -> Bool {
        // Gate 3 (cheapest): feature flag.
        guard configuration.featureFlagEnabled else { return false }
        // Gate 2: binary exists at configured path.
        guard fileManager.fileExists(atPath: configuration.binaryURL.path) else {
            return false
        }
        // Gate 1: macOS 26+ runtime guard.
        if #available(macOS 26, *) {
            return true
        } else {
            return false
        }
    }
}
