---
phase: 01-foundations
plan: 02
type: execute
wave: 2
depends_on: [01]
files_modified:
  - packages/Keychain/Sources/Keychain/KeychainItem.swift
  - packages/Keychain/Sources/Keychain/KeychainError.swift
  - packages/Keychain/Sources/Keychain/KeychainStore.swift
  - packages/Keychain/Sources/Keychain/SystemKeychainStore.swift
  - packages/Keychain/Tests/KeychainTests/KeychainTests.swift
  - packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift
  - packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift
  - packages/Logging/Sources/JarvisLogging/FileLogHandler.swift
  - packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift
  - packages/Logging/Sources/JarvisLogging/OSLogHandler.swift
  - packages/Logging/Sources/JarvisLogging/Redact.swift
  - packages/Logging/Sources/JarvisLogging/LogPaths.swift
  - packages/Logging/Sources/JarvisLogging/DateProvider.swift
  - packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift
  - packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift
  - packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift
  - packages/Config/Package.swift
  - packages/Config/Sources/Config/LaunchSnapshot.swift
  - packages/Config/Sources/Config/PerTurnSnapshot.swift
  - packages/Config/Sources/Config/OllamaConfig.swift
  - packages/Config/Sources/Config/AppleScriptPolicy.swift
  - packages/Config/Sources/Config/ConfirmationPolicy.swift
  - packages/Config/Sources/Config/LoggingLaunchConfig.swift
  - packages/Config/Sources/Config/ProviderSelection.swift
  - packages/Config/Sources/Config/TTSConfig.swift
  - packages/Config/Sources/Config/STTConfig.swift
  - packages/Config/Sources/Config/FeatureFlags.swift
  - packages/Config/Sources/Config/ConfigError.swift
  - packages/Config/Sources/Config/ConfigLoader.swift
  - packages/Config/Sources/Config/ConfigStore.swift
  - packages/Config/Sources/Config/SchemaMigrator.swift
  - packages/Config/Resources/default-config.json
  - packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift
  - packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift
  - packages/Config/Tests/ConfigTests/ConfigSplitTests.swift
  - packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift
  - packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift
  - packages/Config/Tests/ConfigTests/ConfigLoaderTests.swift
autonomous: true
requirements: [SEC-01, AGENT-05, SEC-05, SEC-08, OBS-05, OBS-06]
must_haves:
  truths:
    - "Anthropic API key round-trips through macOS Keychain via SystemKeychainStore (set/get/delete idempotent at service='com.kingsrook.jarvis', account='anthropic')"
    - "ollama.base_url with host not in {127.0.0.1, localhost, ::1} is rejected at decode time with ConfigError.invalidOllamaHost"
    - "LaunchSnapshot contains security keys (ollama, applescript, toolBlocklist, confirmationPolicy, logging); PerTurnSnapshot contains non-security keys (provider, tts, stt, featureFlags)"
    - "FeatureFlags appears in PerTurnSnapshot ONLY (not LaunchSnapshot) — OBS-05 resolution"
    - "applescript.skipAllowlist key does not exist in any schema (SEC-08 — no regex-bypass)"
    - "Four swift-log channels (agent, tools, ui, system) produce logs via MultiplexLogHandler that fans out to both FileLogHandler and OSLogHandler"
    - "Redact.apply() masks all 5 patterns: sk-ant-*, Authorization:Bearer, sk-* (OpenAI), AKIA*, ghp_*; leaves plain text unchanged"
    - "File log rotates daily at local midnight (lazy — first post-midnight write), retains last 7 days, deletes day-8+"
  artifacts:
    - path: "packages/Keychain/Sources/Keychain/SystemKeychainStore.swift"
      provides: "Security.framework wrapper for Keychain set/get/delete"
      contains: "kSecClassGenericPassword"
    - path: "packages/Config/Sources/Config/OllamaConfig.swift"
      provides: "AGENT-05 host validation in init(from:)"
      contains: "invalidOllamaHost"
    - path: "packages/Config/Sources/Config/LaunchSnapshot.swift"
      provides: "Frozen-at-launch security-sensitive config"
      contains: "LaunchSnapshot"
    - path: "packages/Config/Sources/Config/PerTurnSnapshot.swift"
      provides: "Mutable-at-runtime config; hosts feature flags (OBS-05)"
      contains: "FeatureFlags"
    - path: "packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift"
      provides: "Process-wide swift-log bootstrap with MultiplexLogHandler factory"
      contains: "LoggingSystem.bootstrap"
    - path: "packages/Logging/Sources/JarvisLogging/Redact.swift"
      provides: "OBS-06 / D-20 redact() covering exactly 5 patterns"
      contains: "sk-ant-"
  key_links:
    - from: "packages/Config/Sources/Config/OllamaConfig.swift"
      to: "ConfigError.invalidOllamaHost"
      via: "Decoder.init(from:) throws on non-localhost host"
      pattern: "invalidOllamaHost"
    - from: "packages/Logging/Sources/JarvisLogging/FileLogHandler.swift"
      to: "Redact.apply"
      via: "log() method calls Redact.apply before writer.append (single call site per S-4)"
      pattern: "Redact\\.apply"
    - from: "packages/Keychain/Sources/Keychain/SystemKeychainStore.swift"
      to: "Security.framework SecItemAdd/SecItemCopyMatching/SecItemUpdate/SecItemDelete"
      via: "kSecClassGenericPassword query dictionary"
      pattern: "SecItem(Add|CopyMatching|Update|Delete)"
---

<objective>
Build out the three non-UI SPM packages scaffolded in Plan 01: `Keychain` (Security.framework wrapper for SEC-01), `Config` (LaunchSnapshot / PerTurnSnapshot split per SEC-05 with AGENT-05 host validation and SEC-08 no-skip-allowlist enforcement, plus OBS-05 feature flags in PerTurnSnapshot only), and `Logging` (four-channel swift-log bootstrap with MultiplexLogHandler → FileLogHandler + OSLogHandler, lazy midnight rotation, retain-7, and the OBS-06/D-20 `redact()` function).

Purpose: These three packages are the sink of the dependency graph (PATTERNS §S-9). They have no dependencies on each other beyond Config→Keychain and Config→Logging, and they are consumed by Shell (Plan 04) and the App target (Plan 03). Building them in parallel with Plan 03 (which only touches `App/*`) is safe.

Output: Keychain + Config + Logging packages with full Phase-1 feature surface and Nyquist-compliant tests.

**Scope note:** This plan touches ~38 files, exceeding the 15-file threshold. Given the greenfield Phase-1 scope (17 REQ-IDs, no pre-existing codebase to incrementally modify), splitting would fragment tightly-coupled scaffolding work (the Keychain/Config/Logging triad is the sink of the dependency graph per PATTERNS §S-9 and needs to land as a unit) across more plans than the wave DAG requires. Mitigation: each task commits atomically (per-task git commit); the executor samples tests after every task boundary (`xcodebuild test -scheme <package>` or `cd packages/<Name> && swift test`); wave completion gates on `xcodebuild test -scheme JarvisTestsAll` so regressions surface at wave boundaries rather than phase-end.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/phases/01-foundations/01-CONTEXT.md
@.planning/phases/01-foundations/01-RESEARCH.md
@.planning/phases/01-foundations/01-PATTERNS.md
@.planning/phases/01-01-SUMMARY.md

<interfaces>
<!-- Contracts established by Plan 01 that this plan consumes -->

From Plan 01, `packages/Keychain/Package.swift`:
- Target name: `Keychain`; library product: `Keychain`; no SPM deps; Swift 6 strict.

