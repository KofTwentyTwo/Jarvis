---
phase: 01-foundations
reviewed: 2026-04-22T00:00:00Z
depth: standard
files_reviewed: 69
files_reviewed_list:
  - App/AppDelegate.swift
  - App/JarvisApp.swift
  - App/Info.plist
  - App/Jarvis.entitlements
  - App/HUD/BannerContent.swift
  - App/HUD/HUDBanner.swift
  - App/HUD/HUDBannerCoordinator.swift
  - App/HUD/HUDBannerPanel.swift
  - App/HUD/JarvisHUDPanel.swift
  - App/MenuBar/CAAnimationFactory.swift
  - App/MenuBar/MenuBarContextMenu.swift
  - App/MenuBar/MenuBarIconController.swift
  - App/Theme/BrandColors.swift
  - App/Theme/HudState.swift
  - App/Wizard/AnthropicKeyValidator.swift
  - App/Wizard/OnboardingWizardController.swift
  - App/Wizard/WizardStageAPIKeyView.swift
  - App/Wizard/WizardStageHotkeyView.swift
  - App/Wizard/WizardStageTCCView.swift
  - App/Wizard/WizardState.swift
  - App/Wizard/WizardView.swift
  - App/Tests/AppTests/AnthropicKeyValidatorTests.swift
  - App/Tests/AppTests/AppDelegateEntitlementTests.swift
  - App/Tests/AppTests/AppDelegateWiringTests.swift
  - App/Tests/AppTests/HUDBannerCoordinatorTests.swift
  - App/Tests/AppTests/JarvisHUDPanelTests.swift
  - App/Tests/AppTests/MenuBarIconControllerTests.swift
  - App/Tests/AppTests/WizardStateTests.swift
  - App/Tests/AppTests/WizardTCCStageTests.swift
  - App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift
  - App/Tests/JarvisEntitlementProbeTests/Info.plist
  - packages/Config/Package.swift
  - packages/Config/Sources/Config/AppleScriptPolicy.swift
  - packages/Config/Sources/Config/ConfigError.swift
  - packages/Config/Sources/Config/ConfigLoader.swift
  - packages/Config/Sources/Config/ConfigStore.swift
  - packages/Config/Sources/Config/ConfirmationPolicy.swift
  - packages/Config/Sources/Config/FeatureFlags.swift
  - packages/Config/Sources/Config/LaunchSnapshot.swift
  - packages/Config/Sources/Config/LoggingLaunchConfig.swift
  - packages/Config/Sources/Config/OllamaConfig.swift
  - packages/Config/Sources/Config/PerTurnSnapshot.swift
  - packages/Config/Sources/Config/ProviderSelection.swift
  - packages/Config/Sources/Config/SchemaMigrator.swift
  - packages/Config/Sources/Config/STTConfig.swift
  - packages/Config/Sources/Config/TTSConfig.swift
  - packages/Config/Sources/Config/Resources/default-config.json
  - packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift
  - packages/Config/Tests/ConfigTests/ConfigLoaderTests.swift
  - packages/Config/Tests/ConfigTests/ConfigSplitTests.swift
  - packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift
  - packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift
  - packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift
  - packages/Keychain/Package.swift
  - packages/Keychain/Sources/Keychain/KeychainError.swift
  - packages/Keychain/Sources/Keychain/KeychainItem.swift
  - packages/Keychain/Sources/Keychain/KeychainStore.swift
  - packages/Keychain/Sources/Keychain/SystemKeychainStore.swift
  - packages/Keychain/Tests/KeychainTests/KeychainTests.swift
  - packages/Logging/Package.swift
  - packages/Logging/Sources/JarvisLogging/DateProvider.swift
  - packages/Logging/Sources/JarvisLogging/FileLogHandler.swift
  - packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift
  - packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift
  - packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift
  - packages/Logging/Sources/JarvisLogging/LogPaths.swift
  - packages/Logging/Sources/JarvisLogging/OSLogHandler.swift
  - packages/Logging/Sources/JarvisLogging/Redact.swift
  - packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift
  - packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift
  - packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift
  - packages/Shell/Package.swift
  - packages/Shell/Sources/Shell/HotkeyBinder.swift
  - packages/Shell/Sources/Shell/InputMonitoringProbe.swift
  - packages/Shell/Sources/Shell/KeyboardShortcut.swift
  - packages/Shell/Sources/Shell/LaunchAtLoginController.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/KeyCapView.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift
  - packages/Shell/Sources/Shell/TCCAlertService.swift
  - packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift
  - packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift
  - packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift
  - packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift
  - project.yml
  - scripts/codesign.sh
  - scripts/verify-entitlements.sh
  - scripts/verify-codesign-settings.sh
  - scripts/test-verify-entitlements.sh
findings:
  critical: 3
  warning: 12
  info: 7
  total: 22
status: issues_found
---

# Phase 1: Code Review Report

**Reviewed:** 2026-04-22
**Depth:** standard
**Files Reviewed:** 69 (App + Swift packages + tests + scripts)
**Status:** issues_found

## Summary

