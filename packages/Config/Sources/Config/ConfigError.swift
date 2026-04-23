import Foundation

public enum ConfigError: Error, Sendable, Equatable {
    case malformed(reason: String)
    /// WR-04: a migration step found a schema version it doesn't know how to
    /// migrate from. `have` is the source version at the point of failure
    /// (may be an intermediate step, not the user's file version). `supports`
    /// is `SchemaMigrator.currentVersion` at build time.
    case unknownSchemaVersion(have: Int, supports: Int)
    /// WR-04: the user's config is newer than this Jarvis build supports.
    /// `have` is the version in the user's file; `supports` is the newest
    /// version this build can migrate to. "Cannot downgrade schema" is the
    /// human-readable semantic — users see `have > supports` and understand
    /// they have a newer file than Jarvis supports.
    case futureSchema(have: Int, supports: Int)
    case invalidOllamaHost(String)
}
