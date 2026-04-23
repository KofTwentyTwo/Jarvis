import Foundation

public enum SchemaMigrator {
    public static let currentVersion = 1

    public static func migrate(_ data: Data, from: Int, to: Int) throws -> Data {
        // WR-04: `from > to` means the user's config is newer than this
        // build supports. Carry both numbers so the error message can read
        // "have v2, supports v1" instead of the old ambiguous
        // `futureSchema(version: 2)`.
        guard from <= to else {
            throw ConfigError.futureSchema(have: from, supports: to)
        }
        var current = data
        var v = from
        while v < to {
            current = try migrateStep(current, fromVersion: v, targetVersion: to)
            v += 1
        }
        return current
    }

    private static func migrateStep(_ data: Data, fromVersion v: Int, targetVersion to: Int) throws -> Data {
        switch v {
        // P1 ships at v1; no v0→v1 migrator exists.
        // Future: case 1: return try v1ToV2(data)
        default:
            // WR-04: carry both numbers. `have` is the intermediate version
            // at the point of failure, `supports` is the migration target.
            throw ConfigError.unknownSchemaVersion(have: v, supports: to)
        }
    }
}
