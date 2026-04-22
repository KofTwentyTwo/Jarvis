import Foundation

public enum SchemaMigrator {
    public static let currentVersion = 1

    public static func migrate(_ data: Data, from: Int, to: Int) throws -> Data {
        guard from <= to else { throw ConfigError.futureSchema(version: from) }
        var current = data
        var v = from
        while v < to {
            current = try migrateStep(current, fromVersion: v)
            v += 1
        }
        return current
    }

    private static func migrateStep(_ data: Data, fromVersion v: Int) throws -> Data {
        switch v {
        // P1 ships at v1; no v0→v1 migrator exists.
        // Future: case 1: return try v1ToV2(data)
        default:
            throw ConfigError.unknownSchemaVersion(v)
        }
    }
}
