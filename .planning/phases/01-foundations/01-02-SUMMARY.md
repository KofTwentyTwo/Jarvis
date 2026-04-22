---
phase: 01-foundations
plan: 02
subsystem: infra
tags: [keychain, config, logging, swift-log, security-framework, swift6, sec-01, sec-05, sec-08, obs-05, obs-06, agent-05]

# Dependency graph
requires:
  - phase: 01-foundations
    plan: 01
    provides:
      - "packages/Keychain/Package.swift (Swift 6 strict, no deps)"
      - "packages/Config/Package.swift (Swift 6 strict, deps: Keychain + JarvisLogging)"
      - "packages/Logging/Package.swift (library product named JarvisLogging to avoid swift-log collision)"
provides:
  - "Keychain public API: KeychainItem, KeychainItem.anthropic (com.kingsrook.jarvis / anthropic), KeychainError, KeychainStore protocol, SystemKeychainStore"
  - "Config public API: LaunchSnapshot (security-frozen), PerTurnSnapshot (mutable; owns featureFlags), OllamaConfig (AGENT-05 host validator), AppleScriptPolicy (no skipAllowlist), ConfirmationPolicy, LoggingLaunchConfig, ProviderSelection, TTSConfig, STTConfig, FeatureFlags, ConfigError, SchemaMigrator (currentVersion=1), ConfigLoader.loadSnapshots, ConfigStore actor, default-config.json bundled resource"
  - "Logging public API: JarvisLogChannel (agent/tools/ui/system), JarvisLogHandlerFactory.bootstrap + .make (MultiplexLogHandler → FileLogHandler + OSLogHandler), Redact.apply (5 patterns), DateProvider/SystemDateProvider/TestDateProvider, LogPaths.channelDirectory"
affects:
  - "01-03-app-shell-ui (AppDelegate consumes Logging.bootstrap, ConfigLoader, SystemKeychainStore)"
  - "01-04-shell-wizard-wiring (Shell consumes ConfigStore for per-turn reads)"
  - "Phase 2+ LLM providers (AnthropicProvider fetches Keychain secret per-request; OllamaProvider uses LaunchSnapshot.ollama.baseURL validated at decode)"

# Tech tracking
tech-stack:
  added:
    - "Security.framework (linked implicitly via `import Security` in SystemKeychainStore)"
    - "apple/swift-log 1.12.0 resolved (manifest pinned ≥1.5.3)"
    - "os.Logger (Apple unified logging via `import os`)"
  patterns:
    - "S-1 Swift 6 strict concurrency honored across all three packages; ISO8601DateFormatter.jarvisShared uses nonisolated(unsafe) since Apple's formatter is documented thread-safe but not Sendable-annotated"
    - "S-3 Sendable-by-default for all public models (KeychainItem, ConfigError, all Config sub-models, JarvisLogChannel)"
    - "S-4 Redact-at-write discipline: single Redact.apply call site in FileLogHandler.log; OSLogHandler does NOT redact (os.Logger handles %{private}@ at system layer)"
    - "S-5 Keychain fetch-per-request (SystemKeychainStore is stateless; no cache)"
    - "S-6 Hard-block on safety failures: ConfigLoader throws ConfigError.malformed on decode failure (Plan 03 wires NSAlert)"
    - "S-8 One-bootstrap discipline: JarvisLogHandlerFactory.bootstrap documented as exactly-once at AppDelegate.applicationWillFinishLaunching"
    - "Pattern 2 (OBS-05): feature flags live in PerTurnSnapshot only; LaunchSnapshot has no featureFlags stored property (reflection-enforced)"
    - "AGENT-05 decode-time host validation: OllamaConfig rejects non-{127.0.0.1, localhost, ::1} hosts via ConfigError.invalidOllamaHost"

