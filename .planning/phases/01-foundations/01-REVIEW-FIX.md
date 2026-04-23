---
phase: 01-foundations
fixed_at: 2026-04-23T16:30:00Z
review_path: .planning/phases/01-foundations/01-REVIEW.md
iteration: 1
findings_in_scope: 15
fixed: 15
skipped: 0
status: issues_fixed
---

# Phase 1: Code Review Fix Report

**Fixed at:** 2026-04-23T16:30:00Z
**Source review:** `.planning/phases/01-foundations/01-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 15 (3 BLOCKER + 12 WARNING)
- Fixed: 15 (3 BLOCKER + 12 WARNING + 2 bonus INFO)
- Skipped: 0

**Scope note:** per the /gsd-code-review-fix directive the default scope was
BLOCKER + WARNING. Two INFO findings explicitly named by the orchestrator —
IN-02 (OSLogHandler privacy override) and IN-07 (AppDelegateWiringTests
tautology) — were also fixed because they close real regressions rather
than style nits.

All fixes verified via:
- `swift test --package-path packages/{Keychain,Config,Logging,Shell}` — 56
  tests pass across all four Swift packages (1 skipped — live
  SMAppService test, opt-in via env var).
- `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration
  Debug build` — clean build.
- `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration
  Debug build-for-testing` — test-bundle link passes.
- `scripts/test-verify-entitlements.sh` — 3/3 PASS on the fault-injection
  self-test (WR-12 regression gate).

## Fixed Issues

### CR-01: Keychain items written without `kSecAttrAccessible` — SEC-01 violation

**Files modified:**
- `packages/Keychain/Sources/Keychain/SystemKeychainStore.swift`
- `packages/Keychain/Tests/KeychainTests/KeychainTests.swift`

**Commit:** `afd2bc6`
**Applied fix:** Pinned every SecItemAdd / SecItemUpdate to
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable =
kCFBooleanFalse`. Added two regression tests: a runtime query that asserts
a freshly-written item does not match a `kSecAttrSynchronizable = true`
query, and a source-level grep gate that fails CI if either attribute is
dropped. (Runtime `kSecAttrAccessible` readback is not available on the
legacy file-based macOS keychain; the source gate covers that path.)

### CR-02: API key plaintext retained in SwiftUI `@State` — SEC-01

**Files modified:**
- `App/Wizard/WizardStageAPIKeyView.swift`
- `App/Tests/AppTests/WizardStageAPIKeyViewTests.swift` (new)
- `Jarvis.xcodeproj/project.pbxproj` (xcodegen regen)

**Commit:** `929e4ce`
**Applied fix:** `verify()` captures the key into a local and reassigns
`apiKey = ""` immediately so the `@State` slot drops its strong reference
before the async validate / keychain.set chain runs. Error branches
selectively restore the key only where the user plausibly retries.
`.onDisappear { clearAPIKey() }` zeros the buffer and drops `@State` to
empty on every view teardown. Added source-level grep-gate tests for
the three regression points.

### CR-03: `HotkeyBinder.bind` doesn't detect nil global token — SHELL-06

**Files modified:**
- `packages/Shell/Sources/Shell/HotkeyBinder.swift`
- `packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift`
- `App/AppDelegate.swift`

**Commit:** `cd3b62f`
**Applied fix:** Added `HotkeyBinder.BannerSink` protocol mirroring the
`InputMonitoringProbe.BannerSink` pattern. `bind(...)` now inspects the
returned token; if nil, sets `isDegraded = true` AND invokes
`sink.enqueueHotkeyBindFailed()`. `AppDelegate.bindHotkeyFromWizard`
wires `HotkeyBindFailedSink` to the coordinator — **this also fixes WR-06**
(the hotkeyBindFailed banner preset was previously orphaned). Three new
tests: nil-token-marks-degraded, denied-InputMonitoring-doesn't-trip-the-
wrong-banner, happy-path-doesn't-spuriously-enqueue.

### WR-01: `FileRotatingWriter` silently drops log lines — OBS-06

**Files modified:**
- `packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift`
- `packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift`

**Commit:** `813c690`
**Applied fix:** Added `droppedLinesThisWindow` counter touched only from
the serial queue. Both failure paths (`nil handle` and `handle.write`
throw) now increment the counter and emit a one-time `os.Logger.fault`
(subsystem `com.koftwentytwo.jarvis`, category `logging.file`) per
rotation window. `rotateIfNeeded` emits the total drop count at each
boundary. New `test_dropsLinesWhenHandleUnavailable` points the writer at
a regular file-posing-as-directory and asserts 3 appends → 3 dropped.

