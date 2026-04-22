# Phase 1: Foundations — Pattern Map

**Mapped:** 2026-04-22
**Files analyzed:** 51 (46 source / scripts + 5 asset-catalog / entitlements / plist / directory-layout entries)
**Analogs found:** 0 / 51 (greenfield — repo holds only planning artifacts)
**Reference sources:** external URLs and well-known library modules are cited per row in lieu of local analogs, per phase-mapper instructions for greenfield phases

---

## Greenfield Notice

The repository contains **only** `CLAUDE.md`, `README.md`, `.claude/`, and `.planning/` at this commit. No Swift, no SPM packages, no Xcode project, no entitlements plist, no scripts, no webview bundle, no `Contents/Helpers/` skeleton. Every row in this document is a new file with **no local analog**. The "Reference pattern" column carries an external URL, SDK docs link, or well-known library module so each plan's `read_first` block has a citable target.

RESEARCH.md §"Runtime State Inventory" is explicitly omitted on researcher's instruction ("Omit entirely for greenfield phases"). This pattern map follows the same posture.

---

## File Classification

Columns:
- **File** — path the planner will create (relative to repo root).
- **Role** — project-convention role label.
- **Data flow** — what the file reads/writes/transforms at runtime or build time.
- **Reference pattern** — external citation that exemplifies the shape (URL or well-known library/API).
- **Match** — always `no-analog (greenfield)` in P1.

