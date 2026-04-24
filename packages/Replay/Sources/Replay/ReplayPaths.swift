import Foundation

/// Filesystem paths owned by the replay subsystem.
///
/// The replay database is `~/Library/Application Support/Jarvis/replay.db` —
/// distinct from `~/Library/Logs/Jarvis/` (swift-log text channels from
/// Plan 01-02) and `jarvis.db` (memory store, Phase 7).
public enum ReplayPaths {
    /// `~/Library/Application Support/Jarvis/replay.db`. Caller is responsible
    /// for ensuring the parent directory exists; `ensureParentDirectory()`
    /// does that lazily.
    public static var defaultDatabaseURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("replay.db", isDirectory: false)
    }

    /// Ensure the parent directory of `url` exists. Intermediate directories
    /// are created with default attributes. Throws if the directory cannot be
    /// created (e.g., disk full).
    public static func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }
}