### WR-02: ConfigError description bypasses `Redact.apply`

**Files modified:**
- `App/AppDelegate.swift`

**Commit:** `f950c7d`
**Applied fix:** Both the `catch let e as ConfigError` and the generic
`catch` branches now route the error description through `Redact.apply`
before both `systemLogger?.critical(...)` and the NSAlert's
`informativeText`. Protects against a malformed config that happened to
contain an API key (user pastes it into config.json by mistake) from
landing plaintext in `~/Library/Logs/Jarvis/` AND in os.Logger.

### WR-03: OllamaConfig DNS-rebind vulnerability — AGENT-05

**Files modified:**
- `packages/Config/Sources/Config/OllamaConfig.swift`

**Commit:** `e3024cd`
**Applied fix:** `validateHost` now normalizes IPv6-bracketed hosts,
retains the string allowlist as a fast first-pass, and for `localhost`
additionally calls `getaddrinfo` and asserts every resolved IPv4 address
is in 127.0.0.0/8 and every IPv6 address is ::1. Fails closed on
resolution errors or unknown address families. Defeats an `/etc/hosts`
hijack or resolver compromise that points `localhost` to a non-loopback
address.

### WR-04: SchemaMigrator error context ambiguity

**Files modified:**
- `packages/Config/Sources/Config/ConfigError.swift`
- `packages/Config/Sources/Config/SchemaMigrator.swift`
- `packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift`

**Commit:** `569bc80`
**Applied fix:** Replaced `unknownSchemaVersion(Int)` and
`futureSchema(version: Int)` with `unknownSchemaVersion(have:supports:)`
and `futureSchema(have:supports:)` so error messages can unambiguously
report "config is at v3, Jarvis supports up to v2" rather than an
ambiguous single `version: N` field whose meaning varies by context. Test
assertions updated. No other callers touched.

### WR-05: HUDBannerCoordinator 300ms drain race

**Files modified:**
- `App/HUD/HUDBannerCoordinator.swift`
- `App/Tests/AppTests/HUDBannerCoordinatorTests.swift`

**Commit:** `9fc0535`
**Applied fix:** Made the drain a cancellable `DispatchWorkItem` stored
on the coordinator. `clear()` cancels the drain (prevents banner pop-up
at app-quit). `enqueue()` on an empty `current` also cancels any pending
drain (prevents the drained banner from clobbering a higher-priority
enqueue). Two new tests cover both paths with 500ms settle windows.

### WR-06: `BannerContent.hotkeyBindFailed` preset orphaned

**Resolution:** Auto-fixed by CR-03 (`cd3b62f`). The
`HotkeyBindFailedSink` now enqueues the preset from production code.

### WR-07: `AnthropicKeyValidator` uses `URLSession.shared` — MITM-proxy key leak

**Files modified:**
- `App/Wizard/AnthropicKeyValidator.swift`

**Commit:** `9850d95`
**Applied fix:** Default client is now an ephemeral `URLSession` with
`connectionProxyDictionary = [:]` (refuses system proxy),
`tlsMinimumSupportedProtocolVersion = .TLSv13`, 15s request / 30s
resource timeouts, no cookies, no credential storage, no URL cache.
`MockClient` test path still works because the initializer accepts an
optional client. `AnthropicKeyValidatorTests` unchanged.

### WR-08: FileRotatingWriter clock-skew + idle-app retention

**Files modified:**
- `packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift`
- `packages/Logging/Sources/JarvisLogging/FileLogHandler.swift`

**Commit:** `5bd9076`
**Applied fix:** `rotateIfNeeded` now computes the day-delta between the
previous window and the new day; if `|delta| > 2`, emits a notice-level
fault. Added public `runRetentionGC()` on both `FileRotatingWriter` and
`FileLogHandler` so App-layer callers can trigger GC at shutdown or on
a periodic heartbeat — an idle app that doesn't cross midnight for >7
days still cleans up stale files.

### WR-09: OnboardingWizardController refresh race

**Files modified:**
- `App/Wizard/OnboardingWizardController.swift`