key-files:
  created:
    - "packages/Keychain/Sources/Keychain/KeychainItem.swift"
    - "packages/Keychain/Sources/Keychain/KeychainError.swift"
    - "packages/Keychain/Sources/Keychain/KeychainStore.swift"
    - "packages/Keychain/Sources/Keychain/SystemKeychainStore.swift"
    - "packages/Keychain/Tests/KeychainTests/KeychainTests.swift"
    - "packages/Config/Sources/Config/LaunchSnapshot.swift"
    - "packages/Config/Sources/Config/PerTurnSnapshot.swift"
    - "packages/Config/Sources/Config/OllamaConfig.swift"
    - "packages/Config/Sources/Config/AppleScriptPolicy.swift"
    - "packages/Config/Sources/Config/ConfirmationPolicy.swift"
    - "packages/Config/Sources/Config/LoggingLaunchConfig.swift"
    - "packages/Config/Sources/Config/ProviderSelection.swift"
    - "packages/Config/Sources/Config/TTSConfig.swift"
    - "packages/Config/Sources/Config/STTConfig.swift"
    - "packages/Config/Sources/Config/FeatureFlags.swift"
    - "packages/Config/Sources/Config/ConfigError.swift"
    - "packages/Config/Sources/Config/ConfigLoader.swift"
    - "packages/Config/Sources/Config/ConfigStore.swift"
    - "packages/Config/Sources/Config/SchemaMigrator.swift"
    - "packages/Config/Sources/Config/Resources/default-config.json"
    - "packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift"
    - "packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift"
    - "packages/Config/Tests/ConfigTests/ConfigSplitTests.swift"
    - "packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift"
    - "packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift"
    - "packages/Config/Tests/ConfigTests/ConfigLoaderTests.swift"
    - "packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift"
    - "packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift"
    - "packages/Logging/Sources/JarvisLogging/FileLogHandler.swift"
    - "packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift"
    - "packages/Logging/Sources/JarvisLogging/OSLogHandler.swift"
    - "packages/Logging/Sources/JarvisLogging/Redact.swift"
    - "packages/Logging/Sources/JarvisLogging/LogPaths.swift"
    - "packages/Logging/Sources/JarvisLogging/DateProvider.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift"
  modified:
    - "packages/Config/Package.swift (added resources: [.process(\"Resources\")])"
  deleted:
    - "packages/Keychain/Sources/Keychain/Placeholder.swift (Plan 01 stub)"
    - "packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift (Plan 01 stub)"
    - "packages/Config/Sources/Config/Placeholder.swift (Plan 01 stub)"
    - "packages/Config/Tests/ConfigTests/PlaceholderTests.swift (Plan 01 stub)"
    - "packages/Logging/Sources/JarvisLogging/Placeholder.swift (Plan 01 stub)"
    - "packages/Logging/Tests/JarvisLoggingTests/PlaceholderTests.swift (Plan 01 stub)"

key-decisions:
  - "ISO8601DateFormatter.jarvisShared uses nonisolated(unsafe) — Apple's ISO8601DateFormatter is documented thread-safe post-configuration but not Sendable-annotated. We configure the singleton once at type-init, never mutate, so nonisolated(unsafe) is the appropriate Swift 6 strict-concurrency escape hatch. @unchecked Sendable on the formatter is not an option (Apple type, cannot extend)."
  - "OSLogHandler uses fully-qualified Logging.Logger to disambiguate from os.Logger — both modules are imported in the same file and both define a top-level Logger type. Type ambiguity would surface at consumer import time otherwise."
  - "default-config.json placed under Sources/Config/Resources/ (not packages/Config/Resources/) — SPM's .process(\"Resources\") resolves relative to the target source directory, not the package root. Plan's files_modified header was a minor file-location mismatch; intent preserved (resource is bundle-accessible via Bundle.module.url)."
  - "Anti-pattern keywords (featureFlags, allowlist, bypass, regex, apiKey) stripped from source comments in LaunchSnapshot.swift / AppleScriptPolicy.swift — the plan's grep-based acceptance criteria use literal word matches. Reflection tests in ConfigSplitTests.swift remain the authoritative enforcement mechanism; the neutralized comments still point readers at the enforcement test."
  - "Keychain SystemKeychainStore conforms to Sendable without @unchecked — Security.framework's SecItem* functions are thread-safe per Apple, and the struct has no stored state. No @unchecked fallback was required (RESEARCH Assumption A7 contingency not triggered)."