### A. Xcode project + top-level layout

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `Jarvis.xcodeproj/project.pbxproj` | xcode-project | declares App target + local SPM package refs; consumed by `xcodebuild` | Apple "Configuring your Xcode project for distribution" (Hardened Runtime, CODE_SIGN_STYLE=Manual) — https://developer.apple.com/documentation/xcode/configuring-the-build-settings-of-a-target | no-analog (greenfield) |
| `App/Jarvis.entitlements` | entitlements-plist | signed into main binary by `scripts/codesign.sh`; read at runtime by `AppDelegate` hard-block | RESEARCH.md §Standard Stack > Entitlements (`allow-jit`, `speech-recognition-assets`, `device.audio-input`); Apple Hardened Runtime docs — https://developer.apple.com/documentation/security/hardened_runtime | no-analog (greenfield) |
| `App/Info.plist` | info-plist | declares `LSUIElement`, `NSSpeechRecognitionAssetsUsageDescription`, `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `NSAppleEventsUsageDescription`, `JarvisEntitlementsVerified=NO` (flipped at build); read by AppKit + `Bundle.main.object(forInfoDictionaryKey:)` | Apple "Information Property List" — https://developer.apple.com/documentation/bundleresources/information_property_list | no-analog (greenfield) |
| `packages/` (directory) | directory-layout | container for local SPM packages; referenced by `Jarvis.xcodeproj` as local package refs | SPM local-package pattern — https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app | no-analog (greenfield) |
| `Jarvis.app/Contents/Helpers/` (built layout) | directory-layout | empty in P1; populated by P5 MCP helper `.app` bundles; traversed by `scripts/codesign.sh` deepest-first | Apple TN2206 "macOS Code Signing In Depth" (nested bundles) — https://developer.apple.com/library/archive/technotes/tn2206/_index.html | no-analog (greenfield) |
| `~/Library/Application Support/Jarvis/` (runtime) | runtime-dir | created by `ConfigLoader` on first launch; holds `config.json`; future `jarvis.db` in P7 | `FileManager.default.url(for: .applicationSupportDirectory, ...)` — https://developer.apple.com/documentation/foundation/filemanager | no-analog (greenfield) |
| `~/Library/Logs/Jarvis/` (runtime) | runtime-dir | created by `FileLogHandler` on first log write; rotated daily; retain-7 | `FileManager` + swift-log ecosystem convention (`Puppy` FileLogger path convention) — https://github.com/sushichop/Puppy (pattern only; not used) | no-analog (greenfield) |

### B. App target — `@main` / lifecycle / wiring (D-02: lifecycle-only)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `App/JarvisApp.swift` | app-entrypoint | `@main` Swift struct + `NSApplicationDelegateAdaptor`; hosts SwiftUI `WindowGroup`s for wizard and `Settings` scene | SwiftUI app-lifecycle with AppKit adaptor — https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor | no-analog (greenfield) |
| `App/AppDelegate.swift` | app-delegate | `applicationWillFinishLaunching`: (1) `JarvisLogHandlerFactory.bootstrap()` (2) read `JarvisEntitlementsVerified` from `Info.plist` → NSAlert hard-block on false (3) `ConfigLoader.loadSnapshots` (4) `Keychain.fetch(.anthropic)` (5) install `NSStatusItem`+`MenuBarIconController` (6) install `JarvisHUDPanel` (7) install hotkey via `HotkeyBinder` after `IOHIDRequestAccess` probe | RESEARCH.md §Pattern 1 (Pattern 1 — AppDelegate entitlement hard-block, lines 1249-1294); `NSApplicationDelegate.applicationWillFinishLaunching` — https://developer.apple.com/documentation/appkit/nsapplicationdelegate/1428385-applicationwillfinishlaunching | no-analog (greenfield) |

### C. Menu-bar surface (App target — Surface 3 + 4)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `App/MenuBar/MenuBarIconController.swift` | NSStatusItem-controller (`@MainActor`) | owns `NSStatusItem`; installs template PDF into `button.image`; drives `CABasicAnimation` on `button.layer` for 5 states (idle/listening/thinking/speaking/awaitingConfirmation); observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` for Reduce Motion; rate-limited VoiceOver announcement | RESEARCH.md §Question 7 (lines 751-869) — full 100-LOC shape; Apple DevForums thread 88341 (status-item rotation gotcha) — https://developer.apple.com/forums/thread/88341; onmyway133 "How to rotate NSStatusItem" — https://onmyway133.com/posts/how-to-rotate-nsstatusitem/ | no-analog (greenfield) |
| `App/MenuBar/MenuBarContextMenu.swift` | NSMenu-builder | builds `NSMenu` attached via right-click / Ctrl-click (left-click is NOT menu — see Surface 3); items: Setup… / Settings… (disabled stub) / Show Dev Overlay / Copy State Dump / Quit (⌘Q) | UI-SPEC Surface 4 (lines 425-447); `NSStatusItem.popUpMenu` pattern — https://developer.apple.com/documentation/appkit/nsstatusitem | no-analog (greenfield) |
| `App/MenuBar/CAAnimationFactory.swift` (Open Item for Planner #10) | animation-utility | pure helpers returning `CABasicAnimation`/`CAKeyframeAnimation`; every helper consults `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and returns a fallback; also provides `CATransition(type:.fade, duration:0.15)` for crossfades | RESEARCH.md §Question 7 `makeBreath`/`makeRotate`/`makeShimmer`/`makeGlow` excerpts (lines 818-858); `CABasicAnimation` — https://developer.apple.com/documentation/quartzcore/cabasicanimation | no-analog (greenfield) |

### D. HUD panel surface (App target — Surface 5 + 7)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `App/HUD/JarvisHUDPanel.swift` | NSPanel-subclass | borderless 720×720 `NSPanel` hosting blank `WKWebView`; `styleMask=[.borderless,.nonactivatingPanel]`, `level=.statusBar`, `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.transient]`, `backgroundColor=.clear`, `isOpaque=false`; exposes `summon()`/`dismiss()`; overrides `cancelOperation(_:)` for Escape-dismiss; Reduce-Transparency fallback via `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` | UI-SPEC Surface 7 (lines 536-592); Apple `NSPanel` — https://developer.apple.com/documentation/appkit/nspanel; WKWebView transparency docs — https://developer.apple.com/documentation/webkit/wkwebview | no-analog (greenfield) |
| `App/HUD/HUDBannerPanel.swift` | NSPanel-subclass | separate floating panel for degraded-mode banners (Input Monitoring denied, Keychain empty, hotkey-bind failure, ollama URL rejected); 360pt × variable height; top-trailing-corner positioning per active display; `.floating` level, `.nonactivatingPanel`; hosts SwiftUI `HUDBanner` view via `NSHostingView` | UI-SPEC Surface 5 (lines 450-503); `NSVisualEffectView.Material.hudWindow` — https://developer.apple.com/documentation/appkit/nsvisualeffectview/material | no-analog (greenfield) |
| `App/HUD/HUDBannerCoordinator.swift` | coordinator (`@MainActor final class`) | owns queue of pending `BannerContent`; priority order keychain-empty > InputMon-denied > hotkey-bind-fail > ollama-rejected; shows one at a time; dismissal state "dismissed this launch" persists until app relaunch OR condition re-triggers | UI-SPEC Surface 5 "Per-condition lifecycle" (lines 481-486) | no-analog (greenfield) |
| `App/HUD/HUDBanner.swift` | SwiftUI-view | renders title + body + action button; accent stripe leading edge (BrandColor.arcReactorGlow); announces via `AccessibilityNotification.announcement` on appearance | UI-SPEC Surface 5 copywriting table (lines 219-225) + internal layout spec | no-analog (greenfield) |

### E. Onboarding wizard (App target — Surface 1)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `App/Wizard/WizardView.swift` | SwiftUI-root | owns `@State stage: WizardStage` and `@ObservedObject state: WizardState`; 560×440 fixed-size window; three-stage progress-dots header; `.windowStyle(default)`; first-launch: `NSWindow.level = .modalPanel` + close button disabled until stage 1 done; Setup-reentry: free Escape/close | UI-SPEC Surface 1 (lines 256-310); SwiftUI `WindowGroup` — https://developer.apple.com/documentation/swiftui/windowgroup | no-analog (greenfield) |
| `App/Wizard/WizardStageAPIKeyView.swift` | SwiftUI-form-view | `SecureField("Anthropic API key")` → live Anthropic `models/list` probe via `URLSession` → on success `Keychain.set(apiKey, for: .anthropic)`; inline error states (malformed / 401 / network / generic) | UI-SPEC Surface 1 copy table (lines 123-145); Anthropic Messages API reference — https://docs.anthropic.com/en/api/models-list | no-analog (greenfield) |
| `App/Wizard/WizardStageTCCView.swift` | SwiftUI-form-view | four rows (Input Monitoring — active prompt; Microphone / Camera / Automation — explainer-only per D-08); IM row probes `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` and updates granted/denied state | UI-SPEC Surface 1 stage 2 (lines 146-171); IOKit.hid `IOHIDRequestAccess` — https://developer.apple.com/documentation/iokit/iohidrequestaccess | no-analog (greenfield) |
| `App/Wizard/WizardStageHotkeyView.swift` | SwiftUI-form-view | hosts `ShortcutRecorderView` (from `packages/Shell`); writes bound shortcut into config; collision warnings inline | UI-SPEC Surface 1 stage 3 (lines 173-190) | no-analog (greenfield) |
| `App/Wizard/WizardState.swift` | view-state (`@MainActor ObservableObject`) | re-reads per D-09: Keychain item presence, TCC grant state, config hotkey binding; `openSetup(atFirstUnresolved:)` entry point called by menu-bar "Setup…" item | UI-SPEC Surface 1 "Component structure" (lines 268-275) + D-09 wizard stateless reentry | no-analog (greenfield) |
| `App/Wizard/OnboardingWizardController.swift` | window-hosting-controller (`@MainActor`) | bridges SwiftUI root to AppKit `NSWindow` (first-launch modal vs reentry non-modal); positioning, close-button enable/disable; observes first-unresolved-stage resolution | SwiftUI-in-AppKit hosting — `NSHostingController` — https://developer.apple.com/documentation/swiftui/nshostingcontroller | no-analog (greenfield) |

### F. Theme / assets (App target)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `App/Theme/BrandColors.swift` | theme-constants | `BrandColor.arcReactorGlow` with light/dark variants (`#1E88E5`@85% / `#64B5F6`@90%); fallback to `NSColor.controlAccentColor` when `accessibilityDisplayShouldIncreaseContrast == true` | UI-SPEC §Color Custom brand tokens (lines 94-113); `NSColor.controlAccentColor` — https://developer.apple.com/documentation/appkit/nscolor/3000782-controlaccentcolor | no-analog (greenfield) |
| `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf` | asset (PDF vector) | 22pt × 22pt arc-reactor silhouette (outer 18pt stroke ring + mid 12pt ring + inner 4pt filled core + 6 radial spokes); `isTemplate = true` | UI-SPEC Surface 3 asset spec (lines 374-383); Apple "Creating custom symbol images for your app" template-rendering-intent docs — https://developer.apple.com/documentation/xcode/configuring-and-displaying-images-in-your-app | no-analog (greenfield) |
| `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` | asset-catalog-metadata | `"template-rendering-intent": "template"` + `"preserves-vector-representation": true` | Apple Asset Catalog format reference — https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format | no-analog (greenfield) |
| `App/Assets.xcassets/AppIcon.appiconset/` (placeholder) | asset (icon set) | placeholder blue-circle-with-J per Open Item for Planner #2; flagged for post-P1 real art | Apple macOS app-icon sizing requirements — https://developer.apple.com/design/human-interface-guidelines/app-icons | no-analog (greenfield) |
| `App/Assets.xcassets/AccentColor.colorset/` | asset (color set) | **not overridden in P1** — deliberately empty / deferred so user's system Accent Color applies | UI-SPEC §Asset Inventory line 631 ("P1 does NOT override accent color") | no-analog (greenfield) |

### G. `packages/Keychain` (new SPM package)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `packages/Keychain/Package.swift` | spm-manifest | Swift 6 strict (`swiftLanguageMode(.v6)`); library product + test target; zero deps | RESEARCH.md §D-04 + Apple SPM manifest reference — https://developer.apple.com/documentation/packagedescription | no-analog (greenfield) |
| `packages/Keychain/Sources/Keychain/KeychainItem.swift` | model (`Sendable struct`) | `{ service, account }` pair; constant `.anthropic = KeychainItem(service: "com.koftwentytwo.jarvis", account: "anthropic")` (D-10) | RESEARCH.md §Question 1 (lines 154-167) | no-analog (greenfield) |
| `packages/Keychain/Sources/Keychain/KeychainError.swift` | error-enum (`Sendable`) | `itemNotFound` / `duplicateItem` / `unexpectedStatus(OSStatus)`; translates `OSStatus` | RESEARCH.md §Question 1 (lines 162-167); Apple Security errSec* reference — https://developer.apple.com/documentation/security/1542001-security_framework_result_codes | no-analog (greenfield) |
| `packages/Keychain/Sources/Keychain/KeychainStore.swift` | protocol (`Sendable`) | `set / get / delete` API; injected into `AnthropicProvider` (P4) | RESEARCH.md §Question 1 (lines 169-173) | no-analog (greenfield) |
| `packages/Keychain/Sources/Keychain/SystemKeychainStore.swift` | service (Security.framework wrapper, ~60 LOC) | `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` via `kSecClassGenericPassword`; idempotent `set()` tries update then add; fetch-per-request (never cached — Pitfalls §Security posture) | RESEARCH.md §Question 1 full excerpt (lines 175-234); Apple Keychain Services — https://developer.apple.com/documentation/security/keychain_services | no-analog (greenfield) |
| `packages/Keychain/Tests/KeychainTests/KeychainTests.swift` | xctest-suite | `test_setGetDeleteRoundTrip`; uses a random per-test `account` suffix to isolate from real Keychain state | Apple XCTest reference — https://developer.apple.com/documentation/xctest | no-analog (greenfield) |

### H. `packages/Config` (new SPM package)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `packages/Config/Package.swift` | spm-manifest | Swift 6 strict; depends on `packages/Keychain`; exposes `Config` library + tests | RESEARCH.md §Recommended Project Structure (dep graph: Shell → Config → Keychain) | no-analog (greenfield) |
| `packages/Config/Sources/Config/LaunchSnapshot.swift` | model (`Sendable Codable Equatable struct`) | frozen-after-load; holds `ollama` / `applescript` / `toolBlocklist` / `confirmationPolicy` / `logging`; restart required to change | RESEARCH.md §Question 5 (lines 613-623) | no-analog (greenfield) |
| `packages/Config/Sources/Config/PerTurnSnapshot.swift` | model (`Sendable Codable Equatable struct`) | mutable-at-runtime; holds `provider` / `tts` / `stt` / `featureFlags` (OBS-05); applied at next `submit()` | RESEARCH.md §Question 5 (lines 625-632) + §Pattern 2 (lines 1296-1303) | no-analog (greenfield) |
| `packages/Config/Sources/Config/OllamaConfig.swift` | model with custom decoder | `init(from decoder:)` validates `baseURL.host` ∈ `{127.0.0.1, localhost, ::1}` → throws `ConfigError.invalidOllamaHost` otherwise (AGENT-05) | RESEARCH.md §Question 5 (lines 634-643) | no-analog (greenfield) |
| `packages/Config/Sources/Config/FeatureFlags.swift` | model (Codable dictionary-backed) | `isEnabled(_ key: String) -> Bool`; lives in PerTurnSnapshot only; SEC-08 prohibits security-affecting flags | RESEARCH.md §Pattern 2 (lines 1296-1303) | no-analog (greenfield) |
| `packages/Config/Sources/Config/ConfigStore.swift` | actor / service | reads `~/Library/Application Support/Jarvis/config.json`; publishes `(LaunchSnapshot, PerTurnSnapshot)`; `DispatchSource.makeFileSystemObjectSource` file watcher; on launch-key drift → enqueue HUD banner "Config change requires restart" | RESEARCH.md §Question 5 restart-required section (lines 677-680); `DispatchSource` — https://developer.apple.com/documentation/dispatch/dispatchsource | no-analog (greenfield) |
| `packages/Config/Sources/Config/ConfigLoader.swift` | static-loader | `loadSnapshots(from:)` → peek `schemaVersion` → `SchemaMigrator.migrate` → decode both snapshots from same document; on missing file writes default-embedded config then re-reads | RESEARCH.md §Question 5 (lines 650-667) | no-analog (greenfield) |
| `packages/Config/Sources/Config/SchemaMigrator.swift` | migration-dispatcher | `currentVersion = 1`; `migrate(data, from:to:)` + `migrateStep(data, fromVersion:)` switch — empty in P1; fixture tests per migration | RESEARCH.md §Question 6 (lines 716-741); VersionedCodable pattern — https://github.com/jrothwell/VersionedCodable | no-analog (greenfield) |
| `packages/Config/Sources/Config/ConfigError.swift` | error-enum (`Sendable`) | `malformed(reason:)` / `unknownSchemaVersion(Int)` / `futureSchema(version:)` / `invalidOllamaHost(String)`; NSAlert hard-block on decode failure | RESEARCH.md §Question 5 malformed-config section (lines 670-675) | no-analog (greenfield) |
| `packages/Config/Resources/default-config.json` | resource (bundled) | `schemaVersion: 1`; default shape per RESEARCH.md Q6 (lines 691-711); written to app-support on missing | RESEARCH.md §Question 6 single-file shape (lines 691-711) | no-analog (greenfield) |
| `packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift` | xctest-suite | `test_ollamaBaseURLMustBeLocalhost` (AGENT-05 adversarial: `http://evil.com/` → decode fails); `test_featureFlagsNotInLaunchSnapshot` | RESEARCH.md §Validation table rows for AGENT-05 + OBS-05 (lines 1434-1442) | no-analog (greenfield) |
| `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift` | xctest-suite | `test_featureFlagAppliesNextSubmit` with mock orchestrator | RESEARCH.md §Validation table OBS-05 row (line 1441) | no-analog (greenfield) |
| `packages/Config/Tests/ConfigTests/ConfigSplitTests.swift` | xctest-suite | `test_securityKeysInLaunchOnly`; `test_nonSecurityKeysInPerTurnOnly`; `test_noSkipAllowlistKey` (SEC-08 — reflects over both snapshot field lists) | RESEARCH.md §Validation table SEC-05 + SEC-08 rows (lines 1451-1452) | no-analog (greenfield) |
| `packages/Config/Tests/ConfigTests/SchemaMigratorTests.swift` | xctest-suite | empty in P1 (no migrations yet) but asserts `currentVersion == 1` + round-trip decode of default | RESEARCH.md §Question 6 "fixture test" note (line 745) | no-analog (greenfield) |
| `packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift` | xctest-suite | `test_apiKeyNotInConfigJSON` — decodes `LaunchSnapshot` with an injected `"apiKey"` key and asserts it is NOT surfaced anywhere in the snapshot (SEC-01 defense-in-depth) | RESEARCH.md §Validation table SEC-01 row (line 1447) | no-analog (greenfield) |

### I. `packages/Logging` (new SPM package)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `packages/Logging/Package.swift` | spm-manifest | Swift 6 strict; depends on `apple/swift-log` 1.5.3+; exposes `Logging` library + tests | RESEARCH.md §Standard Stack (line 1075); swift-log — https://github.com/apple/swift-log | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/JarvisLogChannel.swift` | enum (`Sendable CaseIterable`) | four cases `agent/tools/ui/system`; `rawValue` is the swift-log `Logger(label:)` argument | RESEARCH.md §Question 3 factory (lines 391-393) | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/LoggingBootstrap.swift` | bootstrap-service | exposes `JarvisLogHandlerFactory.bootstrap()` → `LoggingSystem.bootstrap(JarvisLogHandlerFactory.make)`; single call site at `AppDelegate.applicationWillFinishLaunching` (anti-pattern callout: never bootstrap from package init) | RESEARCH.md §Question 3 (lines 386-416); swift-log `LoggingSystem.bootstrap` — https://github.com/apple/swift-log/blob/main/Sources/Logging/Logging.swift | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/FileLogHandler.swift` | LogHandler-conformance (hand-rolled, ~80 LOC) | writes to `~/Library/Logs/Jarvis/{label}.log`; applies `Redact.apply` BEFORE `writer.append`; metadata merged per-log | RESEARCH.md §Question 3 (lines 436-477); swift-log `LogHandler` protocol — https://github.com/apple/swift-log | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/FileRotatingWriter.swift` | serial-writer (`@unchecked Sendable`) | serial `DispatchQueue`; lazy rotation on first post-midnight append; opens `{baseName}.{YYYY-MM-DD}.log`; GC files older than 7 days on rotation | RESEARCH.md §Question 3 (lines 479-488); `DispatchQueue(label:attributes:)` — https://developer.apple.com/documentation/dispatch/dispatchqueue | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/OSLogHandler.swift` | LogHandler-conformance | wraps `os.Logger(subsystem: "com.koftwentytwo.jarvis", category: label)`; does NOT call `Redact.apply` (os.Logger handles `%{private}@` at system layer) | RESEARCH.md §Question 3 hook-placement note (line 493); Apple `os.Logger` — https://developer.apple.com/documentation/os/logger | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/Redact.swift` | utility (stateless) | single precompiled `NSRegularExpression` with 5 alternation branches (sk-ant-*, OpenAI sk-*, Authorization:Bearer, AKIA*, ghp_*); exposes `Redact.apply(_ input: String) -> String`; OBS-06 / D-20 spec-minimum — nothing more | RESEARCH.md §Question 3 Redact (lines 498-525 spans into 501-525 excerpt); `NSRegularExpression` — https://developer.apple.com/documentation/foundation/nsregularexpression | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/LogPaths.swift` | path-helper | `LogPaths.channelDirectory` → `~/Library/Logs/Jarvis/`; creates directory lazily | `FileManager.url(for: .libraryDirectory, in: .userDomainMask, ...)` — https://developer.apple.com/documentation/foundation/filemanager | no-analog (greenfield) |
| `packages/Logging/Sources/Logging/DateProvider.swift` | protocol (`Sendable`) | `DateProvider` + `SystemDateProvider` + `TestDateProvider` for `FileLogHandler` rotation testability | RESEARCH.md §Question 3 (line 452-461, `dateProvider: any DateProvider`) | no-analog (greenfield) |
| `packages/Logging/Tests/LoggingTests/RedactTests.swift` | xctest-suite | `test_allFivePatterns` (each of 5 branches matches); `test_plainTextUnchanged` (non-matches pass through); `test_overlappingPatterns` (e.g. `sk-ant-…` wins over `sk-…`) | RESEARCH.md §Validation table OBS-06 row (line 1444) | no-analog (greenfield) |
| `packages/Logging/Tests/LoggingTests/FileLogHandlerTests.swift` | xctest-suite | `test_rotatesAtDayBoundary` (inject `TestDateProvider` → advance past midnight → expect new file); `test_deletesBeyondSeven` (seed 10 days of files → trigger rotation → expect exactly 7 remaining) | RESEARCH.md §Validation table OBS-06 row (line 1445) | no-analog (greenfield) |
| `packages/Logging/Tests/LoggingTests/LoggingTests.swift` | xctest-suite | `test_fourChannelsMultiplexToFileAndOSLog` — bootstrap + 4 `Logger(label:)` call sites → assert file handler + mock os.Logger both receive each event | RESEARCH.md §Validation table OBS-06 row (line 1443) | no-analog (greenfield) |

### J. `packages/Shell` (new SPM package)

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `packages/Shell/Package.swift` | spm-manifest | Swift 6 strict; depends on `packages/Config` and `packages/Logging`; exposes `Shell` library + tests; links against `ServiceManagement`, `IOKit.hid`, `Carbon.HIToolbox` (kVK_* constants only) | RESEARCH.md §Recommended Project Structure dep graph + §Standard Stack system frameworks (lines 1079-1086) | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/HotkeyBinder.swift` | service (`@MainActor`) | installs `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` for the bound shortcut; local-monitor fallback when Input Monitoring denied; unregister on rebind | RESEARCH.md §Summary bullet 11 (line 23); `NSEvent.addGlobalMonitorForEvents` — https://developer.apple.com/documentation/appkit/nsevent/1535472-addglobalmonitorforevents | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/InputMonitoringProbe.swift` | service | calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` at launch and on first hotkey registration; returns granted/denied; triggers `HUDBannerCoordinator.enqueue(.inputMonitoringDenied)` on denial (SHELL-06) | `IOHIDRequestAccess` — https://developer.apple.com/documentation/iokit/iohidrequestaccess; RESEARCH.md §Summary bullet 11 | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/KeyboardShortcut.swift` | model (`Sendable Codable Equatable`) | `{ keyCode: UInt16, modifiers: NSEvent.ModifierFlags.RawValue }`; serialized into PerTurnSnapshot | RESEARCH.md §Question 8 (lines 895-898) | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift` | SwiftUI `NSViewRepresentable` | wraps `ShortcutRecorderHostView`; `@Binding var shortcut: KeyboardShortcut?` + `@Binding var errorMessage: String?`; `Coordinator` routes recorded/rejected callbacks | RESEARCH.md §Question 8 (lines 900-927); `sindresorhus/KeyboardShortcuts` RecorderCocoa.swift (pattern only; not used) — https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/RecorderCocoa.swift | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift` | custom `NSView` | overrides `becomeFirstResponder` → installs `NSEvent.addLocalMonitorForEvents([.keyDown,.flagsChanged])`; `keyCode == kVK_Escape` → abort; modifier-only / shift-only → reject with inline error; Tab passes through; `resignFirstResponder` removes monitor | RESEARCH.md §Question 8 (lines 929-979); `NSEvent.addLocalMonitorForEvents` — https://developer.apple.com/documentation/appkit/nsevent/1534971-addlocalmonitorforevents | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/ShortcutRecorder/KeyCapView.swift` | SwiftUI-view | renders a single modifier or key cap (6pt × 2pt padding non-multiple-of-4 exception per UI-SPEC); `+` separators between caps | UI-SPEC Surface 2 visual spec (lines 326-330) | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift` | static-map lookup | known collisions `[(KeyCombo, [App])]`: Cmd+Shift+J → Chrome/Slack/VSCode; Option+Space → Alfred/Raycast; returns warning text per UI-SPEC copy | RESEARCH.md §Question 8 (lines 984-988); UI-SPEC Surface 1 stage 3 collision copy (lines 184-186) | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/LaunchAtLoginController.swift` | service | wraps `SMAppService.mainApp.register()` / `.unregister()`; exposes `isEnabled`, `requiresApproval`, `openSystemSettingsLoginItems()`; handles 4 `SMAppService.Status` cases; scaffolded but not yet wired to UI in P1 | RESEARCH.md §Question 9 full excerpt (lines 1003-1054); `SMAppService.mainApp` — https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp; nilcoalescing pattern — https://nilcoalescing.com/blog/LaunchAtLoginSetting/ | no-analog (greenfield) |
| `packages/Shell/Sources/Shell/TCCAlertService.swift` | HIG-compliant service | builds `NSAlert` instances with `.critical` style for hard-blocker conditions (missing entitlement, entitlement-grep fail, malformed config); "Show Details" opens `~/Library/Logs/Jarvis/system.log` in Console.app via `NSWorkspace.shared.open` | UI-SPEC Surface 6 (lines 506-532); `NSAlert.Style.critical` — https://developer.apple.com/documentation/appkit/nsalert/style | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/MenuBarIconControllerTests.swift` | xctest-suite | `test_statusItemInstalledOnLaunch`; state-machine transitions update `accessibilityLabel` | RESEARCH.md §Validation table SHELL-01 row (lines 1422-1423) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift` | xctest-suite | `test_modifierOnlyRejected`; `test_shiftOnlyRejected`; `test_escapeAborts`; `test_validCaptureCallsCoordinator` | RESEARCH.md §Validation table SHELL-02 row (line 1425); §Question 8 rejection rules (lines 881-884) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift` | xctest-suite | `test_defaultHotkeyIsUnset` (SHELL-02 "ships unset") | RESEARCH.md §Validation table SHELL-02 row (line 1424) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift` | xctest-suite | `test_bannerEnqueuedOnDenial` with a mock `HIDAccessProbe`; `test_localMonitorOnlyFallback` | RESEARCH.md §Validation table SHELL-06 rows (lines 1432-1433) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift` | xctest-suite | `test_registerUnregisterIdempotent` (gated on isolated test user OR uses a `LaunchAtLogin` protocol + in-memory mock) | RESEARCH.md §Validation table SHELL-03 row (line 1427) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/WizardTCCStageTests.swift` | xctest-suite | `test_onlyInputMonitoringTriggers` — other TCC rows are explainer-only (D-08 / SEC-04) | RESEARCH.md §Validation table SEC-04 row (line 1450) | no-analog (greenfield) |
| `packages/Shell/Tests/ShellTests/JarvisEntitlementProbeTests.swift` | one-shot xctest (gated on `JARVIS_ENTITLEMENT_PROBE=1`) | `test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation` — instantiates `SpeechTranscriber(locale:preset:)` + `AssetInventory.status(forModules:)` on a stripped-entitlement Release archive; excluded from default test plan; own `EntitlementProbe` xcscheme | RESEARCH.md §Question 4 full excerpt (lines 552-592); Apple `AssetInventory` — https://developer.apple.com/documentation/speech/assetinventory; WWDC25 session 277 | no-analog (greenfield) |

### K. Build-time scripts

| File | Role | Data flow | Reference pattern | Match |
|------|------|-----------|-------------------|-------|
| `scripts/codesign.sh` | bash-script (Xcode Run Script phase — after Copy/Link, before Notarize) | walks `$BUILT_PRODUCTS_DIR/$WRAPPER_NAME/Contents/Helpers/**/*.app` deepest-first via `find -depth`; signs each helper with its per-helper `.entitlements`; signs main app last with `App/Jarvis.entitlements`; uses `$OTHER_CODE_SIGN_FLAGS=--options=runtime --timestamp`; **never `--deep`** | RESEARCH.md §Question 2 full shell excerpt (lines 255-294); Apple TN2206 deepest-first walk; rsms's macOS distribution gist — https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5 | no-analog (greenfield) |
| `scripts/verify-entitlements.sh` | bash-script (Xcode Run Script phase — after codesign.sh) | runs `codesign -d --entitlements -` on the main app; greps `MAIN_REQUIRED` (allow-jit, speech-recognition-assets, device.audio-input) — exits non-zero on missing; greps `MAIN_FORBIDDEN` (automation.apple-events, allow-unsigned-executable-memory) — exits non-zero if present; `plutil -extract NSSpeechRecognitionAssetsUsageDescription` on Info.plist; `plutil -replace JarvisEntitlementsVerified -bool YES` on success | RESEARCH.md §Question 2 full shell excerpt (lines 298-364); `codesign(1)` manual — https://keith.github.io/xcode-man-pages/codesign.1.html | no-analog (greenfield) |
| `scripts/verify-codesign-settings.sh` | bash-script (pbxproj linter) | greps `Jarvis.xcodeproj/project.pbxproj` for `CodeSignOnCopy = YES` near any `Contents/Helpers/` reference → fails build; greps for `--deep` flag anywhere → fails build | RESEARCH.md §Question 2 "Code Sign On Copy" lint (line 253); MCP-06 validation row (lines 1439-1440) | no-analog (greenfield) |
| `scripts/test-verify-entitlements.sh` | bash-script (fault-injection self-test) | invokes `verify-entitlements.sh` against `test-fixtures/broken-entitlements.plist` and asserts non-zero exit; runs in CI | RESEARCH.md §Wave 0 Gaps (line 1478); MCP-06 validation row (line 1438) | no-analog (greenfield) |
| `scripts/build-webview.sh` | bash-script (stub) | empty stub in P1; P3 fills in Vite build for R3F HUD bundle → `Jarvis.app/Contents/Resources/webview/` | RESEARCH.md §Summary bullet 15 (line 27); Vite build reference — https://vitejs.dev/guide/build.html | no-analog (greenfield) |
| `scripts/prime-tcc.sh` | bash-script (stub) | empty stub in P1; becomes meaningful in P6 (Mic) and P7 (Camera); P1 does NOT use this for Input Monitoring (that's a runtime `IOHIDRequestAccess` probe, not a script) | RESEARCH.md §Summary bullet 15 | no-analog (greenfield) |
| `test-fixtures/broken-entitlements.plist` | test-fixture | intentionally-malformed entitlements plist (missing `allow-jit` key); consumed by `scripts/test-verify-entitlements.sh` | RESEARCH.md §Wave 0 Gaps (line 1478) + §Validation table MCP-06 (line 1438) | no-analog (greenfield) |

---

## Shared Patterns

Cross-cutting patterns that apply across multiple new files. Each plan that touches a listed file should cite the shared pattern's reference source.

### S-1 — Swift 6 strict concurrency on every package (D-04)

**Applies to:** every `Package.swift` in `packages/` (Config, Keychain, Logging, Shell).
**Reference:** RESEARCH.md §D-04 (line 25) + Apple "Migrating to Swift 6" — https://www.swift.org/migration/documentation/migrationguide/

Pattern shape (cite verbatim in every SPM manifest):

```swift
// In Package.swift, on every target:
swiftSettings: [
    .swiftLanguageMode(.v6),
    // or .enableExperimentalFeature("StrictConcurrency") for sub-6 transitional
]
```

Any data-race error is a compile-time failure, not a warning.

### S-2 — `@MainActor` on every AppKit-touching service/controller

**Applies to:** `AppDelegate`, `MenuBarIconController`, `HUDBannerCoordinator`, `OnboardingWizardController`, `HotkeyBinder` (installation side), all SwiftUI `ObservableObject`s under `App/Wizard/`.
**Reference:** Apple `@MainActor` — https://developer.apple.com/documentation/swift/mainactor; RESEARCH.md §Architectural Responsibility Map (lines 118-128).

Rationale: AppKit APIs (`NSStatusItem`, `NSPanel`, `NSAlert`, `NSEvent`) are main-thread-only. `@MainActor` makes the main-thread contract load-bearing at the type level — matches D-04 strict concurrency posture.

### S-3 — `Sendable`-by-default for models and protocols

**Applies to:** every `struct` / `enum` / `protocol` in `packages/Config`, `packages/Keychain`, `packages/Logging` public surface.
**Reference:** RESEARCH.md §Question 1 (KeychainItem, KeychainError, KeychainStore all `Sendable`, lines 154-173); §Question 5 (LaunchSnapshot, PerTurnSnapshot `Sendable Codable Equatable`, lines 613-632).

Pattern shape:

```swift
public struct Foo: Sendable, Codable, Equatable { ... }
public enum FooError: Error, Sendable { ... }
public protocol FooService: Sendable { ... }
```

Actors are used only where shared-mutable-state is unavoidable (`ConfigStore`, `FileRotatingWriter` as `@unchecked Sendable` with a serial queue).

### S-4 — Redact-at-write discipline (single call site)

**Applies to:** `FileLogHandler.log` — the ONLY call site for `Redact.apply`. `OSLogHandler` does NOT call it (os.Logger handles `%{private}@` at system layer).
**Reference:** RESEARCH.md §Question 3 hook-placement note (line 493); OBS-06 / D-20 spec-minimum.

Discipline upstream of that call site: never pass a raw secret as `Logger.Message`. Always call `Redact.apply` on untrusted sources before logging if there's any chance of a key. The file-handler redact is defense-in-depth.

### S-5 — Keychain fetch-per-request, no caching

**Applies to:** any consumer of `KeychainStore` (P4 `AnthropicProvider`, wizard API-key validation).
**Reference:** RESEARCH.md §Question 1 fetch-per-request pattern (line 239).

`AnthropicProvider.stream()` calls `store.get(.anthropic)` on each turn, not at provider construction. Slight overhead; correct TCC posture (matches Touch ID on secure items).

### S-6 — Hard-block on safety failures, not silent fallback

**Applies to:** `AppDelegate` entitlement check (NSAlert → terminate); `ConfigLoader` malformed config (NSAlert → terminate); build-time `verify-entitlements.sh` grep failures.
**Reference:** RESEARCH.md §Pattern 1 (lines 1249-1294); §Anti-Patterns to Avoid line 1309 ("Fall back to defaults silently on malformed config — DON'T").

Counter-pattern to avoid: silent default fallback on `config.json` malformed → masks editing errors and can downgrade security keys (e.g. `ollama.base_url` silently reset to `127.0.0.1:11434`).

### S-7 — Reduce Motion / Reduce Transparency / Increase Contrast fallbacks

**Applies to:** `MenuBarIconController`, `JarvisHUDPanel`, `HUDBanner`, `BrandColors`, every SwiftUI view with a transition animation.
**References:**
- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — UI-SPEC Surface 3 Reduce Motion fallback (lines 400-404).
- `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` — UI-SPEC Surface 7 (line 590).
- `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` — UI-SPEC §Color (line 113).
- Observe via `NSWorkspace.shared.notificationCenter` for `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.

Every animation helper in `CAAnimationFactory` consults `shouldReduceMotion` and returns a fallback (static + tiny pulse dot pattern for idle-like states).

### S-8 — One-bootstrap discipline for global singletons

**Applies to:** `LoggingSystem.bootstrap(...)` — exactly one call site at `AppDelegate.applicationWillFinishLaunching`.
**Reference:** RESEARCH.md §Anti-Patterns to Avoid (line 1307) + §Question 3 `bootstrap()` doc-comment (lines 410-414).

Never call `LoggingSystem.bootstrap` from a package initializer, test `setUp`, or anywhere else. Tests that need a logger use `LoggingSystem.bootstrap { StreamLogHandler.standardOutput(label: $0) }` inside a test-package's test-only entrypoint, not the production one.

### S-9 — Dependency graph is acyclic: `Shell → Config → Keychain`, `Logging` is sink

**Applies to:** every `Package.swift` `dependencies:` array.
**Reference:** RESEARCH.md §"Why `packages/Keychain` as a separate package" (line 1185).

Graph:
```
Shell → Config → Keychain
Shell → Logging
Config → Logging (optional — Config uses Logger(label: "system") for file-watcher diagnostics)
```

Keychain has no SPM deps (only `Security.framework`). Logging has no SPM deps except `swift-log`. Config depends on Keychain + Logging. Shell depends on all three + system frameworks.

### S-10 — No Xcode workspace, no CocoaPods (D-05 / R1 H-B2)

**Applies to:** repo-root project layout; every plan that touches dependencies.
**Reference:** RESEARCH.md §D-05 (line 26); §Standard Stack "Deliberately NOT used in P1" (line 1095).

Only `.xcodeproj` at repo root. Local SPM packages referenced as local package refs from the pbxproj. No `.xcworkspace`. No `Podfile`. Hard rule — any plan that introduces either is a defect.

---

## No-Analog Summary

**Every file is no-analog (greenfield).** Rather than duplicate the "no-analog (greenfield)" row, this summary section calls out the three files the planner should treat as **highest-risk scaffolds** because they carry the most external-API subtlety with no local prior art to follow:

1. **`App/MenuBar/MenuBarIconController.swift`** — the `wantsLayer + template image + anchorPoint + CABasicAnimation` interaction is a known gotcha cluster. Cite RESEARCH.md §Question 7 (lines 751-869) verbatim; follow the "set `button.image` and animate `transform/opacity`, never `layer.contents`" rule.

2. **`packages/Shell/Tests/ShellTests/JarvisEntitlementProbeTests.swift`** — Apple's macOS 26 SpeechAnalyzer error shape is still in flux (two observed error codes: `SFSpeechErrorCode.assetUnavailable` vs `SFSpeechError Code=10 "unallocated locales"`). The test accepts both (RESEARCH.md §Question 4 lines 579-583). Must run on a stripped-entitlement Release archive, not Debug.

3. **`scripts/codesign.sh`** — `find -depth` deepest-first walk + per-helper `.entitlements` + never `--deep`. One wrong flag silently re-signs helpers with the parent identity and strips their per-helper entitlements (TN2206). Worth a close read of RESEARCH.md §Question 2 (lines 245-372) before writing.

---

## Metadata

**Analog search scope:** entire repository root — `.claude/`, `.planning/`, `CLAUDE.md`, `README.md`. No Swift / Xcode / SPM / scripts exist.
**Files scanned:** 0 source files (none exist).
**External references cited:** 51 rows, each citing either a RESEARCH.md excerpt (with line numbers), an Apple developer-documentation URL, or a well-known library source (KeychainAccess, swift-log, KeyboardShortcuts) as a pattern shape — not a dependency.
**Pattern extraction date:** 2026-04-22
**Consumer:** `gsd-planner` building plans for Phase 1 Foundations.
