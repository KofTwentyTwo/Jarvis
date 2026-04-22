import Foundation

public enum ConfigLoader {
    public static func loadSnapshots(from url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.malformed(reason: "Unable to read config file: \(error.localizedDescription)")
        }

        struct Peek: Decodable { let schemaVersion: Int }
        let peek: Peek
        do {
            peek = try JSONDecoder().decode(Peek.self, from: data)
        } catch {
            throw ConfigError.malformed(reason: "Missing or invalid schemaVersion key")
        }

        let currentData = try SchemaMigrator.migrate(data, from: peek.schemaVersion, to: SchemaMigrator.currentVersion)
        let decoder = JSONDecoder()
        do {
            let launch = try decoder.decode(LaunchSnapshot.self, from: currentData)
            let perTurn = try decoder.decode(PerTurnSnapshot.self, from: currentData)
            return (launch, perTurn)
        } catch let e as ConfigError {
            throw e
        } catch let e as DecodingError {
            throw ConfigError.malformed(reason: String(describing: e))
        } catch {
            throw ConfigError.malformed(reason: error.localizedDescription)
        }
    }

    /// Returns the URL of the bundled default-config.json resource (used on missing file).
    public static func bundledDefaultConfigURL() -> URL? {
        Bundle.module.url(forResource: "default-config", withExtension: "json")
    }

    /// Writes the bundled default to the target URL and re-reads.
    public static func writeDefaultAndReload(to url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot) {
        guard let bundled = bundledDefaultConfigURL() else {
            throw ConfigError.malformed(reason: "Bundled default-config.json missing")
        }
        let defaultData = try Data(contentsOf: bundled)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try defaultData.write(to: url)
        return try loadSnapshots(from: url)
    }
}