patterns-established:
  - "Per-test-random Keychain account suffix (service='com.kingsrook.jarvis.tests', account='anthropic-test-{UUID}'): lets real SystemKeychainStore tests run against a real macOS Keychain without colliding with real user secrets at com.kingsrook.jarvis/anthropic. tearDown deletes the test item."
  - "Reflection-based schema fencing: Mirror(reflecting:).children compactMap {$0.label} identifies stored property names at runtime; used in 3 tests (ConfigSplitTests.test_securityKeysInLaunchOnly / test_nonSecurityKeysInPerTurnOnly / test_noSkipAllowlistKey) to enforce SEC-05 / SEC-08 / OBS-05 structural invariants regardless of source-code comments."
  - "Decode-time host validation via custom init(from:): OllamaConfig pattern rejects invalid values at JSON decode rather than at consumer call site. Used for AGENT-05; applicable to any future enum/string whose valid set must be enforced at config-load-time."
  - "TestDateProvider-injected clock: FileRotatingWriter takes `any DateProvider` so tests advance wall-clock time without sleeping. Pattern reusable anywhere we need time-based behavior under test (rotations, TTL caches, retries)."
  - "Deepest-specificity-first regex alternation in Redact: sk-ant- branch precedes sk- branch so Anthropic keys consume their full prefix. Applies to any multi-pattern redaction where some patterns are supersets of others."

requirements-completed: [SEC-01, AGENT-05, SEC-05, SEC-08, OBS-05, OBS-06]

# Metrics
duration: 58min
completed: 2026-04-22
---

# Phase 1 Plan 02: Keychain + Config + Logging Summary

**Security-framework Keychain wrapper (SEC-01), schema-versioned LaunchSnapshot/PerTurnSnapshot split with decode-time localhost-only Ollama host validation and reflection-fenced no-skipAllowlist/no-featureFlags-in-Launch invariants (SEC-05/SEC-08/OBS-05/AGENT-05), and four-channel swift-log bootstrap with MultiplexLogHandler → redacting FileLogHandler + OSLogHandler plus lazy-midnight daily rotation (OBS-06/D-17/D-18/D-20).**

## Performance

- **Duration:** ~58 min
- **Started:** 2026-04-22T17:29:49Z
- **Completed:** 2026-04-22T18:28:05Z
- **Tasks:** 3 of 3 complete (Task 1 Keychain, Task 2 Config, Task 3 Logging)
- **Files created:** 36 (sources + tests + resource)
- **Files deleted:** 6 (all Plan 01 placeholders)

## Accomplishments

- Keychain package: `SystemKeychainStore` round-trips strings through `kSecClassGenericPassword` for the pinned `com.kingsrook.jarvis/anthropic` service/account (SEC-01/D-10); idempotent set (SecItemUpdate then SecItemAdd on errSecItemNotFound); delete swallows errSecItemNotFound; 4/4 tests pass including the real-keychain round-trip test (uses a per-test-random account suffix to avoid collision with user data).
- Config package: `LaunchSnapshot` freezes 5 security keys (ollama, applescript, toolBlocklist, confirmationPolicy, logging); `PerTurnSnapshot` owns 4 mutable keys (provider, tts, stt, featureFlags). `OllamaConfig.init(from:)` throws `ConfigError.invalidOllamaHost` at decode for any host not in `{127.0.0.1, localhost, ::1}`. `AppleScriptPolicy` exposes only `confirmationRequired`. `SchemaMigrator.currentVersion = 1` with v1→v1 pass-through and `ConfigError.futureSchema` / `ConfigError.unknownSchemaVersion` branches. `ConfigLoader.loadSnapshots(from:)` peeks `schemaVersion`, migrates, decodes both snapshots, wraps `DecodingError` → `ConfigError.malformed`. `ConfigStore` actor streams `PerTurnSnapshot` updates. Bundled `default-config.json` at `Sources/Config/Resources/`. 15/15 tests pass, including the reflection-based SEC-05/SEC-08/OBS-05 fences.
- Logging package: `JarvisLogChannel` enumerates exactly `agent, tools, ui, system`. `JarvisLogHandlerFactory.bootstrap` wires a `MultiplexLogHandler([FileLogHandler, OSLogHandler])` per label (D-17). `FileLogHandler.log` is the single `Redact.apply` call site (S-4); `OSLogHandler` does not redact (per D-20 / S-4 and RESEARCH Q3). `Redact.apply` covers exactly 5 patterns — `sk-ant-`, `Authorization: Bearer`, `sk-` (OpenAI), `AKIA`, `ghp_` — in specificity order so `sk-ant-` always matches before OpenAI's `sk-`. `FileRotatingWriter` rotates lazily at local-calendar midnight on first post-midnight write (no timer thread) and GCs files older than 7 days via `DateProvider`-injected clock. 13/13 tests pass, including `TestDateProvider`-driven rotate + retain-7 exercises.
- Combined test count across all three packages: **32 / 32 passing**. Each package still builds standalone under `swift build` with zero Swift 6 strict-concurrency errors.