Phase 1 Foundations is architecturally sound and — to its credit — carries through its security hygiene intent: the Keychain store never exposes values to logs, `copyStateDump()` writes only boolean presence, `Redact.swift` covers five key shapes, the Ollama host allowlist is enforced at decode time, `JarvisEntitlementsVerified` gates launch, and `codesign.sh` walks deepest-first without `--deep`. The Swift 6 strict-concurrency story is clean; every `@unchecked Sendable` and `nonisolated(unsafe)` I found is justified in a comment.

That said, there are real defects — one of them (BLOCKER CR-01) undermines a stated SEC-01 guarantee. Three BLOCKER-class issues need fixing before Phase 2 consumes this foundation:

1. **CR-01 (SEC-01):** `SystemKeychainStore` omits `kSecAttrAccessible`, so items are created with the OS default (historically `kSecAttrAccessibleWhenUnlocked`, but — per Apple — **items written without this attribute get migrated to iCloud Keychain if Keychain sync is enabled**, and on macOS the default also allows the item to be backed up to unencrypted Time Machine backups. The documented SEC-01 / D-10 posture is "never leaves this device"; the current store does not enforce that.
2. **CR-02 (SEC-01):** The `AnthropicKeyValidator` reads the user's API key directly from a SwiftUI `@State private var apiKey: String`. That value lives in a `String` that's never zeroed and is retained by `SwiftUI.TextField`'s internal diffing machinery for the lifetime of the wizard view. On view dismissal the heap page may be reused — meanwhile the key has already been stored in Keychain, making the in-memory residual redundant. The SEC-01 mitigation ("stored in Keychain and never written to disk in plaintext") is technically satisfied only because swap is disabled on Apple Silicon by default; any Intel target or memory-dump scenario exposes the key.
3. **CR-03 (Correctness):** `HotkeyBinder.bind(...)` never tests whether `store.installGlobalMonitor` returned `nil`. `NSEvent.addGlobalMonitorForEvents` **returns `nil` on Input Monitoring denial** (the exact SHELL-06 footgun the code claims to guard against), which means `globalToken` can be `nil` but `isDegraded` will still be set to `false`. The downstream `unbind()` silently no-ops for a `nil` token, but the degraded-mode banner is never surfaced because the HID probe already returned `true`. This is a real silent-no-op path that contradicts SHELL-06's "no silent no-op on denial" invariant.

Warnings concentrate in two places: (a) Config-package edge cases around URL parsing, schema migration off-by-one, and snapshot-decode order, and (b) HUD/banner lifecycle issues (race on 300ms drain, pre-empted banner never re-dedups). Info-level items are mostly defensible style choices that deserve a one-line note.

---

## Critical Issues

### CR-01: Keychain items written without `kSecAttrAccessible` — violates SEC-01 "never leaves this device" posture

**File:** `packages/Keychain/Sources/Keychain/SystemKeychainStore.swift:7-26`
**Severity:** BLOCKER

**Issue:** Both the `SecItemUpdate` and `SecItemAdd` query dictionaries omit `kSecAttrAccessible`. When absent, macOS uses the system default. Per Apple's [Keychain Services Programming Guide] and the `SecItem` header comments, items written without an explicit `kSecAttrAccessible` value:

1. Are eligible for automatic migration to iCloud Keychain if the user enables "Keychain in iCloud" (the default attribute is implicitly `kSecAttrAccessibleWhenUnlocked`, which is synchronizable unless `kSecAttrSynchronizable=false` is also passed — and the current code sets neither).
2. Can be backed up and migrated to a new Mac via Migration Assistant, Time Machine, or iCloud Backup.

Either migration path contradicts the documented SEC-01 / D-10 guarantee ("never leaves this device"). The `KeychainTests` pass because the tests only verify round-trip behavior on the current device — nothing asserts `kSecAttrSynchronizable=false` or the accessibility class.

Additionally, there is no `kSecAttrAccessControl` to require user presence, and no `kSecUseDataProtectionKeychain` to force the data-protection keychain (the one that enforces file-vault-level encryption at rest). On Intel Macs without FileVault the item is encrypted with a key derived from the login password only.

**Fix:** Explicitly set both accessibility and non-sync on every `set`:
```swift
public func set(_ value: String, for item: KeychainItem) throws {
    let data = Data(value.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: item.service,
        kSecAttrAccount as String: item.account,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any,   // never iCloud
    ]
    let attrs: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    // …rest unchanged; also mirror the attrs into addQuery.
}
```
And add a test in `KeychainTests.swift`:
```swift
func test_itemIsDeviceOnlyAndNotSynchronizable() throws {
    try store.set("secret", for: testItem)
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: testItem.service,
        kSecAttrAccount as String: testItem.account,
        kSecReturnAttributes as String: kCFBooleanTrue as Any,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var r: AnyObject?
    XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &r), errSecSuccess)
    let attrs = r as! [String: Any]
    XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
}
```

---

### CR-02: Anthropic API key retained in Swift `String` heap memory until view deallocates

**File:** `App/Wizard/WizardStageAPIKeyView.swift:10, 53-67`
**Severity:** BLOCKER

**Issue:** `apiKey` is `@State private var apiKey: String = ""`. SwiftUI retains this through its attribute-graph diffing; the value outlives the validation call, persists during the entire Keychain write, and is not explicitly zeroed after use. After `try keychain.set(apiKey, for: .anthropic)` succeeds the code calls `onAdvance()` but leaves `apiKey` populated with the real secret until the view deallocates — that can be many seconds later on the animation path, and longer if the wizard stays open via back-navigation.

The docstring at the top of the file promises the value "is never persisted anywhere else (SEC-01)". That is only true for disk. For memory the claim is materially false:
- The original `SecureField` input.
- The `apiKey` state variable.
- The captured `apiKey` in the `Task { @MainActor in … }` closure (still alive after the Keychain write because the error-branch `errorMessage` lives in the same closure).

Any memory-dump forensic vector — crash report with heap snapshot, Xcode memory graph, `leaks(1)` dump, third-party debugger — sees the plaintext key.

There is also a **partial write window**: if `keychain.set` throws `KeychainError.unexpectedStatus(-34018)` (the "entitlement missing" family), the view shows a generic error but `apiKey` is still populated and the user can re-submit. Meanwhile `SecItemAdd` on a bad entitlement may leave a half-written item that `SecItemUpdate` picks up on the next call, stashing the key under an unintended accessibility class.

**Fix:** Zero the buffer immediately after the keychain write succeeds and after any terminal error; also cap the maximum lifetime of `apiKey` by keeping the write synchronous with the input:
```swift
private func verify() {
    errorMessage = nil
    isValidating = true
    let capturedKey = apiKey       // single copy for the task
    apiKey = ""                    // clear the @State immediately so SwiftUI redraws with empty SecureField
    Task { @MainActor in
        defer {
            // Best-effort overwrite — Swift Strings are CoW and immutable, so this doesn't
            // truly zero the backing storage, but it removes the last strong reference
            // from the local scope so ARC can release the page sooner.
            _ = capturedKey.isEmpty
        }
        let result = await validator.validate(key: capturedKey)
        isValidating = false
        switch result {
        case .valid:
            do {
                try keychain.set(capturedKey, for: .anthropic)
                state.apiKeyStored = true
                onAdvance()
            } catch {
                // restore the UI state so the user can retry without retyping
                apiKey = capturedKey
                errorMessage = "Something went wrong saving your key. Details in the system log."
            }
        // …other cases: restore apiKey = capturedKey for retry, or leave empty for .malformed
        }
    }
}
```

Bigger fix: store the value as `[UInt8]` from the start (via a `CocoaPod`-style `SecretStore` wrapper that owns the bytes and zeroes them in `deinit`), not a `String`. Swift `String` CoW semantics make it effectively impossible to zero in place, so the correct long-term posture is to avoid materializing the plaintext as `String` at all — bind `SecureField` to a `Data` binding and hand raw bytes to `SecItemAdd(kSecValueData:)`.

---

### CR-03: `HotkeyBinder.bind` does not detect silent `nil` token from `NSEvent.addGlobalMonitorForEvents` — violates SHELL-06

**File:** `packages/Shell/Sources/Shell/HotkeyBinder.swift:91-107`
**Severity:** BLOCKER

**Issue:** `NSEvent.addGlobalMonitorForEvents(matching:handler:)` returns `nil` if the process lacks Input Monitoring authorization, or if `accessibility-events` is otherwise denied at the moment of the call. The binder assumes the `inputMonitoringGranted` parameter is authoritative — but the parameter is sourced from `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` which is cached by the OS and **does not re-verify if the user revokes the permission between app launches** (or between the wizard completion and the first hotkey press).

The path that fires SHELL-06:
1. User grants Input Monitoring in wizard. `inputMonitoringGranted = true`.
2. User revokes Input Monitoring in System Settings (the OS will auto-revoke if the binary's codesign identity changes, which happens any time the user re-downloads the app).
3. `HotkeyBinder.bind(shortcut, inputMonitoringGranted: true, …)` runs.
4. `store.installGlobalMonitor` calls `NSEvent.addGlobalMonitorForEvents`, which returns `nil` silently.
5. `globalToken = nil`. `isDegraded` stays `false`. No banner fires. The hotkey appears bound (`currentShortcut` returns the value) but the global monitor is dead — the exact silent no-op SHELL-06 exists to prevent.

Compounding the issue: the unit test `test_bindInstallsGlobalAndLocalWhenGranted` uses a mock that returns `"global-N"` as a non-nil token, so the nil-return path is never exercised by the test suite.

**Fix:**
```swift
public func bind(
    _ shortcut: KeyboardShortcut,
    inputMonitoringGranted: Bool,
    onPress: @escaping @Sendable () -> Void
) {
    unbind()
    boundShortcut = shortcut
    if inputMonitoringGranted {
        globalToken = store.installGlobalMonitor(shortcut, onPress)
        if globalToken == nil {
            // OS silently refused — Input Monitoring was revoked or never really granted.
            // SHELL-06: this path must surface degraded-mode state, not pretend it succeeded.
            isDegraded = true
        } else {
            isDegraded = false
        }
    } else {
        isDegraded = true
    }
    localToken = store.installLocalMonitor(shortcut, onPress)
}
```
And extend the test store with a nil-returning fake:
```swift
final class DeniedGlobalMonitorStore: HotkeyMonitorStore, @unchecked Sendable {
    func installGlobalMonitor(_ s: KeyboardShortcut, _ p: @escaping @Sendable () -> Void) -> Any? { nil }
    func installLocalMonitor(_ s: KeyboardShortcut, _ p: @escaping @Sendable () -> Void) -> Any? { "local-1" as NSString }
    func remove(_: Any) {}
}

func test_nilGlobalTokenMarksDegraded() {
    let binder = HotkeyBinder(store: DeniedGlobalMonitorStore())
    binder.bind(KeyboardShortcut(keyCode: 38, modifiers: [.command]),
                inputMonitoringGranted: true) { }
    XCTAssertTrue(binder.isDegraded,
                  "SHELL-06: nil global token must mark binder degraded even when inputMonitoringGranted=true")
}
```
Additionally, the caller (`AppDelegate.bindHotkeyFromWizard`) should inspect `binder.isDegraded` post-bind and enqueue `BannerContent.hotkeyBindFailed` (the preset is already defined but never actually enqueued from production code — see WR-06).

---

## Warnings

### WR-01: `FileRotatingWriter` silently drops log lines when the FileHandle fails to open

**File:** `packages/Logging/Sources/JarvisLogging/FileRotatingWriter.swift:33-40, 42-57`
**Severity:** WARNING

**Issue:** Inside the serial dispatch queue, `rotateIfNeeded()` uses `try?` to open `FileHandle(forWritingTo:)`. If opening fails (disk full, permission revoked, volume unmounted mid-session) `currentHandle` stays `nil` and `append(_:)` silently returns without writing. The caller has no feedback — the `OSLogHandler` companion will still emit the line to `os.Logger`, but the on-disk record required by OBS-06 is lost, and the system never self-reports the loss.

Additionally, `handle.write(contentsOf:)` also uses `try?`, so a mid-session failure (disk fills up, file is deleted from under us, FD gets evicted) drops subsequent lines silently.

OBS-06's intent reads as "rotation must not lose data". The current implementation loses data to any of these failure modes without signaling.

**Fix:** At minimum, post a one-time `os.Logger` fault when `currentHandle` transitions to nil inside `append`:
```swift
func append(_ line: String) {
    queue.async {
        self.rotateIfNeeded()
        guard let handle = self.currentHandle,
              let data = line.data(using: .utf8) else {
            // One-time fault so we don't spam: emit to os.Logger subsystem only.
            if !self.warnedAboutOpenFailure {
                os.Logger(subsystem: "com.koftwentytwo.jarvis", category: "logging")
                    .fault("File log handle unavailable; dropping line")
                self.warnedAboutOpenFailure = true
            }
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // …same one-time warning
        }
    }
}
```

### WR-02: `ConfigLoader.loadSnapshots` decodes `LaunchSnapshot` and `PerTurnSnapshot` separately — silent data loss if schema migrator produces only one shape

**File:** `packages/Config/Sources/Config/ConfigLoader.swift:22-26`
**Severity:** WARNING

**Issue:** The loader decodes two independent `Codable` shapes from the same `currentData`. There is no guarantee both shapes carry every field they document. If a future schema migration drops the `provider` key from the merged blob, `PerTurnSnapshot` decoding throws; but currently both types reference overlapping subsets of keys in a single JSON document, which:
- Hides encoder round-trip asymmetry (encoding a `LaunchSnapshot` produces JSON that `PerTurnSnapshot` cannot decode and vice versa — breaking the "write default, re-read" property `writeDefaultAndReload` claims).
- Makes `SchemaMigrator` output ambiguous when a migration needs to remove a field: the migrator would have to produce a single JSON blob that both types decode correctly, which cross-couples the types.

Additionally, `ConfigLoader.loadSnapshots` throws `ConfigError.malformed(reason:)` wrapping `DecodingError.description`, which may include the raw failing JSON key path — on a malformed blob that happens to contain the user's API key (someone drops the key in config.json by mistake), the error string is logged to `~/Library/Logs/Jarvis/system.log` **before** `Redact.apply` runs, because `AppDelegate.applicationWillFinishLaunching` logs the error via `systemLogger?.critical(...)` on line 101 — this path bypasses `FileLogHandler.log` redaction if the OSLogHandler captures the same `Logger.Message` first (OSLogHandler explicitly comments "no redaction here").

**Fix:**
1. Split the JSON schema: store Launch and PerTurn blobs under separate top-level keys (`"launch": {…}, "perTurn": {…}`) and decode each from its child — makes encoder round-trip clean and isolates migration scope.
2. Redact the exception description before logging:
   ```swift
   systemLogger?.critical("Config malformed: \(Redact.apply(String(describing: e)))")
   ```

### WR-03: `OllamaConfig.validateHost` uses `URL.host` which strips brackets around IPv6 literals — but also does not reject `"::1"` via `URL.host`

**File:** `packages/Config/Sources/Config/OllamaConfig.swift:32-37`
**Severity:** WARNING

**Issue:** For `http://[::1]:11434`, `URL.host` returns `"::1"` on macOS 13+ — but on macOS < 13 (outside the declared `platforms: [.macOS(.v13)]` but still reachable in non-App contexts) the value is bracketed. The allowlist contains `"::1"` without brackets, so IPv6 configurations are fragile across macOS versions.

Additionally, the allowlist check is vulnerable to DNS rebinding on `"localhost"`: `localhost` can resolve to any IP if the user's `/etc/hosts` is compromised or if the resolver is hijacked. For SEC-relevant loopback enforcement, the correct check is post-resolution: validate the **resolved address** is within `127.0.0.0/8` or `::1/128`, not the URL host string. AGENT-05's intent is "local only"; the current check enforces "has a localhost-looking string", which is weaker.

Finally, `host?.lowercased()` is applied *after* `URL.host` — but `URL.host` already normalizes case for DNS names and returns IP literals unchanged. The `lowercased()` is harmless for IPv4 literals and `::1`, but if a future Swift stdlib version changes host normalization, the lowercase may mask a string-comparison bug.

**Fix:** Keep the current string allowlist as a first pass, but additionally require URL **scheme** == `http` (not `https`, not `ws`, not `file`, not anything else) and the port is set:
```swift
private static func validateHost(_ url: URL) throws {
    guard url.scheme == "http" || url.scheme == "https" else {
        throw ConfigError.invalidOllamaHost("unsupported scheme: \(url.scheme ?? "")")
    }
    let host = url.host ?? ""
    let normalized = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host
    guard allowedHosts.contains(normalized.lowercased()) else {
        throw ConfigError.invalidOllamaHost(host)
    }
}
```
Longer-term: resolve `localhost` via `getaddrinfo` at startup, compare the resolved IP against loopback ranges, and reject any other result.

### WR-04: `SchemaMigrator.migrate(from:to:)` has an off-by-one in the `future schema` check

**File:** `packages/Config/Sources/Config/SchemaMigrator.swift:6-8`
**Severity:** WARNING

**Issue:** The check `guard from <= to else { throw … }` rejects `from > to` as "future schema". That's correct when the caller is asking to migrate *forward* to `currentVersion`. But at `currentVersion = 1`, `migrate(data, from: 1, to: 1)` is treated as the pass-through case (loop body never runs) — which is fine — **but** `migrate(data, from: 2, to: 1)` throws `.futureSchema(version: 2)`. The test `test_futureSchemaThrows` confirms this, but the thrown value reports `version: 2` which is the `from` parameter, not the `to`. A user looking at the error message will see "future schema version 2" and think their *target* version is 2, not their source — the semantic is "you have a v2 config but Jarvis is on v1". The error value should carry both numbers, or be named `.cannotDowngradeSchema(have: Int, supports: Int)` to remove ambiguity.

Separately, `unknownSchemaVersion(v)` carries `v` as the source version, but the loop increments `v` after each step, so if we ever add multi-step migrations and one step throws `unknownSchemaVersion`, the reported `v` is the *intermediate* version, not the version the user's file actually has. Traceability suffers.

**Fix:** Carry richer context:
```swift
public enum ConfigError: Error, Sendable, Equatable {
    case malformed(reason: String)
    case unknownSchemaVersion(have: Int, supports: Int)
    case futureSchema(have: Int, supports: Int)
    // …
}
```

### WR-05: `HUDBannerCoordinator.dismissCurrent()` race — next banner can be dismissed during the 300 ms drain

**File:** `App/HUD/HUDBannerCoordinator.swift:52-65`
**Severity:** WARNING

**Issue:** The 300 ms drain timer uses `DispatchQueue.main.asyncAfter` with `[weak self]` and checks `dismissedThisLaunch.contains(next.id)`. The check prevents re-showing a banner that was explicitly dismissed — but the intervening window creates two additional races:

1. A higher-priority banner enqueued during the 300 ms drain: the `current` slot is `nil` for 300 ms, so `enqueue(_:)` sees `current == nil` and calls `showBanner(content)` immediately. Then the drain timer fires and also calls `showBanner(next)`, clobbering the higher-priority banner with the lower-priority queued one. Pre-emption logic runs once, then gets silently undone.
2. If `clear()` is called during the 300 ms window (app quitting), the drain timer still fires and shows a banner via `showBanner(next)` even though the user has asked for everything to stop.

The `queue.removeFirst()` happens *before* the async dispatch, so by the time the delayed closure runs, the item has already been popped from `queue`. If the timer is cancelled externally (impossible today — there's no cancel handle) or if the window race above occurs, the popped item is leaked without ever being shown.

**Fix:** Make the drain a property so it can be cancelled, and re-check state before calling `showBanner`:
```swift
private var drainWorkItem: DispatchWorkItem?

public func dismissCurrent() {
    if let c = current { dismissedThisLaunch.insert(c.id) }
    current = nil
    panel.orderOut(nil)
    guard !queue.isEmpty else { return }
    let next = queue.removeFirst()
    let item = DispatchWorkItem { [weak self] in
        guard let self, self.current == nil,
              !self.dismissedThisLaunch.contains(next.id) else { return }
        self.showBanner(next)
    }
    drainWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
}

public func clear() {
    drainWorkItem?.cancel()
    drainWorkItem = nil
    queue.removeAll()
    current = nil
    panel.orderOut(nil)
}
```

### WR-06: `BannerContent.hotkeyBindFailed` preset is defined but never enqueued from production code

**File:** `App/HUD/BannerContent.swift:55-62`, `App/AppDelegate.swift:251-259`
**Severity:** WARNING

**Issue:** The preset `hotkeyBindFailed` exists and is referenced by `HUDBannerCoordinatorTests`, but no production path in `AppDelegate.bindHotkeyFromWizard` checks for bind failure and enqueues it. Combined with CR-03 (nil global token silently succeeds), this means the degraded-hotkey banner literally cannot appear during real use — it only exists in test fixtures.

**Fix:** After `hotkeyBinder?.bind(...)`, inspect `binder.isDegraded` or add a return value:
```swift
private func bindHotkeyFromWizard() {
    guard let state = wizardState, let shortcut = state.hotkey else { return }
    hotkeyBinder?.bind(
        shortcut,
        inputMonitoringGranted: state.inputMonitoringGranted
    ) { [weak self] in
        Task { @MainActor [weak self] in self?.toggleHUD() }
    }
    if hotkeyBinder?.isDegraded == true {
        bannerCoordinator?.enqueue(.hotkeyBindFailed)
    }
}
```

### WR-07: `AnthropicKeyValidator` uses `URLSession.shared` — ignores proxy bypass and connection pooling isolation

**File:** `App/Wizard/AnthropicKeyValidator.swift:29, 37-42`
**Severity:** WARNING

**Issue:** The validator creates its `URLSession` default as `URLSession.shared`. `URLSession.shared` honors `URLSession.shared.configuration.connectionProxyDictionary`, which on macOS inherits from system proxy settings. In a corporate environment with a MITM proxy, **the API key is shipped in an `x-api-key` header to `api.anthropic.com` *through the corporate proxy*.** That proxy will see the plaintext TLS termination if it's configured to intercept anthropic.com — leaking the key exactly once, during the first validation attempt, before the user even knows Jarvis is doing network calls.

The file's docstring says "HTTPS is enforced by the fixed URL" — but HTTPS enforcement only guarantees the transport to the first hop, not past the proxy.

There's no `requiresClientCertificateAuthentication` hint, no `tlsMinimumSupportedProtocolVersion = .TLSv13`, and no pinning. For a one-shot API-key validation call this is defensible, but the key itself is the thing being leaked in the failure mode.

**Fix:** Use an ephemeral session with proxy disabled:
```swift
public init(client: any URLRequestClient? = nil) {
    self.client = client ?? {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // refuse system proxy for key validation
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        return URLSession(configuration: config)
    }()
}
```
Or — even safer — make key validation a deliberate user opt-in with explicit "this will make one HTTPS call to api.anthropic.com" copy, so users on corporate networks can choose to skip.

### WR-08: `TestDateProvider` uses `NSLock` but is `@unchecked Sendable` — correct, but unrelated code path for `.monotonic` vs `.wall` is not considered

**File:** `packages/Logging/Sources/JarvisLogging/DateProvider.swift:13-26`
**Severity:** WARNING

**Issue:** `Date()` is wall-clock. `FileRotatingWriter` uses the date to compute "today" via `DateFormatter.string(from:)` for rotation. If the user's clock is adjusted backwards (NTP correction, manual change, DST transition where the user is in a non-DST zone) — `today` regresses, and the existing file handle stays valid (no rotation). The log file for "today" will then contain entries from the future (pre-adjustment timestamps) interleaved with post-adjustment timestamps. Retention GC deletes files "older than 7 days" by file date; after a large clock jump forward the GC will delete everything.

Additionally, retention GC runs **inside `rotateIfNeeded()` only** — if the user keeps the app open for >7 days without any day-crossing log line (plausible: quiet app, DEBUG-level filter), retention never runs.

**Fix:** Two small changes:
1. Use `CFAbsoluteTimeGetCurrent`-backed `Date()` comparison with sanity check: if the computed new day is more than ±2 from the previous day, log a warning and rotate anyway.
2. Run GC on a periodic heartbeat (once per hour) independent of rotation, or at `applicationWillTerminate`.

### WR-09: `OnboardingWizardController.open` reads `state.currentStage` before `state.refresh()` can complete — race on `state.apiKeyStored`

**File:** `App/Wizard/OnboardingWizardController.swift:31, 53`
**Severity:** WARNING

**Issue:** `state.refresh()` is synchronous and reads the Keychain via `try? keychain.get(.anthropic)`. That call can block for up to ~500 ms under keychain lock contention (first-run ACL prompt, CI runs, locked keychain sessions). During that block the UI thread hangs — the wizard window never appears, the user sees a delay, and if the Keychain is in a prompting-state the blocking call can race with the main window's `makeKeyAndOrderFront(nil)` below.

More subtly: `state.refresh()` sets `state.apiKeyStored = (…)`. Since `WizardState` is an `@ObservableObject`, this triggers a `@Published` notification that fires observers on the next runloop tick. The `WizardView` body — which is instantiated inside `NSHostingController(rootView: rootView)` on the next line — observes `state.currentStage`, which refresh() just set. If the first publish arrives *before* `NSHostingController` has subscribed, the view renders the stale initial `currentStage = .apiKey` value and only reconciles on the next SwiftUI frame.

On first-launch + Stage 1 unresolved the outcome is correct by coincidence. On re-entry (Setup…) via non-first-launch with API key already stored, the wizard briefly shows Stage 1 (.apiKey) before jumping to Stage 2 — a visible flash of wrong UI.

**Fix:** Either make the refresh call async-off-main:
```swift
public func open(...) {
    Task { @MainActor in
        await Task.detached { state.refresh() }.value
        // now instantiate view
    }
}
```
Or move the Keychain probe into `init(keychain:)` and make `refresh()` a no-op on the first call.

### WR-10: `JarvisHUDPanel.init` uses `setValue(false, forKey: "drawsBackground")` — KVC on `WKWebView` is not part of its documented API

**File:** `App/HUD/JarvisHUDPanel.swift:48`
**Severity:** WARNING

**Issue:** The comment acknowledges this is a "private-key force" and correctly notes that `WKWebView.isOpaque` is get-only. KVC poking at a private setter works today but:
- May be rejected by App Store review (not relevant — personal use only).
- May be removed without notice in future WebKit builds (since this targets macOS 26 Tahoe the exposure window is real).
- Throws `NSUndefinedKeyException` if the key is renamed, crashing the app at launch rather than degrading gracefully.

The fix documented in `UI-SPEC Surface 7` says this is a "force" required by Tahoe; still, the KVC call should be wrapped so a future rename is a degraded-render bug (opaque background) rather than a launch crash.

**Fix:**
```swift
// Private-key KVC for transparent backing — isolate exceptions so a WebKit rename
// doesn't crash the app at launch.
let selector = NSSelectorFromString("setDrawsBackground:")
if self.webView.responds(to: selector) {
    self.webView.setValue(false, forKey: "drawsBackground")
}
```

### WR-11: `FeatureFlags` has no explicit flag-name allowlist — typos silently disable features

**File:** `packages/Config/Sources/Config/FeatureFlags.swift:11-13`
**Severity:** WARNING

**Issue:** `isEnabled(_ key: String)` returns `flags[key] ?? false`. If a caller types `"orpheusTtsEnabled"` (wrong case) or `"orpheus_tts_enabled"` (wrong separator), the call silently returns `false`. Combined with the fact that `FeatureFlags` is the primary mechanism for gating WhisperKit / Orpheus in Phase 6, a typo anywhere in the agent loop silently disables the feature with no diagnostic.

The CLAUDE.md note about `qwen2.5-coder:32b` being the known-good baseline for local tool-calling exists because these bugs are hard to catch.

**Fix:** Introduce an enum of known flag keys and route callers through it:
```swift
public enum FeatureFlag: String, CaseIterable, Sendable {
    case orpheusTTSEnabled
    case whisperKitSTTEnabled
}

public struct FeatureFlags: Sendable, Codable, Equatable {
    private let flags: [String: Bool]
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag.rawValue] ?? false
    }
    // …
}
```
Keep the string-keyed `isEnabled(_: String)` as a deprecated-in-docs fallback for dynamic inspection (dev overlay) but make the enum path the canonical one.

### WR-12: `verify-entitlements.sh --post-codesign` swallows `codesign` stderr via `2>&1 || true`

**File:** `scripts/verify-entitlements.sh:92, 123`
**Severity:** WARNING

**Issue:**
```bash
EXTRACTED="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>&1 || true)"
```
This merges stdout+stderr and suppresses the exit code. If `codesign` fails (binary not signed, identity mismatch, corrupted bundle), `EXTRACTED` will contain an error message like `"$APP: not signed"` — the subsequent `grep -q "<key>com.apple.security.cs.allow-jit</key>"` will not match, and the script will correctly exit 1.

**But** the `HELPER_ENTS="$(… 2>&1 || true)"` for helpers on line 123 has the same pattern: if `codesign -d` fails on a helper, `HELPER_ENTS` carries the failure text, and the grep for `automation.apple-events` succeeds or fails based on *error message content*. In the worst case, a helper whose binary was deleted between the codesign step and the verify step reports `"no such file"`, which happens to not contain `"apple-events"`, so the verification passes — letting an unsigned helper ship.

The script should `set -eo pipefail` **and** check `codesign`'s exit code explicitly before grepping:
```bash
if ! EXTRACTED="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null)"; then
    echo "error: codesign -d failed on $APP" >&2
    exit 1
fi
```

Also, `find "$HELPERS_DIR" -depth -name "*.app" -type d` with `-depth` traverses bottom-up — which is correct for signing (deepest-first) — but for `verify --post-codesign` the traversal direction doesn't matter. Using `-depth` here harms readability without providing correctness benefit.

---

## Info

### IN-01: `ISO8601DateFormatter.jarvisShared` uses `nonisolated(unsafe)` — justified, but the justification should be tested

**File:** `packages/Logging/Sources/JarvisLogging/FileLogHandler.swift:44-54`

**Issue:** The comment claims `ISO8601DateFormatter` is "documented thread-safe since macOS 10.12" — but Apple's actual guarantee is "once fully configured, concurrent calls to `string(from:)` are safe." The formatter here is configured in the closure initializer and never mutated afterward, so the claim holds. Still, add a light concurrent-access unit test that smoke-tests the assumption:
```swift
func test_sharedFormatterIsConcurrentSafe() async {
    await withTaskGroup(of: String.self) { group in
        for _ in 0..<100 {
            group.addTask {
                ISO8601DateFormatter.jarvisShared.string(from: Date())
            }
        }
        for await s in group {
            XCTAssertFalse(s.isEmpty)
        }
    }
}
```

### IN-02: `OSLogHandler` marks every message `privacy: .public` — defeats the `%{private}@` guard mentioned in the docstring

**File:** `packages/Logging/Sources/JarvisLogging/OSLogHandler.swift:30-33`

**Issue:** The comment says "os.Logger handles `%{private}@` at system layer. Discipline: callers must redact untrusted input BEFORE passing to Logger." But the actual implementation substitutes `.public` for every message, which **removes the private-data masking that os.Logger provides by default.** On a Console.app capture the full message is visible to any user with the right entitlement, including messages that carry untrusted input before the caller redacts.

`Redact.apply` runs *only* in `FileLogHandler.log` — not in `OSLogHandler.log` — so a message like `logger.info("saving key \(userInput)")` produces a redacted line in the file log but a **plaintext** line in `os.Logger`. The docstring calls this out but the cure (caller redacts first) is on the honor system with no enforcement.

**Fix:** Either make the dispatch private-by-default:
```swift
logger.log(level: osLevel, "\(message, privacy: .private(mask: .hash))")
```
Or run `Redact.apply` in both handlers.

### IN-03: `MenuBarIconController.configureButton` sets `button.image` from `NSImage(named: "Icon-MenuBar-Template")` without error handling

**File:** `App/MenuBar/MenuBarIconController.swift:70-71`

**Issue:** `NSImage(named:)` returns `nil` if the asset is missing; `button.image?.isTemplate = true` then runs on a nil value and silently does nothing. The menu-bar icon falls back to a blank text title (since `statusItem.button?.title` wasn't set), which makes the app unreachable. Not critical — user can still right-click the blank button — but worth a one-line `assertionFailure` in Debug so the missing asset is noticed at dev time rather than shipped.

### IN-04: `HUDBannerPanel.positionTopTrailing` reads `contentView?.fittingSize.height` — may return 0 before layout

**File:** `App/HUD/HUDBannerPanel.swift:45`

**Issue:** Called from `host(_ view:)` immediately after `self.contentView = NSHostingView(rootView: view)`. `NSHostingView` computes `fittingSize` lazily; before the first layout pass `fittingSize.height` can be 0, which combined with `visibleFrame.maxY - bannerHeight - 8` positions the banner 8 pt below the top edge with unpredictable height. The `?? 96` fallback covers the nil case but not the zero-height case.

**Fix:** Force a layout pass:
```swift
public func host(_ view: some View) {
    self.contentView = NSHostingView(rootView: view)
    self.contentView?.layoutSubtreeIfNeeded()
    self.positionTopTrailing()
}
```

### IN-05: `AppDelegate.copyStateDump` uses `ISO8601DateFormatter()` instead of the shared cached formatter

**File:** `App/AppDelegate.swift:281`

**Issue:** Every invocation allocates a new formatter. Not a performance concern at this call volume, but inconsistent with `FileLogHandler` which caches one. Switch to:
```swift
payload["timestamp"] = ISO8601DateFormatter.jarvisShared.string(from: Date())
```
Requires promoting the extension from `FileLogHandler.swift` to a public helper in `JarvisLogging`.

### IN-06: `project.yml` declares `Carbon` framework dependency for Shell, but production code only uses `Carbon.HIToolbox` for constants

**File:** `packages/Shell/Package.swift:26`

**Issue:** `.linkedFramework("Carbon")` links the full Carbon framework even though `Carbon.HIToolbox` is only used for `kVK_*` constants (which are C `#define`s that don't require runtime linking — the Swift import brings them in as compile-time constants). Redundant framework link adds ~600 KB to the binary and pulls in an entire deprecated API surface.

**Fix:** Drop the `.linkedFramework("Carbon")` line; the `Carbon.HIToolbox` import in `CollisionDetector.swift` / `KeyCapView.swift` / `ShortcutRecorderHostView.swift` compiles without the linker flag because the `kVK_*` values resolve at compile time.

### IN-07: `AppDelegateWiringTests.test_stateDumpDoesNotIncludeAPIKey` is a tautology — claims to test SEC-01 but only runs `applicationWillFinishLaunching`

**File:** `App/Tests/AppTests/AppDelegateWiringTests.swift:105-123`

**Issue:** The test's docstring says the invariant "is enforced at source level by the grep gate in acceptance criteria" and the test "asserts the positive path launches without errors so the design invariant at least compiles." `XCTAssertTrue(true)` is the body — this test literally cannot fail on a SEC-01 regression. A meaningful test would invoke `copyStateDump()`, read `NSPasteboard.general.string(forType: .string)`, and assert it does not contain `"sk-ant-"`. That's not a performance issue — it's a real regression gate that's currently absent.

**Fix:**
```swift
func test_stateDumpDoesNotIncludeAPIKey() {
    // (setup as before, with keychainStore returning "sk-ant-actual-value")
    delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
    // Trigger the state dump via the private selector (or expose a test seam).
    delegate.perform(Selector("copyStateDump"))
    let pasteboardContents = NSPasteboard.general.string(forType: .string) ?? ""
    XCTAssertFalse(pasteboardContents.contains("sk-ant-"),
                   "State dump must never include the raw API key (SEC-01)")
    XCTAssertFalse(pasteboardContents.contains("anthropic-test-key"),
                   "State dump must never include the keychain value")
    cleanUp(delegate)
}
```
Alternatively, expose `copyStateDump` internally for tests:
```swift
#if DEBUG
internal var _copyStateDumpForTest: () -> Void { copyStateDump }
#endif
```

---

_Reviewed: 2026-04-22_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