From Plan 01, `packages/Logging/Package.swift`:
- Target name: `JarvisLogging` (NOT `Logging` — collides with swift-log's module); library product: `JarvisLogging`.
- Depends on `apple/swift-log` 1.5.3+; consumers `import JarvisLogging` for the factory and `import Logging` for swift-log's `Logger`.

From Plan 01, `packages/Config/Package.swift`:
- Target name: `Config`; depends on `Keychain` + `JarvisLogging`.

<!-- Contracts this plan ESTABLISHES that downstream plans (03, 04) will consume -->

Keychain public API (created in Task 1 here):
```swift
public struct KeychainItem: Sendable { let service: String; let account: String }
public extension KeychainItem {
    static let anthropic = KeychainItem(service: "com.kingsrook.jarvis", account: "anthropic")
}
public enum KeychainError: Error, Sendable { case itemNotFound, duplicateItem, unexpectedStatus(OSStatus) }
public protocol KeychainStore: Sendable {
    func set(_ value: String, for item: KeychainItem) throws
    func get(_ item: KeychainItem) throws -> String
    func delete(_ item: KeychainItem) throws
}
public struct SystemKeychainStore: KeychainStore { /* Security.framework wrapper */ }
```

Config public API (created in Task 2 here):
```swift
public struct LaunchSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let ollama: OllamaConfig
    public let applescript: AppleScriptPolicy
    public let toolBlocklist: [String]
    public let confirmationPolicy: ConfirmationPolicy
    public let logging: LoggingLaunchConfig
}
public struct PerTurnSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let provider: ProviderSelection
    public let tts: TTSConfig
    public let stt: STTConfig
    public let featureFlags: FeatureFlags
}
public enum ConfigLoader {
    public static func loadSnapshots(from url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot)
}
public actor ConfigStore { /* file watcher + publishers */ }
```

Logging public API (created in Task 3 here):
```swift
public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent, tools, ui, system
}
public enum JarvisLogHandlerFactory {
    public static func bootstrap()  // exactly once at AppDelegate.applicationWillFinishLaunching
    public static func make(label: String) -> LogHandler  // factory for MultiplexLogHandler
}
public enum Redact {
    public static func apply(_ s: String) -> String  // masks 5 patterns per OBS-06/D-20
}
```

PATTERNS cross-refs used throughout this plan:
- S-1: Swift 6 strict concurrency (already in Package.swift)
- S-3: Sendable-by-default for models and protocols
- S-4: Redact-at-write discipline — single call site in FileLogHandler.log (NOT in OSLogHandler)
- S-5: Keychain fetch-per-request, no caching
- S-6: Hard-block on safety failures — malformed config → NSAlert terminate (surfaced in AppDelegate by Plan 03; this plan throws ConfigError)
- S-8: One-bootstrap discipline — LoggingSystem.bootstrap called exactly once at AppDelegate
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Build Keychain package (KeychainItem, KeychainError, KeychainStore protocol, SystemKeychainStore, tests)</name>
  <files>packages/Keychain/Sources/Keychain/KeychainItem.swift, packages/Keychain/Sources/Keychain/KeychainError.swift, packages/Keychain/Sources/Keychain/KeychainStore.swift, packages/Keychain/Sources/Keychain/SystemKeychainStore.swift, packages/Keychain/Tests/KeychainTests/KeychainTests.swift</files>
  <behavior>
    - Test: `SystemKeychainStore().set("secret-value", for: .anthropic)` then `get(.anthropic)` returns "secret-value"
    - Test: idempotent `set()` — calling set() twice with different values overwrites without duplicateItem
    - Test: `get(.anthropic)` after `delete(.anthropic)` throws `.itemNotFound`
    - Test: `delete(.anthropic)` when item does not exist does NOT throw (errSecItemNotFound is swallowed per RESEARCH Q1 line 230)
    - Test: `KeychainItem.anthropic == KeychainItem(service: "com.kingsrook.jarvis", account: "anthropic")` (SEC-01 / D-10 constants verbatim)
    - Tests use a **per-test-random account suffix** (e.g. `"anthropic-test-\(UUID().uuidString)"`) to avoid colliding with real user Keychain state; cleanup in tearDown
    - Delete placeholder file and placeholder test created in Plan 01 Task 2
  </behavior>
  <read_first>
    - packages/Keychain/Package.swift (confirm target name, Swift 6 mode active)
    - packages/Keychain/Sources/Keychain/Placeholder.swift (to delete)
    - packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift (to delete)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 1 lines 133-241 (copy the Security.framework wrapper verbatim — it's 60 LOC and battle-tested)
    - .planning/phases/01-foundations/01-PATTERNS.md §G lines 84-93 (Keychain package file classifications + content contracts)
    - .planning/phases/01-foundations/01-CONTEXT.md D-10 (Keychain item constant `com.kingsrook.jarvis.anthropic`)
  </read_first>
  <action>
    Delete `packages/Keychain/Sources/Keychain/Placeholder.swift` and `packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift` — replaced by real sources.

    **`packages/Keychain/Sources/Keychain/KeychainItem.swift`** — exact content:
    ```swift
    import Foundation

    public struct KeychainItem: Sendable, Equatable {
        public let service: String
        public let account: String
        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    public extension KeychainItem {
        /// Anthropic API key storage location per SEC-01 / D-10.
        /// kSecAttrService: "com.kingsrook.jarvis"
        /// kSecAttrAccount: "anthropic"
        static let anthropic = KeychainItem(service: "com.kingsrook.jarvis", account: "anthropic")
    }
    ```

    **`packages/Keychain/Sources/Keychain/KeychainError.swift`** — exact content:
    ```swift
    import Foundation

    public enum KeychainError: Error, Sendable, Equatable {
        case itemNotFound
        case duplicateItem
        case unexpectedStatus(OSStatus)
    }
    ```

    **`packages/Keychain/Sources/Keychain/KeychainStore.swift`** — protocol (per S-3 Sendable):
    ```swift
    import Foundation

    public protocol KeychainStore: Sendable {
        func set(_ value: String, for item: KeychainItem) throws
        func get(_ item: KeychainItem) throws -> String
        func delete(_ item: KeychainItem) throws
    }
    ```

    **`packages/Keychain/Sources/Keychain/SystemKeychainStore.swift`** — copy the verbatim ~60-LOC shape from RESEARCH §Question 1 lines 175-234:
    ```swift
    import Foundation
    import Security

    public struct SystemKeychainStore: KeychainStore {
        public init() {}

        public func set(_ value: String, for item: KeychainItem) throws {
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
            ]
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if updateStatus == errSecSuccess { return }
            if updateStatus != errSecItemNotFound {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        }

        public func get(_ item: KeychainItem) throws -> String {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data,
                      let s = String(data: data, encoding: .utf8) else {
                    throw KeychainError.unexpectedStatus(status)
                }
                return s
            case errSecItemNotFound:
                throw KeychainError.itemNotFound
            default:
                throw KeychainError.unexpectedStatus(status)
            }
        }

        public func delete(_ item: KeychainItem) throws {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }
    ```

    If Swift 6 strict concurrency objects to `SystemKeychainStore` being `Sendable` (SecItem* is C), fall back to `public struct SystemKeychainStore: KeychainStore, @unchecked Sendable` per RESEARCH Assumption A7 (line 1525). Prefer the pure `Sendable` form first; only add `@unchecked` if the compiler complains.

    **`packages/Keychain/Tests/KeychainTests/KeychainTests.swift`** — XCTest suite covering the behaviors listed above. Use a random per-test `account` suffix:
    ```swift
    import XCTest
    @testable import Keychain

    final class KeychainTests: XCTestCase {
        private var testItem: KeychainItem!
        private let store = SystemKeychainStore()

        override func setUp() {
            super.setUp()
            // Random account so parallel test runs and real user Keychain state don't collide.
            testItem = KeychainItem(
                service: "com.kingsrook.jarvis.tests",
                account: "anthropic-test-\(UUID().uuidString)"
            )
        }

        override func tearDown() {
            try? store.delete(testItem)
            super.tearDown()
        }

        func test_setGetDeleteRoundTrip() throws {
            try store.set("secret-value-001", for: testItem)
            XCTAssertEqual(try store.get(testItem), "secret-value-001")
            try store.delete(testItem)
            XCTAssertThrowsError(try store.get(testItem)) { error in
                XCTAssertEqual(error as? KeychainError, .itemNotFound)
            }
        }

        func test_setIdempotentOverwrite() throws {
            try store.set("first", for: testItem)
            try store.set("second", for: testItem)
            XCTAssertEqual(try store.get(testItem), "second")
        }

        func test_deleteMissingDoesNotThrow() {
            // Never set; delete should swallow errSecItemNotFound.
            XCTAssertNoThrow(try store.delete(testItem))
        }

        func test_anthropicConstantMatchesD10() {
            XCTAssertEqual(KeychainItem.anthropic.service, "com.kingsrook.jarvis")
            XCTAssertEqual(KeychainItem.anthropic.account, "anthropic")
        }
    }
    ```
  </action>
  <verify>
    <automated>cd packages/Keychain &amp;&amp; swift test 2>&amp;1 | tail -20</automated>
  </verify>
  <acceptance_criteria>
    - `test ! -f packages/Keychain/Sources/Keychain/Placeholder.swift` (placeholder deleted)
    - `test ! -f packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift` (placeholder deleted)
    - `grep 'kSecAttrService as String: "com.kingsrook.jarvis"' packages/Keychain/Sources/Keychain/KeychainItem.swift` returns 1 match (SEC-01/D-10 constant verbatim)
    - `grep -c 'SecItemAdd\|SecItemCopyMatching\|SecItemUpdate\|SecItemDelete' packages/Keychain/Sources/Keychain/SystemKeychainStore.swift` returns ≥ 4
    - `grep 'kSecClassGenericPassword' packages/Keychain/Sources/Keychain/SystemKeychainStore.swift` returns ≥ 3 matches (set, get, delete)
    - `cd packages/Keychain && swift test` exits 0 with 4 passing tests (`test_setGetDeleteRoundTrip`, `test_setIdempotentOverwrite`, `test_deleteMissingDoesNotThrow`, `test_anthropicConstantMatchesD10`)
    - `xcodebuild test -scheme Keychain -destination 'platform=macOS' -derivedDataPath build` (from `Jarvis.xcodeproj` after Plan 01 loaded packages) exits 0 — OR, if xcodebuild doesn't yet route through the SPM package directly, `swift test` from the package directory is acceptable and the Xcode scheme-level test wiring is verified in Plan 05
  </acceptance_criteria>
  <done>Keychain package compiles under Swift 6 strict concurrency, round-trips the Anthropic constant via Security.framework, and the test suite exercises all four behaviors above.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Build Config package (LaunchSnapshot/PerTurnSnapshot split, AGENT-05 host validation, SEC-08 no-skip-allowlist, feature flags in PerTurnSnapshot)</name>
  <files>packages/Config/Sources/Config/LaunchSnapshot.swift, packages/Config/Sources/Config/PerTurnSnapshot.swift, packages/Config/Sources/Config/OllamaConfig.swift, packages/Config/Sources/Config/AppleScriptPolicy.swift, packages/Config/Sources/Config/ConfirmationPolicy.swift, packages/Config/Sources/Config/LoggingLaunchConfig.swift, packages/Config/Sources/Config/ProviderSelection.swift, packages/Config/Sources/Config/TTSConfig.swift, packages/Config/Sources/Config/STTConfig.swift, packages/Config/Sources/Config/FeatureFlags.swift, packages/Config/Sources/Config/ConfigError.swift, packages/Config/Sources/Config/ConfigLoader.swift, packages/Config/Sources/Config/ConfigStore.swift, packages/Config/Sources/Config/SchemaMigrator.swift, packages/Config/Resources/default-config.json, packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift, packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift, packages/Config/Tests/ConfigTests/ConfigSplitTests.swift, packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift, packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift, packages/Config/Tests/ConfigTests/ConfigLoaderTests.swift, packages/Config/Package.swift</files>
  <behavior>
    - Test: `OllamaConfig` decoded from `{"baseURL": "http://evil.com/"}` throws `ConfigError.invalidOllamaHost("evil.com")` (AGENT-05 adversarial)
    - Test: `OllamaConfig` decoded from `{"baseURL": "http://127.0.0.1:11434"}` succeeds (AGENT-05 happy path)
    - Test: `OllamaConfig` decoded from `{"baseURL": "http://localhost:11434"}` succeeds (AGENT-05 localhost name)
    - Test: `OllamaConfig` decoded from `{"baseURL": "http://[::1]:11434"}` succeeds (AGENT-05 IPv6 loopback)
    - Test: `FeatureFlags` field exists on `PerTurnSnapshot` but NOT on `LaunchSnapshot` (OBS-05)
    - Test: Encoding `LaunchSnapshot` and introspecting its JSON does NOT contain a `featureFlags` key (OBS-05 defense-in-depth)
    - Test: No `applescript.skipAllowlist` key exists in either schema — introspect `AppleScriptPolicy` declared properties via Mirror; assert no case-insensitive `skipAllowlist` / `skip_allowlist` / `allowlist` field (SEC-08)
    - Test: Encoded-then-decoded `LaunchSnapshot` does NOT contain an `apiKey` / `anthropicKey` / `key` field (SEC-01 defense-in-depth: API key must live in Keychain only)
    - Test: `SchemaMigrator.migrate(data, from: 1, to: 1)` is a pass-through (returns data unchanged)
    - Test: `SchemaMigrator.migrate(data, from: 2, to: 1)` throws `ConfigError.futureSchema(version: 2)` (forward-only)
    - Test: `SchemaMigrator.migrate(data, from: 0, to: 1)` throws `ConfigError.unknownSchemaVersion(0)` (no migrator for v0→v1)
    - Test: `ConfigLoader.loadSnapshots(from: bundled-default-config-url)` returns a valid (LaunchSnapshot, PerTurnSnapshot) pair
    - Test: `ConfigLoader.loadSnapshots(from: malformed-json-url)` throws `ConfigError.malformed(reason:)`
    - Delete placeholder file and placeholder test from Plan 01 Task 2
  </behavior>
  <read_first>
    - packages/Config/Package.swift (confirm target name, deps on Keychain + JarvisLogging)
    - packages/Config/Sources/Config/Placeholder.swift (to delete)
    - packages/Config/Tests/ConfigTests/PlaceholderTests.swift (to delete)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 5 lines 606-682 (LaunchSnapshot/PerTurnSnapshot shapes verbatim; OllamaConfig custom decoder)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 6 lines 685-747 (schema versioning + migration pattern)
    - .planning/phases/01-foundations/01-RESEARCH.md §Validation Architecture lines 1420-1452 (per-req test list)
    - .planning/phases/01-foundations/01-PATTERNS.md §H lines 96-113 (Config package file-by-file contracts)
    - .planning/phases/01-foundations/01-CONTEXT.md D-19 (NSAlert hard-block on malformed config; Plan 03 wires the alert — this plan throws ConfigError)
    - .planning/phases/01-foundations/01-CONTEXT.md D-20 (redact spec-minimum — relevant so Config doesn't leak keys via ConfigError messages)
  </read_first>
  <action>
    Delete `packages/Config/Sources/Config/Placeholder.swift` and `packages/Config/Tests/ConfigTests/PlaceholderTests.swift`.

    **Update `packages/Config/Package.swift`** to include the `Resources/default-config.json` resource:
    ```swift
    .target(
        name: "Config",
        dependencies: [
            .product(name: "Keychain", package: "Keychain"),
            .product(name: "JarvisLogging", package: "Logging"),
        ],
        resources: [.process("Resources")],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    ```

    **Create sub-models** (all `Sendable, Codable, Equatable` per PATTERNS §S-3):

    `packages/Config/Sources/Config/OllamaConfig.swift`:
    ```swift
    import Foundation

    public struct OllamaConfig: Sendable, Codable, Equatable {
        public let baseURL: URL

        public init(baseURL: URL) throws {
            try Self.validateHost(baseURL)
            self.baseURL = baseURL
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let urlString = try container.decode(String.self, forKey: .baseURL)
            guard let url = URL(string: urlString) else {
                throw ConfigError.malformed(reason: "ollama.baseURL is not a valid URL: \(urlString)")
            }
            try Self.validateHost(url)
            self.baseURL = url
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseURL.absoluteString, forKey: .baseURL)
        }

        private enum CodingKeys: String, CodingKey { case baseURL }

        /// AGENT-05: only 127.0.0.1, localhost, ::1 permitted.
        private static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

        private static func validateHost(_ url: URL) throws {
            let host = url.host ?? ""
            guard allowedHosts.contains(host.lowercased()) else {
                throw ConfigError.invalidOllamaHost(host)
            }
        }
    }
    ```

    `packages/Config/Sources/Config/AppleScriptPolicy.swift`:
    ```swift
    import Foundation

    public struct AppleScriptPolicy: Sendable, Codable, Equatable {
        public let confirmationRequired: Bool
        public init(confirmationRequired: Bool = true) {
            self.confirmationRequired = confirmationRequired
        }
        // SEC-08: No skipAllowlist / allowlist / regex-bypass field. Every AppleScript requires confirmation.
    }
    ```

    `packages/Config/Sources/Config/ConfirmationPolicy.swift`:
    ```swift
    import Foundation

    public struct ConfirmationPolicy: Sendable, Codable, Equatable {
        public let timeoutSeconds: Int
        public init(timeoutSeconds: Int = 60) {
            self.timeoutSeconds = timeoutSeconds
        }
    }
    ```

    `packages/Config/Sources/Config/LoggingLaunchConfig.swift`:
    ```swift
    import Foundation

    public struct LoggingLaunchConfig: Sendable, Codable, Equatable {
        public let fileLevel: String   // "debug"|"info"|"notice"|"warning"|"error"
        public let osLogLevel: String
        public init(fileLevel: String = "info", osLogLevel: String = "info") {
            self.fileLevel = fileLevel
            self.osLogLevel = osLogLevel
        }
    }
    ```

    `packages/Config/Sources/Config/ProviderSelection.swift`:
    ```swift
    import Foundation

    public enum ProviderSelection: String, Sendable, Codable, Equatable {
        case anthropic
        case ollama
    }
    ```

    `packages/Config/Sources/Config/TTSConfig.swift`:
    ```swift
    import Foundation

    public struct TTSConfig: Sendable, Codable, Equatable {
        public let tier: String   // "tier1" (AVSpeechSynthesizer) | "tier2" (Orpheus). P6 interprets.
        public init(tier: String = "tier1") { self.tier = tier }
    }
    ```

    `packages/Config/Sources/Config/STTConfig.swift`:
    ```swift
    import Foundation

    public struct STTConfig: Sendable, Codable, Equatable {
        public let whisperKitFallback: Bool
        public init(whisperKitFallback: Bool = false) {
            self.whisperKitFallback = whisperKitFallback
        }
    }
    ```

    `packages/Config/Sources/Config/FeatureFlags.swift`:
    ```swift
    import Foundation

    /// OBS-05 / PATTERNS §Pattern 2: feature flags live in PerTurnSnapshot ONLY.
    /// Security-affecting flags DO NOT EXIST (SEC-08 forbids a skip-allowlist).
    public struct FeatureFlags: Sendable, Codable, Equatable {
        private let flags: [String: Bool]

        public init(_ flags: [String: Bool] = [:]) {
            self.flags = flags
        }

        public func isEnabled(_ key: String) -> Bool {
            flags[key] ?? false
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.flags = try container.decode([String: Bool].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(flags)
        }
    }
    ```

    `packages/Config/Sources/Config/ConfigError.swift`:
    ```swift
    import Foundation

    public enum ConfigError: Error, Sendable, Equatable {
        case malformed(reason: String)
        case unknownSchemaVersion(Int)
        case futureSchema(version: Int)
        case invalidOllamaHost(String)
    }
    ```

    **Create `LaunchSnapshot.swift`** — security keys ONLY (per SEC-05):
    ```swift
    import Foundation

    public struct LaunchSnapshot: Sendable, Codable, Equatable {
        public let schemaVersion: Int
        public let ollama: OllamaConfig
        public let applescript: AppleScriptPolicy
        public let toolBlocklist: [String]
        public let confirmationPolicy: ConfirmationPolicy
        public let logging: LoggingLaunchConfig
        // DO NOT add: apiKey (SEC-01 — Keychain only), featureFlags (OBS-05 — PerTurn only).
    }
    ```

    **Create `PerTurnSnapshot.swift`** — non-security keys (per SEC-05), feature flags live here (per OBS-05):
    ```swift
    import Foundation

    public struct PerTurnSnapshot: Sendable, Codable, Equatable {
        public let schemaVersion: Int
        public let provider: ProviderSelection
        public let tts: TTSConfig
        public let stt: STTConfig
        public let featureFlags: FeatureFlags
        // DO NOT add: ollama host, applescript policy, toolBlocklist, confirmationPolicy (all Launch-pinned per SEC-05).
    }
    ```

    **Create `SchemaMigrator.swift`** — copy verbatim from RESEARCH §Question 6 lines 716-740:
    ```swift
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
    ```

    **Create `ConfigLoader.swift`** — per RESEARCH Q5 lines 650-667:
    ```swift
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
    ```

    **Create `ConfigStore.swift`** — minimal actor skeleton per RESEARCH Q5 lines 677-680 (full file-watcher restart-banner logic is a Plan 03 wiring concern; this plan ships the actor API):
    ```swift
    import Foundation

    /// Holds the frozen LaunchSnapshot + publishes PerTurnSnapshot updates.
    /// File-watcher integration (restart-required banner) is installed by AppDelegate (Plan 03).
    public actor ConfigStore {
        public let launch: LaunchSnapshot
        private var current: PerTurnSnapshot
        private var subscribers: [AsyncStream<PerTurnSnapshot>.Continuation] = []

        public init(launch: LaunchSnapshot, initial: PerTurnSnapshot) {
            self.launch = launch
            self.current = initial
        }

        public func perTurn() -> PerTurnSnapshot {
            current
        }

        public func updatePerTurn(_ next: PerTurnSnapshot) {
            current = next
            for s in subscribers { s.yield(next) }
        }

        public func stream() -> AsyncStream<PerTurnSnapshot> {
            AsyncStream { continuation in
                self.subscribers.append(continuation)
                continuation.yield(current)
            }
        }
    }
    ```

    **Create `packages/Config/Resources/default-config.json`** — copy verbatim from RESEARCH §Question 6 lines 691-711:
    ```json
    {
      "schemaVersion": 1,
      "ollama": {
        "baseURL": "http://127.0.0.1:11434"
      },
      "applescript": {
        "confirmationRequired": true
      },
      "provider": "anthropic",
      "tts": { "tier": "tier1" },
      "stt": { "whisperKitFallback": false },
      "featureFlags": {
        "orpheusTTSEnabled": false,
        "whisperKitSTTEnabled": false
      },
      "toolBlocklist": [],
      "confirmationPolicy": { "timeoutSeconds": 60 },
      "logging": { "fileLevel": "info", "osLogLevel": "info" }
    }
    ```

    **Create tests** — one file per requirement angle per RESEARCH §Validation Architecture lines 1434-1452:

    `LaunchSnapshotTests.swift`:
    ```swift
    import XCTest
    @testable import Config

    final class LaunchSnapshotTests: XCTestCase {
        func test_ollamaBaseURLAcceptsLocalhostAndLoopback() throws {
            for host in ["127.0.0.1", "localhost", "::1"] {
                let urlString = host == "::1" ? "http://[::1]:11434" : "http://\(host):11434"
                let json = """
                {"schemaVersion":1,"ollama":{"baseURL":"\(urlString)"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
                """.data(using: .utf8)!
                XCTAssertNoThrow(try JSONDecoder().decode(LaunchSnapshot.self, from: json),
                                 "host \(host) should be accepted")
            }
        }

        func test_ollamaBaseURLMustBeLocalhost() {
            let json = """
            {"schemaVersion":1,"ollama":{"baseURL":"http://evil.com/"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
            """.data(using: .utf8)!
            XCTAssertThrowsError(try JSONDecoder().decode(LaunchSnapshot.self, from: json)) { error in
                // Decoder wraps invalidOllamaHost inside DecodingError.dataCorrupted.
                // We just assert that decoding fails; the exact wrapping is accepted.
                XCTAssertTrue(
                    "\(error)".contains("invalidOllamaHost") || "\(error)".contains("evil.com"),
                    "Expected invalidOllamaHost error, got: \(error)"
                )
            }
        }

        func test_featureFlagsNotInLaunchSnapshot() {
            // Introspect type: assert no stored property named 'featureFlags' exists.
            let mirror = Mirror(reflecting: try! buildFixtureLaunchSnapshot())
            let names = mirror.children.compactMap { $0.label }
            XCTAssertFalse(names.contains("featureFlags"),
                           "featureFlags must NOT live in LaunchSnapshot (OBS-05). Found: \(names)")
        }

        private func buildFixtureLaunchSnapshot() throws -> LaunchSnapshot {
            let json = """
            {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(LaunchSnapshot.self, from: json)
        }
    }
    ```

    `PerTurnSnapshotTests.swift`:
    ```swift
    import XCTest
    @testable import Config

    final class PerTurnSnapshotTests: XCTestCase {
        func test_featureFlagsArePresentInPerTurnSnapshot() throws {
            let json = """
            {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{"orpheusTTSEnabled":true}}
            """.data(using: .utf8)!
            let snapshot = try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
            XCTAssertTrue(snapshot.featureFlags.isEnabled("orpheusTTSEnabled"))
            XCTAssertFalse(snapshot.featureFlags.isEnabled("nonexistent"))
        }

        func test_featureFlagAppliesNextSubmit() async throws {
            // Mock orchestrator: reads perTurn from ConfigStore on each 'submit'.
            let launch = try sampleLaunch()
            let initial = try sampleEmptyFlags()
            let store = ConfigStore(launch: launch, initial: initial)
            XCTAssertFalse(await store.perTurn().featureFlags.isEnabled("orpheusTTSEnabled"))

            let next = try samplePerTurn(flags: ["orpheusTTSEnabled": true])
            await store.updatePerTurn(next)

            XCTAssertTrue(await store.perTurn().featureFlags.isEnabled("orpheusTTSEnabled"))
        }

        // Fixture helpers
        private func sampleLaunch() throws -> LaunchSnapshot { /* decode from default-config.json */ try ConfigTestFixtures.launch() }
        private func sampleEmptyFlags() throws -> PerTurnSnapshot { try ConfigTestFixtures.perTurn(flags: [:]) }
        private func samplePerTurn(flags: [String: Bool]) throws -> PerTurnSnapshot { try ConfigTestFixtures.perTurn(flags: flags) }
    }

    enum ConfigTestFixtures {
        static func launch() throws -> LaunchSnapshot {
            let json = """
            {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(LaunchSnapshot.self, from: json)
        }
        static func perTurn(flags: [String: Bool]) throws -> PerTurnSnapshot {
            let flagsJSON = flags.isEmpty ? "{}" : String(data: try JSONEncoder().encode(flags), encoding: .utf8)!
            let json = """
            {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":\(flagsJSON)}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
        }
    }
    ```

    `ConfigSplitTests.swift` — SEC-05 + SEC-08:
    ```swift
    import XCTest
    @testable import Config

    final class ConfigSplitTests: XCTestCase {
        func test_securityKeysInLaunchOnly() throws {
            let launch = try ConfigTestFixtures.launch()
            let mirror = Mirror(reflecting: launch)
            let names = Set(mirror.children.compactMap { $0.label })
            for key in ["ollama", "applescript", "toolBlocklist", "confirmationPolicy", "logging"] {
                XCTAssertTrue(names.contains(key), "LaunchSnapshot missing security key: \(key)")
            }
        }

        func test_nonSecurityKeysInPerTurnOnly() throws {
            let perTurn = try ConfigTestFixtures.perTurn(flags: [:])
            let mirror = Mirror(reflecting: perTurn)
            let names = Set(mirror.children.compactMap { $0.label })
            for key in ["provider", "tts", "stt", "featureFlags"] {
                XCTAssertTrue(names.contains(key), "PerTurnSnapshot missing key: \(key)")
            }
        }

        func test_noSkipAllowlistKey() {
            // SEC-08: reflect over AppleScriptPolicy and assert no allowlist-like field exists.
            let policy = AppleScriptPolicy(confirmationRequired: true)
            let mirror = Mirror(reflecting: policy)
            let names = mirror.children.compactMap { $0.label?.lowercased() ?? "" }
            for forbidden in ["skipallowlist", "skip_allowlist", "allowlist", "bypass", "regex"] {
                XCTAssertFalse(names.contains(forbidden),
                               "SEC-08 violation: AppleScriptPolicy has forbidden field '\(forbidden)'")
            }
        }
    }
    ```

    `ApiKeyNotInConfigTests.swift` — SEC-01 defense-in-depth:
    ```swift
    import XCTest
    @testable import Config

    final class ApiKeyNotInConfigTests: XCTestCase {
        func test_apiKeyNotInConfigJSON() throws {
            let launch = try ConfigTestFixtures.launch()
            let encoded = try JSONEncoder().encode(launch)
            let json = String(data: encoded, encoding: .utf8)!.lowercased()
            for forbidden in ["apikey", "\"api_key\"", "anthropic_key", "\"key\"", "sk-ant-"] {
                XCTAssertFalse(json.contains(forbidden),
                               "LaunchSnapshot JSON encoding contains forbidden field '\(forbidden)' — SEC-01 violation")
            }
        }
    }
    ```

    `SchemaMigratorTests.swift`:
    ```swift
    import XCTest
    @testable import Config

    final class SchemaMigratorTests: XCTestCase {
        func test_currentVersionIsOne() {
            XCTAssertEqual(SchemaMigrator.currentVersion, 1)
        }

        func test_v1ToV1IsPassThrough() throws {
            let data = Data("{\"schemaVersion\":1}".utf8)
            let result = try SchemaMigrator.migrate(data, from: 1, to: 1)
            XCTAssertEqual(result, data)
        }

        func test_futureSchemaThrows() {
            let data = Data("{\"schemaVersion\":2}".utf8)
            XCTAssertThrowsError(try SchemaMigrator.migrate(data, from: 2, to: 1)) { error in
                XCTAssertEqual(error as? ConfigError, .futureSchema(version: 2))
            }
        }

        func test_unknownV0ToV1Throws() {
            let data = Data("{\"schemaVersion\":0}".utf8)
            XCTAssertThrowsError(try SchemaMigrator.migrate(data, from: 0, to: 1)) { error in
                XCTAssertEqual(error as? ConfigError, .unknownSchemaVersion(0))
            }
        }
    }
    ```

    `ConfigLoaderTests.swift`:
    ```swift
    import XCTest
    @testable import Config

    final class ConfigLoaderTests: XCTestCase {
        func test_loadDefaultConfigFromBundle() throws {
            guard let url = ConfigLoader.bundledDefaultConfigURL() else {
                XCTFail("Bundled default-config.json missing"); return
            }
            let (launch, perTurn) = try ConfigLoader.loadSnapshots(from: url)
            XCTAssertEqual(launch.schemaVersion, 1)
            XCTAssertEqual(perTurn.schemaVersion, 1)
            XCTAssertEqual(launch.ollama.baseURL.host, "127.0.0.1")
            XCTAssertEqual(perTurn.provider, .anthropic)
        }

        func test_malformedConfigThrowsMalformed() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
            try Data("{not-valid-json".utf8).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            XCTAssertThrowsError(try ConfigLoader.loadSnapshots(from: tmp)) { error in
                if case .malformed = error as? ConfigError {
                    // OK
                } else {
                    XCTFail("Expected ConfigError.malformed, got: \(error)")
                }
            }
        }
    }
    ```
  </action>
  <verify>
    <automated>cd packages/Config &amp;&amp; swift test 2>&amp;1 | tail -30</automated>
  </verify>
  <acceptance_criteria>
    - `test ! -f packages/Config/Sources/Config/Placeholder.swift` (placeholder deleted)
    - `test ! -f packages/Config/Tests/ConfigTests/PlaceholderTests.swift` (placeholder deleted)
    - `grep -c 'invalidOllamaHost' packages/Config/Sources/Config/OllamaConfig.swift` returns ≥ 2 (declared + thrown)
    - `grep 'case invalidOllamaHost(String)' packages/Config/Sources/Config/ConfigError.swift` returns 1 match
    - `grep -c '"127.0.0.1", "localhost", "::1"' packages/Config/Sources/Config/OllamaConfig.swift` returns 1 match (set literal)
    - `grep 'featureFlags' packages/Config/Sources/Config/LaunchSnapshot.swift` returns NO matches (OBS-05 defense: featureFlags must not appear in LaunchSnapshot source)
    - `grep 'featureFlags' packages/Config/Sources/Config/PerTurnSnapshot.swift` returns ≥ 1 match (PerTurn owns feature flags)
    - `grep -i 'skipallowlist\|skip_allowlist\|allowlist\|regex' packages/Config/Sources/Config/AppleScriptPolicy.swift` returns NO matches (SEC-08)
    - `grep -i 'apikey\|api_key\|anthropic_key' packages/Config/Sources/Config/LaunchSnapshot.swift packages/Config/Sources/Config/PerTurnSnapshot.swift` returns NO matches (SEC-01 defense-in-depth)
    - `test -f packages/Config/Resources/default-config.json && jq -r .schemaVersion packages/Config/Resources/default-config.json` returns `1`
    - `cd packages/Config && swift test` exits 0 with ALL tests passing: `test_ollamaBaseURLMustBeLocalhost`, `test_ollamaBaseURLAcceptsLocalhostAndLoopback`, `test_featureFlagsNotInLaunchSnapshot`, `test_featureFlagsArePresentInPerTurnSnapshot`, `test_featureFlagAppliesNextSubmit`, `test_securityKeysInLaunchOnly`, `test_nonSecurityKeysInPerTurnOnly`, `test_noSkipAllowlistKey`, `test_apiKeyNotInConfigJSON`, `test_currentVersionIsOne`, `test_v1ToV1IsPassThrough`, `test_futureSchemaThrows`, `test_unknownV0ToV1Throws`, `test_loadDefaultConfigFromBundle`, `test_malformedConfigThrowsMalformed`
  </acceptance_criteria>
  <done>Config package compiles under Swift 6 strict, `OllamaConfig` decoder rejects non-localhost hosts at decode time (AGENT-05), feature flags are fenced into `PerTurnSnapshot` (OBS-05), no skip-allowlist field exists anywhere (SEC-08), and the SEC-05 split is enforced by reflection tests.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Build Logging package (four-channel swift-log with MultiplexLogHandler, FileLogHandler with lazy midnight rotation + retain-7, OSLogHandler, Redact with 5 patterns, tests)</name>
  <files>packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift, packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift, packages/Logging/Sources/JarvisLogging/FileLogHandler.swift, packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift, packages/Logging/Sources/JarvisLogging/OSLogHandler.swift, packages/Logging/Sources/JarvisLogging/Redact.swift, packages/Logging/Sources/JarvisLogging/LogPaths.swift, packages/Logging/Sources/JarvisLogging/DateProvider.swift, packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift, packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift, packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift</files>
  <behavior>
    - Test: `Redact.apply("Authorization: Bearer abc123xyz789abc")` contains `<redacted>` and NOT `abc123xyz789abc`
    - Test: `Redact.apply("my key is sk-ant-abc123def456ghi789jkl")` contains `<redacted>` and NOT the full key suffix
    - Test: `Redact.apply("sk-abc123def456ghi789jklmnopqrstuv")` (OpenAI-style) is masked
    - Test: `Redact.apply("AKIAIOSFODNN7EXAMPLE")` is masked
    - Test: `Redact.apply("ghp_abcdef1234567890ABCDEF1234567890abcdef")` (36 chars) is masked
    - Test: `Redact.apply("hello world, just a normal message")` is unchanged
    - Test: `Redact.apply("sk-ant-xxx")` is matched by the Anthropic branch (not the OpenAI one) — ordering test
    - Test: `FileLogHandler` with `TestDateProvider` writes to `{baseName}.{date}.log`; advancing the date provider past midnight rotates to a new file on next append
    - Test: After rotation, a 10-file history → retain-7 deletes the 3 oldest; check 7 files remain
    - Test: `JarvisLogHandlerFactory.bootstrap()` installs the factory; `Logger(label: "agent")` + `.info("hello")` produces a log line in BOTH the file at `~/Library/Logs/Jarvis/agent.log` (or temp dir in tests) AND via the OSLogHandler path (verifiable via a spy-logger-fake in tests)
    - Test: The four channels `agent, tools, ui, system` each produce their own file
    - Delete placeholder file and placeholder test from Plan 01 Task 2
  </behavior>
  <read_first>
    - packages/Logging/Package.swift (confirm target named `JarvisLogging`, depends on swift-log 1.5.3+)
    - packages/Logging/Sources/JarvisLogging/Placeholder.swift (to delete — note path uses `JarvisLogging` per Plan 01 naming)
    - packages/Logging/Tests/JarvisLoggingTests/PlaceholderTests.swift (to delete)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 3 lines 376-526 (full Redact + FileLogHandler shapes verbatim)
    - .planning/phases/01-foundations/01-PATTERNS.md §I lines 116-130 (Logging file classifications)
    - .planning/phases/01-foundations/01-PATTERNS.md §S-4 lines 211-216 (redact single call site discipline) and §S-8 lines 244-248 (one-bootstrap discipline)
    - .planning/phases/01-foundations/01-CONTEXT.md D-17 (two handlers simultaneously; os.Logger subsystem=com.kingsrook.jarvis, category=<label>), D-18 (daily midnight rotate + retain-7), D-20 (redact spec minimum — 5 patterns EXACTLY, nothing more)
  </read_first>
  <action>
    **Note on path:** Plan 01 established the library target as `JarvisLogging` (to avoid collision with swift-log's `Logging` module). All source paths use `packages/Logging/Sources/JarvisLogging/...`. The **public module name** consumers import is `JarvisLogging`.

    Delete `packages/Logging/Sources/JarvisLogging/Placeholder.swift` and `packages/Logging/Tests/JarvisLoggingTests/PlaceholderTests.swift` (delete whichever placeholder path Plan 01 Task 2 actually created — could be either `Placeholder.swift` or a differently-named stub; adjust accordingly).

    **`packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift`**:
    ```swift
    import Foundation

    public enum JarvisLogChannel: String, Sendable, CaseIterable {
        case agent
        case tools
        case ui
        case system
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/DateProvider.swift`** (for FileRotatingWriter testability):
    ```swift
    import Foundation

    public protocol DateProvider: Sendable {
        func now() -> Date
    }

    public struct SystemDateProvider: DateProvider {
        public init() {}
        public func now() -> Date { Date() }
    }

    /// For tests: advance `currentDate` manually to simulate time passage.
    public final class TestDateProvider: DateProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var currentDate: Date
        public init(startingAt: Date) { self.currentDate = startingAt }
        public func now() -> Date { lock.lock(); defer { lock.unlock() }; return currentDate }
        public func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            currentDate = currentDate.addingTimeInterval(seconds)
        }
        public func set(_ date: Date) {
            lock.lock(); defer { lock.unlock() }
            currentDate = date
        }
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/LogPaths.swift`**:
    ```swift
    import Foundation

    public enum LogPaths {
        /// ~/Library/Logs/Jarvis/
        public static var channelDirectory: URL {
            let fm = FileManager.default
            let libraryURL: URL
            do {
                libraryURL = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            } catch {
                libraryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library"))
            }
            let dir = libraryURL.appendingPathComponent("Logs/Jarvis", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/Redact.swift`** — EXACTLY 5 patterns per D-20. Do NOT add more (over-redaction hurts P4+ debugging and conflicts with OBS-02 nothing-masked-bytes for replay log):
    ```swift
    import Foundation

    public enum Redact {
        /// Compiled once. Alternation branches ordered by specificity so sk-ant- matches
        /// branch 1 before sk- (OpenAI) branch 3.
        ///   1. Anthropic sk-ant-<20+ tokens>
        ///   2. Authorization: Bearer <token>  (case-insensitive)
        ///   3. OpenAI sk-<20+ tokens>
        ///   4. AKIA<16 uppercase alphanumerics>
        ///   5. ghp_<36 alphanumerics>
        private static let pattern: NSRegularExpression = {
            let raw = #"(sk-ant-[A-Za-z0-9_\-]{20,})|((?i:Authorization:\s*Bearer)\s+[A-Za-z0-9_\-\.=]+)|(\bsk-[A-Za-z0-9_\-]{20,})|(AKIA[0-9A-Z]{16})|(ghp_[A-Za-z0-9]{36})"#
            return try! NSRegularExpression(pattern: raw)
        }()

        public static func apply(_ s: String) -> String {
            let ns = s as NSString
            return pattern.stringByReplacingMatches(
                in: s,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "<redacted>"
            )
        }
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift`** — lazy midnight rotation, retain-7, serial DispatchQueue:
    ```swift
    import Foundation

    /// Serial writer with lazy rotation at local-calendar day boundary.
    /// Per D-18: rotate daily at local midnight; retain last 7 days.
    /// Per RESEARCH Q3 line 491: lazy on first post-midnight write (no timer thread).
    final class FileRotatingWriter: @unchecked Sendable {
        private let directory: URL
        private let baseName: String
        private let retentionDays: Int
        private let dateProvider: any DateProvider
        private let queue: DispatchQueue
        private var currentDayString: String?
        private var currentHandle: FileHandle?

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone.current
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        init(directory: URL, baseName: String, retentionDays: Int, dateProvider: any DateProvider) {
            self.directory = directory
            self.baseName = baseName
            self.retentionDays = retentionDays
            self.dateProvider = dateProvider
            self.queue = DispatchQueue(label: "com.kingsrook.jarvis.filelog.\(baseName)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func append(_ line: String) {
            queue.async {
                self.rotateIfNeeded()
                guard let handle = self.currentHandle,
                      let data = line.data(using: .utf8) else { return }
                try? handle.write(contentsOf: data)
            }
        }

        private func rotateIfNeeded() {
            let today = dateFormatter.string(from: dateProvider.now())
            if today == currentDayString { return }
            try? currentHandle?.close()
            currentHandle = nil

            let fileURL = directory.appendingPathComponent("\(baseName).\(today).log")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            currentHandle = try? FileHandle(forWritingTo: fileURL)
            try? currentHandle?.seekToEnd()
            currentDayString = today

            gcOldFiles(now: dateProvider.now())
        }

        /// Delete files older than `retentionDays` days.
        private func gcOldFiles(now: Date) {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retentionDays, to: now) ?? now

            for url in contents where url.lastPathComponent.hasPrefix("\(baseName).") && url.lastPathComponent.hasSuffix(".log") {
                let components = url.lastPathComponent
                    .replacingOccurrences(of: "\(baseName).", with: "")
                    .replacingOccurrences(of: ".log", with: "")
                if let fileDate = dateFormatter.date(from: components), fileDate < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        deinit {
            try? currentHandle?.close()
        }
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/FileLogHandler.swift`** — the SINGLE `Redact.apply` call site per S-4:
    ```swift
    import Foundation
    import Logging  // swift-log

    struct FileLogHandler: LogHandler {
        let label: String
        let directory: URL
        let dateProvider: any DateProvider

        var logLevel: Logger.Level = .info
        var metadata: Logger.Metadata = [:]
        var metadataProvider: Logger.MetadataProvider?

        private let writer: FileRotatingWriter

        init(label: String, directory: URL, dateProvider: any DateProvider) {
            self.label = label
            self.directory = directory
            self.dateProvider = dateProvider
            self.writer = FileRotatingWriter(
                directory: directory,
                baseName: label,
                retentionDays: 7,
                dateProvider: dateProvider
            )
        }

        func log(level: Logger.Level, message: Logger.Message,
                 metadata: Logger.Metadata?, source: String,
                 file: String, function: String, line: UInt) {
            let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
            let metaStr = merged.isEmpty ? "" : " " + merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            let iso = ISO8601DateFormatter.jarvisShared.string(from: dateProvider.now())
            let raw = "\(iso) \(level.rawValue.uppercased()) [\(label)] \(message)\(metaStr)\n"
            let redacted = Redact.apply(raw)   // S-4: single call site
            writer.append(redacted)
        }

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
    }

    extension ISO8601DateFormatter {
        static let jarvisShared: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/OSLogHandler.swift`** — NO `Redact.apply` per S-4 + RESEARCH Q3 line 493 (os.Logger handles `%{private}@` at system layer; double-redact is pointless):
    ```swift
    import Foundation
    import Logging   // swift-log
    import os        // Apple os.Logger

    struct OSLogHandler: LogHandler {
        let subsystem: String
        let category: String
        private let logger: os.Logger

        var logLevel: Logger.Level = .info
        var metadata: Logger.Metadata = [:]
        var metadataProvider: Logger.MetadataProvider?

        init(subsystem: String, category: String, label: String) {
            self.subsystem = subsystem
            self.category = category
            self.logger = os.Logger(subsystem: subsystem, category: category)
        }

        func log(level: Logger.Level, message: Logger.Message,
                 metadata: Logger.Metadata?, source: String,
                 file: String, function: String, line: UInt) {
            let osLevel: OSLogType = switch level {
            case .trace, .debug: .debug
            case .info, .notice: .info
            case .warning: .default
            case .error: .error
            case .critical: .fault
            }
            // NOTE: no Redact.apply — os.Logger handles %{private}@ at system layer.
            // Discipline: callers must redact untrusted input BEFORE passing to Logger.
            logger.log(level: osLevel, "\(message, privacy: .public)")
        }

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
    }
    ```

    **`packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift`** — one-bootstrap discipline per S-8:
    ```swift
    import Foundation
    import Logging   // swift-log

    public enum JarvisLogHandlerFactory {
        /// The subsystem string baked into OSLogHandler — matches CLAUDE.md §os.Logger identity.
        public static let subsystem = "com.kingsrook.jarvis"

        /// Factory consumed by swift-log's LoggingSystem.bootstrap.
        public static func make(label: String) -> LogHandler {
            let file = FileLogHandler(
                label: label,
                directory: LogPaths.channelDirectory,
                dateProvider: SystemDateProvider()
            )
            let os = OSLogHandler(subsystem: subsystem, category: label, label: label)
            return MultiplexLogHandler([file, os])
        }

        /// Call exactly ONCE at `AppDelegate.applicationWillFinishLaunching`.
        /// Per S-8: anti-pattern to call from package init or test setUp.
        public static func bootstrap() {
            LoggingSystem.bootstrap(Self.make)
        }
    }
    ```

    **Create tests** in `packages/Logging/Tests/JarvisLoggingTests/`:

    `RedactTests.swift` — 5-pattern coverage per RESEARCH §Validation line 1444:
    ```swift
    import XCTest
    @testable import JarvisLogging

    final class RedactTests: XCTestCase {
        func test_anthropicKey() {
            let input = "my key is sk-ant-api03-abc123XYZ-0987654321"
            let out = Redact.apply(input)
            XCTAssertTrue(out.contains("<redacted>"))
            XCTAssertFalse(out.contains("sk-ant-api03-abc123XYZ-0987654321"))
        }

        func test_openAIKey() {
            let input = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
            let out = Redact.apply(input)
            XCTAssertTrue(out.contains("<redacted>"))
        }

        func test_authorizationBearer() {
            let input = "Authorization: Bearer abcdefghij1234567890"
            let out = Redact.apply(input)
            XCTAssertTrue(out.contains("<redacted>"))
            XCTAssertFalse(out.contains("abcdefghij1234567890"))
        }

        func test_awsAccessKey() {
            let input = "AKIAIOSFODNN7EXAMPLE"
            let out = Redact.apply(input)
            XCTAssertTrue(out.contains("<redacted>"))
            XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
        }

        func test_githubToken() {
            let input = "ghp_abcdef1234567890ABCDEF1234567890abcdef"
            let out = Redact.apply(input)
            XCTAssertTrue(out.contains("<redacted>"))
        }

        func test_plainTextUnchanged() {
            let input = "Hello, this is a totally normal log line with no secrets."
            XCTAssertEqual(Redact.apply(input), input)
        }

        func test_anthropicBranchBeatsOpenAIBranch() {
            // sk-ant-... should match pattern 1 (Anthropic), not pattern 3 (OpenAI sk-).
            let input = "sk-ant-api03-abcdef1234567890abcdef"
            let out = Redact.apply(input)
            // Both branches redact, but we check that the ENTIRE sk-ant- prefix is captured.
            // A regression where branch 3 matched first would leave "sk-ant-" prefix visible.
            XCTAssertFalse(out.contains("sk-ant-"), "Anthropic branch should consume the full prefix")
        }
    }
    ```

    `FileLogHandlerTests.swift` — rotation + retain-7 per RESEARCH §Validation line 1445:
    ```swift
    import XCTest
    import Logging
    @testable import JarvisLogging

    final class FileLogHandlerTests: XCTestCase {
        private var tempDir: URL!

        override func setUp() {
            super.setUp()
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("jarvis-logtest-\(UUID())", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
            super.tearDown()
        }

        func test_rotatesAtDayBoundary() throws {
            let startDate = Date(timeIntervalSince1970: 1_800_000_000) // deterministic past date
            let dp = TestDateProvider(startingAt: startDate)
            var handler = FileLogHandler(label: "rotate-test", directory: tempDir, dateProvider: dp)

            handler.log(level: .info, message: "day one",
                        metadata: nil, source: "", file: "", function: "", line: 0)
            usleep(50_000) // let the serial queue drain

            // Advance 26 hours → crosses at least one midnight boundary.
            dp.advance(by: 26 * 3600)

            handler.log(level: .info, message: "day two",
                        metadata: nil, source: "", file: "", function: "", line: 0)
            usleep(50_000)

            let files = try FileManager.default.contentsOfDirectory(
                at: tempDir, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("rotate-test.") }
            XCTAssertGreaterThanOrEqual(files.count, 2, "Should have rotated to a new file")
        }

        func test_deletesBeyondSeven() throws {
            // Seed 10 files with past dates, then write one log line → GC should leave ≤7.
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let fm = FileManager.default
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"

            for i in 0..<10 {
                let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -i, to: now)!
                let path = tempDir.appendingPathComponent("retain-test.\(df.string(from: date)).log")
                try "seed\n".data(using: .utf8)!.write(to: path)
            }

            let dp = TestDateProvider(startingAt: now)
            let handler = FileLogHandler(label: "retain-test", directory: tempDir, dateProvider: dp)
            handler.log(level: .info, message: "trigger-gc",
                        metadata: nil, source: "", file: "", function: "", line: 0)
            usleep(100_000) // let GC run

            let remaining = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("retain-test.") }
            XCTAssertLessThanOrEqual(remaining.count, 8, "retain-7 + today means ≤8 files; got \(remaining.count)")
            // Stricter: the oldest file (10 days ago) should be deleted.
            let oldest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -9, to: now)!
            let oldestPath = tempDir.appendingPathComponent("retain-test.\(df.string(from: oldest)).log")
            XCTAssertFalse(fm.fileExists(atPath: oldestPath.path), "9-day-old file should have been GC'd")
        }
    }
    ```

    `LoggingTests.swift` — four-channel multiplex + bootstrap:
    ```swift
    import XCTest
    import Logging
    @testable import JarvisLogging

    final class LoggingTests: XCTestCase {
        func test_fourChannelsAreDefined() {
            let expected: Set<String> = ["agent", "tools", "ui", "system"]
            let actual = Set(JarvisLogChannel.allCases.map(\.rawValue))
            XCTAssertEqual(actual, expected)
        }

        func test_factoryProducesMultiplexLogHandler() {
            let handler = JarvisLogHandlerFactory.make(label: "agent")
            // MultiplexLogHandler is a struct; cast-check via type dump.
            XCTAssertEqual(String(describing: type(of: handler)), "MultiplexLogHandler")
        }

        func test_bootstrapRunsWithoutThrowing() {
            // This test is intentionally NOT exercising LoggingSystem.bootstrap multiple times —
            // swift-log allows bootstrap exactly once per process. In test runs, calling
            // bootstrap is unsafe across tests. We instead verify the factory is callable.
            XCTAssertNoThrow(JarvisLogHandlerFactory.make(label: "system"))
        }

        func test_subsystemConstant() {
            XCTAssertEqual(JarvisLogHandlerFactory.subsystem, "com.kingsrook.jarvis")
        }
    }
    ```

    Note on `test_bootstrapRunsWithoutThrowing`: `LoggingSystem.bootstrap` is process-global per S-8; repeatedly invoking it in tests breaks subsequent tests. We verify the factory mechanic only. A full multiplex-to-file-and-os assertion is deferred to an integration test in Plan 03 where `AppDelegate.applicationWillFinishLaunching` exercises the real bootstrap path.
  </action>
  <verify>
    <automated>cd packages/Logging &amp;&amp; swift test 2>&amp;1 | tail -25</automated>
  </verify>
  <acceptance_criteria>
    - `test ! -f packages/Logging/Sources/JarvisLogging/Placeholder.swift` (placeholder deleted — or whichever name Plan 01 used)
    - `grep -c 'case agent\|case tools\|case ui\|case system' packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` returns ≥ 4
    - `grep 'com.kingsrook.jarvis' packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift` returns ≥ 1 match (subsystem constant)
    - `grep 'MultiplexLogHandler' packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift` returns 1 match
    - `grep 'Redact.apply' packages/Logging/Sources/JarvisLogging/FileLogHandler.swift` returns 1 match (single call site per S-4)
    - `grep 'Redact.apply' packages/Logging/Sources/JarvisLogging/OSLogHandler.swift` returns NO matches (S-4: OSLogHandler does NOT redact)
    - `grep -c 'sk-ant-\|Authorization\|sk-\|AKIA\|ghp_' packages/Logging/Sources/JarvisLogging/Redact.swift` returns ≥ 5 (exactly 5 patterns per D-20)
    - `grep -c 'sk-ant-\|Authorization\|sk-\|AKIA\|ghp_\|password\|secret\|token\|email\|ssn' packages/Logging/Sources/JarvisLogging/Redact.swift` returns no more than 6 (D-20: exactly 5 patterns, nothing more — counting excludes trivial occurrences in comments; if comments mention prohibited extras it's a violation)
    - `grep 'retentionDays: 7' packages/Logging/Sources/JarvisLogging/FileLogHandler.swift` returns 1 match (D-18)
    - `grep 'Library/Logs/Jarvis' packages/Logging/Sources/JarvisLogging/LogPaths.swift` returns 1 match (D-17)
    - `cd packages/Logging && swift test` exits 0 with ALL tests passing: RedactTests (test_anthropicKey, test_openAIKey, test_authorizationBearer, test_awsAccessKey, test_githubToken, test_plainTextUnchanged, test_anthropicBranchBeatsOpenAIBranch), FileLogHandlerTests (test_rotatesAtDayBoundary, test_deletesBeyondSeven), LoggingTests (test_fourChannelsAreDefined, test_factoryProducesMultiplexLogHandler, test_bootstrapRunsWithoutThrowing, test_subsystemConstant)
  </acceptance_criteria>
  <done>Logging package compiles under Swift 6 strict, four channels enumerated, MultiplexLogHandler factory wires FileLogHandler + OSLogHandler, Redact covers exactly 5 patterns with Anthropic-beats-OpenAI ordering, rotation+retain-7 verified with a TestDateProvider.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| macOS Keychain ↔ Jarvis process | Keychain grants access to `com.kingsrook.jarvis` service items; untrusted-process access is denied by OS ACL |
| config.json (disk, user-editable) ↔ Jarvis process | User may edit config; malicious same-user process may write — launch snapshot freeze + decode validation is the boundary |
| Log sinks (disk + os.Logger) ↔ user/inspectors | Log content is observable; redact boundary is the file-handler write |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-02-01 | Information Disclosure | Anthropic API key | mitigate | Keychain-only storage via `SystemKeychainStore` (SEC-01); `test_apiKeyNotInConfigJSON` asserts no API-key field exists in `LaunchSnapshot` encoding; S-5 fetch-per-request discipline (no caching). |
| T-02-02 | Tampering | `ollama.base_url` via config.json | mitigate | `OllamaConfig.init(from:)` rejects hosts not in {127.0.0.1, localhost, ::1} at decode time; fails with `ConfigError.invalidOllamaHost` (AGENT-05). Launch-snapshot freeze means runtime edits require restart (SEC-05). |
| T-02-03 | Tampering | Launch-snapshot bypass via runtime config mutation | mitigate | `LaunchSnapshot` stored as immutable `let`; `ConfigStore.launch` is non-mutating. Runtime edits to security keys require NSAlert + restart (file-watcher wires in Plan 03). |
| T-02-04 | Elevation of Privilege | AppleScript skip-allowlist | mitigate | `test_noSkipAllowlistKey` reflects over `AppleScriptPolicy` and fails if any `skipAllowlist`/`allowlist`/`bypass`/`regex` field exists (SEC-08). Every AppleScript requires confirmation — no bypass mechanism. |
| T-02-05 | Information Disclosure | API key in log files | mitigate | `Redact.apply` covers Anthropic `sk-ant-*`, OpenAI `sk-*`, AWS `AKIA*`, GitHub `ghp_*`, and `Authorization: Bearer` (OBS-06 / D-20); single call site at `FileLogHandler.log` (S-4). OSLogHandler uses `%{public}@` intentionally (raw through os.Logger — callers redact before logging if content is untrusted; file-handler redact is defense-in-depth). |
| T-02-06 | Information Disclosure | Over-redaction masking debugging info | accept | D-20 caps redact at exactly 5 patterns. No path redaction, no tool-result elision. Rationale: single-user machine threat model — over-redaction hurts P4+ debugging; replay log (OBS-02, P4) is already nothing-masked-bytes. |
| T-02-07 | Denial of Service | Malformed config file hides editing errors | mitigate | `ConfigLoader` throws `ConfigError.malformed` on decode failure; Plan 03 AppDelegate surfaces NSAlert hard-block (D-19). S-6 "hard-block on safety failures, not silent fallback". |
| T-02-08 | Denial of Service | `LoggingSystem.bootstrap` called twice → undefined swift-log state | mitigate | S-8 one-bootstrap discipline: `JarvisLogHandlerFactory.bootstrap` has a doc comment marking it "exactly once at `AppDelegate.applicationWillFinishLaunching`"; lint enforcement / code-review checkpoint in Plan 03. |

No `high`-severity residual risk. All known P1 Information-Disclosure and Tampering paths around secrets + config are mitigated. SEC-08 anti-bypass is reflection-asserted.
</threat_model>

<verification>
**Per package:**
- `cd packages/Keychain && swift test` exits 0 with 4 passing tests
- `cd packages/Config && swift test` exits 0 with ≥15 passing tests
- `cd packages/Logging && swift test` exits 0 with ≥13 passing tests

**Grep gates (from acceptance criteria):**
- No `featureFlags` in `LaunchSnapshot.swift`
- No `skipAllowlist` / `allowlist` / `bypass` / `regex` in `AppleScriptPolicy.swift`
- No `apiKey` / `api_key` / `anthropic_key` in either snapshot source
- No `Redact.apply` in `OSLogHandler.swift` (S-4 enforcement)
- Exactly 5 redact patterns (D-20)
</verification>

<success_criteria>
- Keychain package: Anthropic constant matches D-10; round-trip via Security.framework verified
- Config package: AGENT-05 localhost constraint enforced at decode time; SEC-05 split reflection-verified; SEC-08 no-skip-allowlist reflection-verified; OBS-05 feature flags in PerTurnSnapshot only; SEC-01 defense-in-depth via encoding grep
- Logging package: 4 channels (agent, tools, ui, system); MultiplexLogHandler factory; Redact 5 patterns; FileLogHandler with lazy midnight rotation + retain-7 verified via `TestDateProvider`; OSLogHandler via `os.Logger(subsystem: "com.kingsrook.jarvis", category: <label>)`
- All three packages compile standalone under Swift 6 strict concurrency
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundations/01-02-SUMMARY.md` documenting:
- Public API of each package (Keychain: `KeychainItem.anthropic`, `KeychainStore`, `SystemKeychainStore`; Config: `LaunchSnapshot`, `PerTurnSnapshot`, `ConfigLoader`, `ConfigStore`; Logging: `JarvisLogChannel`, `JarvisLogHandlerFactory`, `Redact`)
- Test count per package + which REQ-IDs each test covers (AGENT-05, SEC-01, SEC-05, SEC-08, OBS-05, OBS-06)
- Any Swift 6 strict-concurrency pushback that required `@unchecked Sendable` fallbacks
- Open items deferred to Plan 03 wiring: file-watcher restart banner, `LoggingSystem.bootstrap` call site, AppDelegate `ConfigLoader` + NSAlert wiring on malformed
</output>
</content>
</invoke>