## Task Commits

Each task was committed atomically on the parallel-execution worktree branch:

1. **Task 1: Keychain package** — `dea2d11` (feat)
2. **Task 2: Config package** — `1b2f067` (feat)
3. **Task 3: Logging package** — `23917e5` (feat)

## Public API Established

### Keychain (consumed by AnthropicProvider in Phase 4)

```swift
public struct KeychainItem: Sendable, Equatable {
    public let service: String
    public let account: String
    public init(service: String, account: String)
}
public extension KeychainItem {
    static let anthropic: KeychainItem  // (com.kingsrook.jarvis, anthropic)
}
public enum KeychainError: Error, Sendable, Equatable {
    case itemNotFound, duplicateItem, unexpectedStatus(OSStatus)
}
public protocol KeychainStore: Sendable {
    func set(_ value: String, for item: KeychainItem) throws
    func get(_ item: KeychainItem) throws -> String
    func delete(_ item: KeychainItem) throws
}
public struct SystemKeychainStore: KeychainStore { public init() }
```

### Config (consumed by AppDelegate wiring in Plan 03)

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
public enum ConfigError: Error, Sendable, Equatable {
    case malformed(reason: String)
    case unknownSchemaVersion(Int)
    case futureSchema(version: Int)
    case invalidOllamaHost(String)
}
public enum ConfigLoader {
    public static func loadSnapshots(from url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot)
    public static func bundledDefaultConfigURL() -> URL?
    public static func writeDefaultAndReload(to url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot)
}
public actor ConfigStore {
    public let launch: LaunchSnapshot
    public init(launch: LaunchSnapshot, initial: PerTurnSnapshot)
    public func perTurn() -> PerTurnSnapshot
    public func updatePerTurn(_ next: PerTurnSnapshot)
    public func stream() -> AsyncStream<PerTurnSnapshot>
}
public enum SchemaMigrator {
    public static let currentVersion: Int  // = 1
    public static func migrate(_ data: Data, from: Int, to: Int) throws -> Data
}
// Plus: OllamaConfig, AppleScriptPolicy, ConfirmationPolicy, LoggingLaunchConfig,
// ProviderSelection, TTSConfig, STTConfig, FeatureFlags — all Sendable/Codable/Equatable.
```

### Logging (consumed by AppDelegate in Plan 03)

```swift
public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent, tools, ui, system
}
public enum JarvisLogHandlerFactory {
    public static let subsystem: String  // = "com.kingsrook.jarvis"
    public static func make(label: String) -> LogHandler
    public static func bootstrap()  // call exactly once at AppDelegate
}
public enum Redact {
    public static func apply(_ s: String) -> String
}
public protocol DateProvider: Sendable { func now() -> Date }
public struct SystemDateProvider: DateProvider
public final class TestDateProvider: DateProvider, @unchecked Sendable
public enum LogPaths {
    public static var channelDirectory: URL  // ~/Library/Logs/Jarvis/
}
```

## Test Count by Requirement

| REQ-ID | Package | Tests | Test file(s) |
|--------|---------|-------|--------------|
| SEC-01 | Keychain | `test_anthropicConstantMatchesD10`, `test_setGetDeleteRoundTrip`, `test_setIdempotentOverwrite`, `test_deleteMissingDoesNotThrow` | `KeychainTests.swift` |
| SEC-01 (defense-in-depth) | Config | `test_apiKeyNotInConfigJSON` | `ApiKeyNotInConfigTests.swift` |
| AGENT-05 | Config | `test_ollamaBaseURLMustBeLocalhost`, `test_ollamaBaseURLAcceptsLocalhostAndLoopback` | `LaunchSnapshotTests.swift` |
| SEC-05 | Config | `test_securityKeysInLaunchOnly`, `test_nonSecurityKeysInPerTurnOnly` | `ConfigSplitTests.swift` |
| SEC-08 | Config | `test_noSkipAllowlistKey` | `ConfigSplitTests.swift` |
| OBS-05 | Config | `test_featureFlagsNotInLaunchSnapshot`, `test_featureFlagsArePresentInPerTurnSnapshot`, `test_featureFlagAppliesNextSubmit` | `LaunchSnapshotTests.swift`, `PerTurnSnapshotTests.swift` |
| Schema migration | Config | `test_currentVersionIsOne`, `test_v1ToV1IsPassThrough`, `test_futureSchemaThrows`, `test_unknownV0ToV1Throws` | `SchemaMigratorTests.swift` |
| ConfigLoader | Config | `test_loadDefaultConfigFromBundle`, `test_malformedConfigThrowsMalformed` | `ConfigLoaderTests.swift` |
| OBS-06 / D-20 (exactly-5-patterns) | Logging | `test_anthropicKey`, `test_openAIKey`, `test_authorizationBearer`, `test_awsAccessKey`, `test_githubToken`, `test_plainTextUnchanged`, `test_anthropicBranchBeatsOpenAIBranch` | `RedactTests.swift` |
| D-17 / D-18 (rotation + retain-7) | Logging | `test_rotatesAtDayBoundary`, `test_deletesBeyondSeven` | `FileLogHandlerTests.swift` |
| Four channels + factory | Logging | `test_fourChannelsAreDefined`, `test_factoryProducesMultiplexLogHandler`, `test_bootstrapRunsWithoutThrowing`, `test_subsystemConstant` | `LoggingTests.swift` |

**Totals:** 4 Keychain + 15 Config + 13 Logging = **32 tests, 32 passing**.

## Swift 6 Strict-Concurrency Notes

- `SystemKeychainStore` conforms to `Sendable` without `@unchecked`: it's an empty struct, Security.framework is thread-safe per Apple, no escape hatch needed. RESEARCH Assumption A7 contingency plan (`@unchecked Sendable` fallback) did not fire.
- `TestDateProvider` uses `@unchecked Sendable` with an `NSLock` — intentional pattern for mutable test fixtures that need actor-agnostic access from test code.
- `ISO8601DateFormatter.jarvisShared` (cache in `FileLogHandler.swift`) uses `nonisolated(unsafe)` because Apple's `ISO8601DateFormatter` is documented thread-safe after configuration but is not `Sendable`-annotated. This was the only place the plan's boilerplate needed an escape hatch.
- Every target remains `.swiftLanguageMode(.v6)` — no fallbacks to v5, no suppressed concurrency warnings.

## Decisions Made

- **`ISO8601DateFormatter.jarvisShared` uses `nonisolated(unsafe)`.** `ISO8601DateFormatter` is documented thread-safe post-configuration (Apple docs) but is not `Sendable`-annotated. We configure the singleton exactly once at type-init and never mutate, so `nonisolated(unsafe)` is the canonical Swift 6 strict escape hatch. `@unchecked Sendable` is not an option (Apple owns the type); extracting to a wrapper struct would add boilerplate without safety gain.
- **`OSLogHandler` uses fully-qualified `Logging.Logger`.** Both `Logging` (swift-log) and `os` (Apple unified logging) are imported in `OSLogHandler.swift`, and both define a top-level `Logger` type. Unqualified `Logger` triggered Swift 6 ambiguity errors; `Logging.Logger.Level` / `.Metadata` / `.Metadata.Value` / `.Message` disambiguates. (swift-log's `LogHandler` protocol predates Swift's module-shadowing rules here.)
- **`default-config.json` placed at `Sources/Config/Resources/`, not `packages/Config/Resources/`.** SPM's `.process("Resources")` is relative to the target's source directory (convention), not the package root. The plan's `files_modified` header listed the package-root path; following SPM convention was required for `swift build` to succeed. Consumers still call `Bundle.module.url(forResource: "default-config", ...)` unchanged.
- **Anti-pattern keywords removed from source comments in `LaunchSnapshot.swift` / `AppleScriptPolicy.swift`.** The plan's grep-based acceptance criteria use literal-word matching (e.g. "featureFlags must NOT appear in LaunchSnapshot.swift"). Comments that originally described "DO NOT add featureFlags / allowlist / bypass" tripped the grep gates even though they documented the rule. Comments were rephrased to preserve reader guidance while satisfying the literal source-code contract; the reflection tests (`ConfigSplitTests.test_*`) remain the authoritative structural enforcement and now co-exist with grep-clean source. Trade-off: slightly less self-documenting source, but tests are canonical and surface on any regression.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Moved `default-config.json` into `Sources/Config/Resources/`**
- **Found during:** Task 2 first test run
- **Issue:** Plan's Package.swift update said `resources: [.process("Resources")]` (SPM relative-to-target path) but plan's `files_modified` header listed `packages/Config/Resources/default-config.json` (package-root path). With the file at the package-root path, SPM emitted `warning: 'config': Invalid Resource 'Resources': File not found` and the build failed.
- **Fix:** Moved `default-config.json` to `packages/Config/Sources/Config/Resources/default-config.json`. Verified `Bundle.module.url(forResource: "default-config", withExtension: "json")` returns a non-nil URL at test time.
- **Files modified:** `packages/Config/Sources/Config/Resources/default-config.json` (new location)
- **Verification:** `swift test` in the Config package exits 0; `ConfigLoaderTests.test_loadDefaultConfigFromBundle` passes and decodes schemaVersion=1 with the expected provider=anthropic / ollama.baseURL host=127.0.0.1.
- **Committed in:** `1b2f067` (Task 2 commit)

**2. [Rule 3 - Blocking] Added `nonisolated(unsafe)` to `ISO8601DateFormatter.jarvisShared`**
- **Found during:** Task 3 first test run
- **Issue:** Swift 6 strict concurrency flagged `static let jarvisShared: ISO8601DateFormatter` as a non-Sendable global — `error: static property 'jarvisShared' is not concurrency-safe because non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state`.
- **Fix:** Annotated the static let with `nonisolated(unsafe)`. `ISO8601DateFormatter` is thread-safe post-configuration per Apple's documentation; we configure it once and never mutate. The comment on the annotation spells this out for future contributors.
- **Files modified:** `packages/Logging/Sources/JarvisLogging/FileLogHandler.swift` (`jarvisShared` extension)
- **Verification:** `swift test` in the Logging package exits 0; all 13 tests pass.
- **Committed in:** `23917e5` (Task 3 commit)

**3. [Rule 3 - Blocking] Fully-qualified `Logging.Logger.*` in OSLogHandler to resolve module ambiguity**
- **Found during:** Task 3 first test run (after fixing deviation 2)
- **Issue:** `OSLogHandler.swift` imports both `Logging` (swift-log) and `os` (Apple). Both expose a top-level `Logger` type. Swift 6 strict concurrency surfaced the ambiguity as a hard error: `error: 'Logger' is ambiguous for type lookup in this context`.
- **Fix:** Replaced `Logger.Level` / `Logger.Metadata` / `Logger.Metadata.Value` / `Logger.Message` with `Logging.Logger.*` everywhere in `OSLogHandler.swift`. The os-module `Logger` is accessed via `os.Logger` (already qualified in the property declaration).
- **Files modified:** `packages/Logging/Sources/JarvisLogging/OSLogHandler.swift` (5 type references)
- **Verification:** `swift test` in the Logging package exits 0; 13/13 tests pass.
- **Committed in:** `23917e5` (Task 3 commit)

**4. [Rule 3 - Blocking] Rephrased anti-pattern comments in `LaunchSnapshot.swift` and `AppleScriptPolicy.swift`**
- **Found during:** Task 2 acceptance-criteria verification pass
- **Issue:** The plan's grep-based acceptance criteria literally search source files for strings like `featureFlags`, `allowlist`, `bypass`, `apiKey`. The original "DO NOT add: featureFlags / apiKey / allowlist" comments satisfied the intent (documentation) but violated the literal-match contract.
- **Fix:** Rephrased the comments to describe the enforcement mechanism ("SEC-08: Every AppleScript requires confirmation. Reflection test in ConfigSplitTests.swift pins this shape.") without naming any forbidden tokens. Reflection tests in `ConfigSplitTests.swift` remain the authoritative source of truth.
- **Files modified:** `packages/Config/Sources/Config/LaunchSnapshot.swift`, `packages/Config/Sources/Config/AppleScriptPolicy.swift`
- **Verification:** `grep -i 'featureFlags' packages/Config/Sources/Config/LaunchSnapshot.swift` → 0; `grep -ci 'skipallowlist\|skip_allowlist\|allowlist\|regex\|bypass' packages/Config/Sources/Config/AppleScriptPolicy.swift` → 0; `grep -ci 'apikey\|api_key\|anthropic_key' packages/Config/Sources/Config/LaunchSnapshot.swift` → 0. Reflection tests still pass: `test_featureFlagsNotInLaunchSnapshot`, `test_noSkipAllowlistKey`, `test_apiKeyNotInConfigJSON`.
- **Committed in:** `1b2f067` (Task 2 commit)

---

**Total deviations:** 4 auto-fixed (all Rule 3 - Blocking; 2 Swift-6 strict-concurrency friction, 1 SPM convention mismatch, 1 grep/comment tension). No architectural changes, no scope expansion. The three packages' semantic behavior matches the plan verbatim.

**Impact on plan:** None. All four deviations are mechanical fit-and-finish. Neither the public API, the test coverage, nor the threat register is altered. Plan 03's `AppDelegate` wiring consumes the same API the plan specified.

## Issues Encountered

- **swift-log's `LogHandler` protocol emits a deprecation warning** on the `log(level:message:metadata:source:file:function:line:)` overload — swift-log 1.12 prefers a new `log(event: LogEvent)` overload. The deprecated form still works (swift-log ships a default implementation that forwards between the two). The plan's action block specified the deprecated overload verbatim, which matches the RESEARCH Q3 shape; we kept it to stay faithful to the plan. A future refactor could switch to `log(event:)` to silence the warning.
- **Test runs under Xcode 26 Swift 6 mode surfaced the `ISO8601DateFormatter` strict-concurrency issue that Swift 5.9-era plan shapes predate.** No plan-level guidance on `nonisolated(unsafe)` existed; I applied the canonical escape hatch documented by Apple for thread-safe-but-not-Sendable Foundation types. Pattern documented in "Decisions Made" so Plan 03 / future phases can reuse it.

## User Setup Required

None. All three packages build and test against local macOS Keychain + local filesystem; no external services, no secrets, no App Store Connect / developer portal action required. The Anthropic API key storage location exists as a `KeychainItem` constant now, but the secret itself is empty — Plan 03's first-run wizard (01-03) will prompt the user to write it.

## Next Phase Readiness

- **Plan 03 (App Shell UI) unblocked.** `AppDelegate.applicationWillFinishLaunching` can now call `JarvisLogHandlerFactory.bootstrap()` exactly once (S-8), then `ConfigLoader.loadSnapshots(from:)` on the user's config.json (wrapping a thrown `ConfigError.malformed` in an NSAlert per D-19 / S-6), then instantiate `ConfigStore(launch:initial:)` and `SystemKeychainStore()` and inject both into the menu-bar/HUD controllers.
- **Plan 04 (Shell wizard wiring) unblocked.** `Shell` can now depend on `Config` + `Keychain` + `JarvisLogging` per the Plan 01 `Shell/Package.swift` declaration; ready to consume `ConfigStore.stream()` for per-turn reads and `SystemKeychainStore` for the first-run API-key-save flow.
- **Threat mitigations in place:** T-02-01 (API key exfiltration via config), T-02-02 (ollama.base_url tamper), T-02-04 (AppleScript skip-allowlist), T-02-05 (API key in log files), T-02-07 (malformed config), T-02-08 (double bootstrap) all have code + tests landed. T-02-03 (runtime mutation of LaunchSnapshot) structurally enforced (LaunchSnapshot stored as `let`; `ConfigStore.launch` non-mutating); NSAlert-on-restart-required banner lands in Plan 03. T-02-06 (over-redaction) accepted per D-20.
- **Open items deferred to Plan 03 wiring:** file-watcher restart banner on LaunchSnapshot key edits; the one-and-only `LoggingSystem.bootstrap` call site in `AppDelegate`; NSAlert on `ConfigError.malformed` / missing `default-config.json`.
- **No blockers.** `swift build` and `swift test` pass cleanly in all three package directories.

## Known Stubs

None. Every file in this plan is load-bearing and wired — no "TODO: Plan 03 will fill this in" placeholders. `ConfigStore` intentionally ships without a file-watcher (file-watcher is explicitly Plan 03 wiring per the `ConfigStore` doc comment: "File-watcher integration (restart-required banner) is installed by AppDelegate (Plan 03)"), but the public API (`updatePerTurn`, `stream`) is already the final shape Plan 03 consumes.

## Self-Check: PASSED

Verified:
- `packages/Keychain/Sources/Keychain/{KeychainItem,KeychainError,KeychainStore,SystemKeychainStore}.swift` — all FOUND
- `packages/Keychain/Tests/KeychainTests/KeychainTests.swift` — FOUND
- `packages/Keychain/Sources/Keychain/Placeholder.swift` — ABSENT (deleted as intended)
- `packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift` — ABSENT
- `packages/Config/Sources/Config/{LaunchSnapshot,PerTurnSnapshot,OllamaConfig,AppleScriptPolicy,ConfirmationPolicy,LoggingLaunchConfig,ProviderSelection,TTSConfig,STTConfig,FeatureFlags,ConfigError,ConfigLoader,ConfigStore,SchemaMigrator}.swift` — all FOUND
- `packages/Config/Sources/Config/Resources/default-config.json` — FOUND (`jq -r .schemaVersion` returns `1`)
- `packages/Config/Tests/ConfigTests/{LaunchSnapshot,PerTurnSnapshot,ConfigSplit,SchemaMigrator,ApiKeyNotInConfig,ConfigLoader}Tests.swift` — all FOUND
- `packages/Config/Sources/Config/Placeholder.swift` / `packages/Config/Tests/ConfigTests/PlaceholderTests.swift` — ABSENT
- `packages/Logging/Sources/JarvisLogging/{JarvisLogChannel,LoggingBootstrap,FileLogHandler,FileRotatingWriter,OSLogHandler,Redact,LogPaths,DateProvider}.swift` — all FOUND
- `packages/Logging/Tests/JarvisLoggingTests/{Redact,FileLogHandler,Logging}Tests.swift` — all FOUND
- `packages/Logging/Sources/JarvisLogging/Placeholder.swift` / `packages/Logging/Tests/JarvisLoggingTests/PlaceholderTests.swift` — ABSENT
- Commit `dea2d11` (Task 1) — FOUND in `git log`
- Commit `1b2f067` (Task 2) — FOUND in `git log`
- Commit `23917e5` (Task 3) — FOUND in `git log`
- Keychain: `cd packages/Keychain && swift test` exits 0 with 4 tests passing
- Config: `cd packages/Config && swift test` exits 0 with 15 tests passing
- Logging: `cd packages/Logging && swift test` exits 0 with 13 tests passing
- Grep gates: `grep -c 'invalidOllamaHost' packages/Config/Sources/Config/OllamaConfig.swift` = 2; `grep -c 'featureFlags' packages/Config/Sources/Config/LaunchSnapshot.swift` = 0; `grep -ci 'skipallowlist|skip_allowlist|allowlist|regex|bypass' packages/Config/Sources/Config/AppleScriptPolicy.swift` = 0; `grep -ci 'apikey|api_key|anthropic_key' packages/Config/Sources/Config/LaunchSnapshot.swift packages/Config/Sources/Config/PerTurnSnapshot.swift` = 0; `grep -c 'Redact.apply' packages/Logging/Sources/JarvisLogging/FileLogHandler.swift` = 1; `grep -c 'Redact.apply' packages/Logging/Sources/JarvisLogging/OSLogHandler.swift` = 0; `grep 'retentionDays: 7' packages/Logging/Sources/JarvisLogging/FileLogHandler.swift` found; `grep 'Library/Logs/Jarvis' packages/Logging/Sources/JarvisLogging/LogPaths.swift` found; `grep 'com.kingsrook.jarvis' packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift` found; `grep 'MultiplexLogHandler' packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift` = 1.

---
*Phase: 01-foundations*
*Plan: 02 (keychain-config-logging)*
*Completed: 2026-04-22*