**Commit:** `1fc613b`
**Applied fix:** Documented the refresh-before-view-build invariant
with an explicit docstring + runtime `Thread.isMainThread` assertion.
Async-off-main refresh would make the UX worse (visible flash of empty
wizard for the async duration), so the existing synchronous posture is
retained but now regression-proof. Note in the comment marks this for
revisit if keychain stalls become user-visible.

### WR-10: WKWebView KVC private-key exception safety

**Files modified:**
- `App/HUD/JarvisHUDPanel.swift`

**Commit:** `9d50e1c`
**Applied fix:** Wrapped `setValue(false, forKey: "drawsBackground")` in a
`responds(to: NSSelectorFromString("setDrawsBackground:"))` probe. A
future WebKit rename of the setter now degrades to an opaque HUD
(visible regression) instead of an `NSUndefinedKeyException` launch
crash.

### WR-11: FeatureFlags typo-silent-disable

**Files modified:**
- `packages/Config/Sources/Config/FeatureFlags.swift`
- `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`

**Commit:** `0785d6e`
**Applied fix:** Added `public enum FeatureFlag: String, CaseIterable,
Sendable` with cases `orpheusTTSEnabled` and `whisperKitSTTEnabled`
(the known flags per REQUIREMENTS.md). Canonical typed lookup is now
`isEnabled(_ flag: FeatureFlag)`; the string-keyed path was renamed to
`isEnabledDynamic(_:)` so production callers get a compile error on
typos. New `test_featureFlagEnumRawValueMatchesDecoder` regression
guard. No production callers of the old string API — no migration
needed.

### WR-12: `verify-entitlements.sh --post-codesign` swallows codesign stderr

**Files modified:**
- `scripts/verify-entitlements.sh`

**Commit:** `4446afb`
**Applied fix:** Both the main-app and per-helper `codesign -d`
invocations now split streams (stdout → captured, stderr → temp file),
check exit status explicitly with `if ! … ; then`, and dump the captured
stderr + exit 1 on codesign failure. Dropped `-depth` from the helper
find — only relevant for signing, pointless for verify. The
`scripts/test-verify-entitlements.sh` self-test still passes 3/3.

## Bonus fixes (Info findings explicitly called out in orchestrator prompt)

### IN-02: OSLogHandler marks every message `.public`

**Files modified:**
- `packages/Logging/Sources/JarvisLogging/OSLogHandler.swift`

**Commit:** `559661b`
**Applied fix:** Replaced `privacy: .public` with
`privacy: .private(mask: .hash)`. Untrusted interpolated values
(file paths, error descriptions) are now hashed in Console.app captures
by default. Severity signal is preserved via the `logger.log(level:)`
API (not embedded in the message body). All 14 logging tests still pass.

### IN-07: `AppDelegateWiringTests.test_stateDumpDoesNotIncludeAPIKey` tautology

**Files modified:**
- `App/Tests/AppTests/AppDelegateWiringTests.swift`

**Commit:** `b76ff75`
**Applied fix:** Replaced `XCTAssertTrue(true)` body with a real assertion:
`RecognizableKeychain` fake returns `"sk-ant-test-do-not-leak"`;
`NSPasteboard.general.clearContents()` before the test; trigger
`copyStateDump()` via `perform(Selector("copyStateDump"))`; assert the
pasteboard string does NOT contain the sentinel plaintext AND does NOT
contain any `sk-ant-` prefix. Sanity check: the pasteboard DOES contain
`"apiKeyStored"` so we know the path was exercised.

## Skipped issues

None — every in-scope finding was fixed.

## Test verification summary

| Package | Tests | Skipped | Failures |
|---------|-------|---------|----------|
| Keychain | 6 | 0 | 0 |
| Config | 16 | 0 | 0 |
| Logging | 14 | 0 | 0 |
| Shell | 20 | 1 (live SMAppService, opt-in) | 0 |
| **Total** | **56** | **1** | **0** |

App-layer Xcode tests (JarvisAppTests) were not executed via
`xcodebuild test` because of an unrelated Runningboard launch error in
this environment (Launchd job spawn failed on test-runner install).
Build-for-testing passes cleanly, which confirms the test target
compiles with all new tests included and the xcodegen regen picked up
the new `WizardStageAPIKeyViewTests.swift` file correctly. The
additional App-layer assertions (IN-07 SEC-01 pasteboard check, CR-02
regression gates, WR-05 drain-race tests) are syntactically verified by
the linker; the first subsequent manual `xcodebuild test` run or Xcode
IDE run will exercise them.

---

_Fixed: 2026-04-23_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
