---
phase: 01-foundations
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Jarvis.xcodeproj/project.pbxproj
  - App/Info.plist
  - App/Jarvis.entitlements
  - App/JarvisApp.swift
  - App/AppDelegate.swift
  - packages/Keychain/Package.swift
  - packages/Config/Package.swift
  - packages/Logging/Package.swift
  - packages/Shell/Package.swift
  - packages/Keychain/Sources/Keychain/Placeholder.swift
  - packages/Config/Sources/Config/Placeholder.swift
  - packages/Logging/Sources/Logging/Placeholder.swift
  - packages/Shell/Sources/Shell/Placeholder.swift
  - packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift
  - packages/Config/Tests/ConfigTests/PlaceholderTests.swift
  - packages/Logging/Tests/LoggingTests/PlaceholderTests.swift
  - packages/Shell/Tests/ShellTests/PlaceholderTests.swift
autonomous: false
requirements: [SHELL-04, SHELL-05, SEC-02, SEC-03, MCP-05]
user_setup:
  - service: apple-developer-portal
    why: "Enable com.apple.developer.speech-recognition-assets capability on App ID com.kingsrook.jarvis; Developer ID Application cert alone is insufficient"
    dashboard_config:
      - task: "Sign in to developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → com.kingsrook.jarvis → enable SpeechAnalyzer Asset Download capability"
        location: "developer.apple.com"
must_haves:
  truths:
    - "Jarvis.xcodeproj opens in Xcode 16 and compiles a Debug build successfully"
    - "Four SPM packages (Keychain, Config, Logging, Shell) exist under packages/ with Swift 6 strict concurrency opted in"
    - "App/Jarvis.entitlements carries allow-jit + speech-recognition-assets + device.audio-input; does NOT carry allow-unsigned-executable-memory or automation.apple-events"
    - "App/Info.plist carries LSUIElement=YES, NSSpeechRecognitionAssetsUsageDescription, NSMicrophoneUsageDescription, NSCameraUsageDescription, NSAppleEventsUsageDescription, JarvisEntitlementsVerified=NO (default)"
    - "Contents/Helpers/ directory exists in the built app bundle (via Copy Files build phase with empty source)"
  artifacts:
    - path: "Jarvis.xcodeproj/project.pbxproj"
      provides: "Xcode project with App target + 4 local SPM package refs, Hardened Runtime enabled, CODE_SIGN_STYLE=Manual"
      contains: "packages/Keychain"
    - path: "App/Jarvis.entitlements"
      provides: "Entitlements pair day one"
      contains: "com.apple.security.cs.allow-jit"
    - path: "App/Info.plist"
      provides: "LSUIElement + speech-recognition usage + entitlements-verified flag"
      contains: "LSUIElement"
    - path: "packages/Keychain/Package.swift"
      provides: "Keychain SPM manifest, Swift 6 strict"
      contains: ".swiftLanguageMode(.v6)"
    - path: "packages/Config/Package.swift"
      provides: "Config SPM manifest, depends on Keychain + Logging"
      contains: ".swiftLanguageMode(.v6)"
    - path: "packages/Logging/Package.swift"
      provides: "Logging SPM manifest, depends on apple/swift-log 1.5.3+"
      contains: "apple/swift-log"
    - path: "packages/Shell/Package.swift"
      provides: "Shell SPM manifest, depends on Config + Logging"
      contains: ".swiftLanguageMode(.v6)"
  key_links:
    - from: "Jarvis.xcodeproj/project.pbxproj"
      to: "packages/{Keychain,Config,Logging,Shell}"
      via: "local package refs"
      pattern: "packages/Keychain|packages/Config|packages/Logging|packages/Shell"
    - from: "App/Jarvis.entitlements"
      to: "codesign output"
      via: "CODE_SIGN_ENTITLEMENTS build setting"
      pattern: "CODE_SIGN_ENTITLEMENTS"
    - from: "App/Info.plist"
      to: "AppDelegate hard-block"
      via: "JarvisEntitlementsVerified key"
      pattern: "JarvisEntitlementsVerified"
---

<objective>
Scaffold the Jarvis.xcodeproj + four local SPM packages (Keychain, Config, Logging, Shell) with Swift 6 strict concurrency, day-one entitlements pair, Info.plist with `LSUIElement=YES` and all speech/mic/camera/AppleScript usage-description keys pre-set, and the `Contents/Helpers/` directory layout — even though no helper apps exist yet (P5 populates). After this plan, the project opens in Xcode 16 and compiles an empty Debug build; later plans fill in logic.

Purpose: Establish the static layout everything else attaches to. Getting entitlements + plist + SPM package layout right on day one is cheaper than retrofitting. D-01 forbids pre-creating `Bus`, `LLM`, `MCP`, `Voice`, `Memory` packages — only the four P1-scoped packages are created now.

Output: A compilable empty-shell Xcode project with package skeletons in place, ready for Plans 02/03 to fill in subsystems.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/01-foundations/01-CONTEXT.md
@.planning/phases/01-foundations/01-RESEARCH.md
@.planning/phases/01-foundations/01-PATTERNS.md
@.planning/research/RESEARCH-DELTAS.md

<interfaces>
<!-- Greenfield phase — no existing interfaces to consume. These are the contracts this plan ESTABLISHES for downstream plans. -->

SPM dependency graph (from PATTERNS §S-9, RESEARCH §Recommended Project Structure):
```
Shell → Config → Keychain
Shell → Logging
Config → Logging (optional — Config may use Logger for file-watcher diagnostics)
Keychain — no SPM deps (Security.framework only)
Logging — depends only on apple/swift-log 1.5.3+
```

Swift 6 strict concurrency pattern (PATTERNS §S-1, embedded verbatim in every Package.swift):
```swift
.target(
    name: "...",
    dependencies: [...],
    swiftSettings: [.swiftLanguageMode(.v6)]
)
```

Main app Jarvis.entitlements REQUIRED keys (RESEARCH §Entitlements lines 1097-1106):
- `com.apple.security.cs.allow-jit` = true (WKWebView JIT; SHELL-04/SEC-02)
- `com.apple.developer.speech-recognition-assets` = true (SpeechAnalyzer; SHELL-05/SEC-03)
- `com.apple.security.device.audio-input` = true (pre-pinned for P6 mic; does not prompt at P1)

Main app Jarvis.entitlements FORBIDDEN keys (RESEARCH §Entitlements lines 1109-1111):
- `com.apple.security.cs.allow-unsigned-executable-memory` — MLX does NOT need it (R2-S4)
- `com.apple.security.automation.apple-events` — moves to `mcp-applescript.entitlements` (P5)

Info.plist REQUIRED keys (RESEARCH §Info.plist lines 1114-1121):
- `LSUIElement` = YES (no Dock icon; SHELL-05)
- `NSSpeechRecognitionAssetsUsageDescription` = "Jarvis uses on-device speech recognition to listen to your voice commands. Audio never leaves your Mac."
- `NSMicrophoneUsageDescription` = pre-set for P6 (does NOT prompt in P1; OS only prompts on first use of AVAudioEngine mic)
- `NSCameraUsageDescription` = pre-set for P7
- `NSAppleEventsUsageDescription` = pre-set for P5 (mcp-applescript)
- `JarvisEntitlementsVerified` = NO (flipped at build time by verify-entitlements.sh — Plan 05)
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create Xcode project + Info.plist + Jarvis.entitlements + empty app target</name>
  <files>Jarvis.xcodeproj/project.pbxproj, App/Info.plist, App/Jarvis.entitlements, App/JarvisApp.swift, App/AppDelegate.swift, App/Assets.xcassets/AppIcon.appiconset/Contents.json, App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json, App/Assets.xcassets/Contents.json</files>
  <read_first>
    - CLAUDE.md (root — architecture lock + Hardened Runtime + allow-jit + SpeechAnalyzer entitlement rule)
    - .planning/phases/01-foundations/01-CONTEXT.md (D-01 through D-20 — especially D-05 "no workspace, no CocoaPods")
    - .planning/phases/01-foundations/01-RESEARCH.md §Standard Stack lines 1066-1142 (entitlements + Info.plist tables verbatim)
    - .planning/phases/01-foundations/01-PATTERNS.md §A lines 29-37 (Xcode project layout) and §B lines 39-44 (App target — lifecycle only per D-02)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Asset Inventory lines 624-634 (AppIcon placeholder + menu-bar template asset catalog paths)
  </read_first>
  <action>
    Create `Jarvis.xcodeproj` at repo root (NOT `.xcworkspace` — D-05 forbids workspace). Single App target named `Jarvis`, macOS platform, deployment target macOS 13.0, SDK macOS 26.

    **Xcode project build settings (all Configurations unless noted):**
    - `PRODUCT_BUNDLE_IDENTIFIER = com.kingsrook.jarvis`
    - `PRODUCT_NAME = Jarvis`
    - `MACOSX_DEPLOYMENT_TARGET = 13.0`
    - `SWIFT_VERSION = 6.0`
    - `SWIFT_STRICT_CONCURRENCY = complete`
    - `ENABLE_HARDENED_RUNTIME = YES` (SEC-02)
    - `CODE_SIGN_STYLE = Manual`
    - `CODE_SIGN_IDENTITY = -` (ad-hoc for Debug; Release uses `Developer ID Application` — planner leaves identity assignment to user keychain)
    - `CODE_SIGN_ENTITLEMENTS = App/Jarvis.entitlements`
    - `INFOPLIST_FILE = App/Info.plist`
    - `OTHER_CODE_SIGN_FLAGS = --options=runtime --timestamp` (per RESEARCH Q2 line 252)
    - `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`
    - `LSUIElement` is set in Info.plist (below), NOT as a build setting

    Add local SPM package references for all four packages (will be created empty in Task 3): `packages/Keychain`, `packages/Config`, `packages/Logging`, `packages/Shell`. Link all four package products to the `Jarvis` App target.

    Add a **Copy Files build phase** with destination **Wrapper** / subpath `Contents/Helpers` and **no files** — this materializes an empty `Contents/Helpers/` directory inside the built `.app` bundle (MCP-05). In Xcode: Build Phases → + → New Copy Files Phase → Destination: **Wrapper** (NOT Executables — Executables maps to `Contents/MacOS`, so subpath `Contents/Helpers` there would resolve to `Contents/MacOS/Contents/Helpers`, which is wrong). Wrapper maps to `$(WRAPPER_NAME)` (the `.app` bundle root); subpath `Contents/Helpers` then resolves to `Jarvis.app/Contents/Helpers` as required by MCP-05. The equivalent raw build-settings path, if editing pbxproj directly: set `dstSubfolderSpec = 1` (Xcode internal code for "Wrapper"; `6` is "Executables" and must NOT be used here).

**xcodebuild convention for Phase 1 (inherited by all P1 plans):** All `xcodebuild` invocations in Phase 1 use `-derivedDataPath build`. Acceptance criteria across Plans 01–05 reference `build/Build/Products/Debug/Jarvis.app` and `build/Build/Products/Release/Jarvis.app` on that basis. Concretely, the Debug build step for this task is:

```
xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build
```

After that completes, the built `.app` lives at `build/Build/Products/Debug/Jarvis.app`. Acceptance criteria referencing `build/Debug/Jarvis.app` below should be read against `build/Build/Products/Debug/Jarvis.app` — use whichever is the actual output path for your local xcodebuild version; the key constraint is that `-derivedDataPath build` is passed so the artifacts land under `build/` and not under `~/Library/Developer/Xcode/DerivedData/...`.

    **Create `App/Jarvis.entitlements`** (exact content, no deviations):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.cs.allow-jit</key>
        <true/>
        <key>com.apple.developer.speech-recognition-assets</key>
        <true/>
        <key>com.apple.security.device.audio-input</key>
        <true/>
    </dict>
    </plist>
    ```
    Do NOT add `com.apple.security.cs.allow-unsigned-executable-memory` (MLX doesn't need it per R2-S4) or `com.apple.security.automation.apple-events` (moves to mcp-applescript in P5).

    **Create `App/Info.plist`** with these keys verbatim:
    - `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)` (standard Xcode substitution)
    - `CFBundleName = $(PRODUCT_NAME)`
    - `CFBundleDisplayName = Jarvis`
    - `CFBundleExecutable = $(EXECUTABLE_NAME)`
    - `CFBundlePackageType = APPL`
    - `CFBundleShortVersionString = 0.1.0`
    - `CFBundleVersion = 1`
    - `LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET)`
    - `LSUIElement = YES` (boolean true — keeps app out of Dock per SHELL-05)
    - `NSHumanReadableCopyright = Copyright © 2026. Personal use.`
    - `NSSpeechRecognitionAssetsUsageDescription = Jarvis uses on-device speech recognition to listen to your voice commands. Audio never leaves your Mac.`
    - `NSMicrophoneUsageDescription = Jarvis listens for voice commands when the voice loop is active. Audio is processed on-device and never leaves your Mac.`
    - `NSCameraUsageDescription = Jarvis uses the camera only when vision features are active and only at your request.`
    - `NSAppleEventsUsageDescription = Jarvis uses AppleScript automation only after you approve each request in a confirmation dialog.`
    - `JarvisEntitlementsVerified = NO` (boolean false — Plan 05's verify-entitlements.sh flips to YES in a pre-codesign phase; AppDelegate reads this at launch and hard-blocks if still NO)
    - `NSHighResolutionCapable = YES`
    - `NSSupportsAutomaticGraphicsSwitching = YES`

    **Create `App/JarvisApp.swift`** (pure skeleton; wiring lands in Plan 03):
    ```swift
    import SwiftUI

    @main
    struct JarvisApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
        var body: some Scene {
            // Placeholder Settings scene so @main has a body; real windows land in Plan 03.
            Settings { EmptyView() }
        }
    }
    ```

    **Create `App/AppDelegate.swift`** (pure skeleton; entitlement hard-block lands in Plan 03):
    ```swift
    import AppKit

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationWillFinishLaunching(_ notification: Notification) {
            // Wiring lands in Plan 03 (logging bootstrap → entitlement check → config → keychain → menu bar → HUD panel → hotkey).
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // P1 scaffold. Empty.
        }
    }
    ```

    **Create asset catalog stubs:**
    - `App/Assets.xcassets/Contents.json` with standard `{"info": {"version": 1, "author": "xcode"}}` shell.
    - `App/Assets.xcassets/AppIcon.appiconset/Contents.json` — standard empty AppIcon set (placeholder; real art is post-P1 per UI-SPEC Open Items §2). Do NOT drop in any PNG files — leave slots empty. Xcode will emit warnings; accept them for P1.
    - `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` — carries `"template-rendering-intent": "template"` and `"preserves-vector-representation": true`; the actual `.pdf` file is deferred to Plan 03 where the menu-bar icon is wired (placeholder PDF acceptable per UI-SPEC Open Items §1).

    Per D-02, the App target is lifecycle + wiring only — these stub files satisfy that contract; no business logic ships in App/ files in this plan.
  </action>
  <verify>
    <automated>xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build 2>&amp;1 | tail -5</automated>
  </verify>
  <acceptance_criteria>
    - `Jarvis.xcodeproj/project.pbxproj` exists and contains the string `packages/Keychain`, `packages/Config`, `packages/Logging`, `packages/Shell` (all four local package refs registered)
    - `grep -c 'SWIFT_STRICT_CONCURRENCY = complete' Jarvis.xcodeproj/project.pbxproj` returns ≥ 2 (both Debug + Release configs)
    - `grep -c 'ENABLE_HARDENED_RUNTIME = YES' Jarvis.xcodeproj/project.pbxproj` returns ≥ 2
    - `grep -c 'CODE_SIGN_ENTITLEMENTS = App/Jarvis.entitlements' Jarvis.xcodeproj/project.pbxproj` returns ≥ 2
    - `grep -c 'OTHER_CODE_SIGN_FLAGS = "--options=runtime --timestamp"' Jarvis.xcodeproj/project.pbxproj` returns ≥ 2 (or matches without quotes depending on pbxproj emit style)
    - `grep -c 'Contents/Helpers' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1 (Copy Files phase subpath)
    - Copy Files phase Destination is **Wrapper**, NOT Executables: `grep -A3 'Contents/Helpers' Jarvis.xcodeproj/project.pbxproj | grep -q 'dstSubfolderSpec = 1;'` returns success (dstSubfolderSpec = 1 is Xcode's internal code for "Wrapper"; 6 = "Executables" which would be wrong). If the value is anything other than 1, the Copy Files destination is incorrect and MCP-05 fails.
    - `grep '<key>com.apple.security.cs.allow-jit</key>' App/Jarvis.entitlements` returns 1 match
    - `grep '<key>com.apple.developer.speech-recognition-assets</key>' App/Jarvis.entitlements` returns 1 match
    - `grep '<key>com.apple.security.device.audio-input</key>' App/Jarvis.entitlements` returns 1 match
    - `grep 'com.apple.security.cs.allow-unsigned-executable-memory' App/Jarvis.entitlements` returns NO matches (exit code 1)
    - `grep 'com.apple.security.automation.apple-events' App/Jarvis.entitlements` returns NO matches (exit code 1)
    - `plutil -extract LSUIElement raw App/Info.plist` prints `true` (or `1`)
    - `plutil -extract NSSpeechRecognitionAssetsUsageDescription raw App/Info.plist` prints the usage-description string (non-empty)
    - `plutil -extract NSMicrophoneUsageDescription raw App/Info.plist`, `NSCameraUsageDescription`, `NSAppleEventsUsageDescription` all non-empty
    - `plutil -extract JarvisEntitlementsVerified raw App/Info.plist` prints `false` (or `0`)
    - `.xcworkspace` does NOT exist anywhere under the repo (D-05): `find . -name '*.xcworkspace' -not -path './Jarvis.xcodeproj/*'` returns empty
    - `Podfile` does NOT exist at repo root: `test ! -f Podfile`
    - `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build` exits 0
    - Built `.app` bundle contains `Contents/Helpers/` directory: `test -d build/Build/Products/Debug/Jarvis.app/Contents/Helpers` (path follows `-derivedDataPath build` convention)
  </acceptance_criteria>
  <done>Xcode project opens in Xcode 16 without workspace; Debug build compiles to an empty app with `LSUIElement=YES`, Hardened Runtime, entitlements pair signed in, and `Contents/Helpers/` directory present in the built bundle.</done>
</task>

<task type="auto">
  <name>Task 2: Create four SPM package manifests with Swift 6 strict concurrency + placeholder sources/tests</name>
  <files>packages/Keychain/Package.swift, packages/Keychain/Sources/Keychain/Placeholder.swift, packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift, packages/Config/Package.swift, packages/Config/Sources/Config/Placeholder.swift, packages/Config/Tests/ConfigTests/PlaceholderTests.swift, packages/Logging/Package.swift, packages/Logging/Sources/Logging/Placeholder.swift, packages/Logging/Tests/LoggingTests/PlaceholderTests.swift, packages/Shell/Package.swift, packages/Shell/Sources/Shell/Placeholder.swift, packages/Shell/Tests/ShellTests/PlaceholderTests.swift</files>
  <read_first>
    - .planning/phases/01-foundations/01-CONTEXT.md (D-01 ONLY four packages; D-03 per-package testTarget; D-04 Swift 6 strict concurrency)
    - .planning/phases/01-foundations/01-RESEARCH.md §Standard Stack lines 1069-1086 (pinned libraries: apple/swift-log 1.5.3+)
    - .planning/phases/01-foundations/01-RESEARCH.md §Recommended Project Structure lines 1144-1185 (dep graph: Shell → Config → Keychain; Shell → Logging; Keychain no deps)
    - .planning/phases/01-foundations/01-PATTERNS.md §S-1 lines 172-187 (Swift 6 strict concurrency pattern) and §S-9 lines 250-263 (dep graph)
  </read_first>
  <action>
    Create all four SPM package manifests per D-01. Each package declares ONE library product, ONE test target, Swift 6 strict concurrency (`.swiftLanguageMode(.v6)` on every target per D-04).

    **`packages/Keychain/Package.swift`** (NO SPM deps — only Security.framework at link time, which is automatic on macOS):
    ```swift
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "Keychain",
        platforms: [.macOS(.v13)],
        products: [
            .library(name: "Keychain", targets: ["Keychain"]),
        ],
        dependencies: [],
        targets: [
            .target(
                name: "Keychain",
                dependencies: [],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
            .testTarget(
                name: "KeychainTests",
                dependencies: ["Keychain"],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
        ]
    )
    ```

    **`packages/Logging/Package.swift`** (apple/swift-log 1.5.3+ pinned per RESEARCH §Standard Stack line 1075):
    ```swift
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "Logging",
        platforms: [.macOS(.v13)],
        products: [
            .library(name: "JarvisLogging", targets: ["JarvisLogging"]),
        ],
        dependencies: [
            .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        ],
        targets: [
            .target(
                name: "JarvisLogging",
                dependencies: [
                    .product(name: "Logging", package: "swift-log"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
            .testTarget(
                name: "JarvisLoggingTests",
                dependencies: ["JarvisLogging"],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
        ]
    )
    ```
    Note: the library/target is named `JarvisLogging` (not `Logging`) to avoid a name collision with `swift-log`'s own `Logging` module — consumers `import JarvisLogging` to get the factory, `import Logging` to get swift-log's `Logger`.

    **`packages/Config/Package.swift`** (depends on Keychain + JarvisLogging):
    ```swift
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "Config",
        platforms: [.macOS(.v13)],
        products: [
            .library(name: "Config", targets: ["Config"]),
        ],
        dependencies: [
            .package(path: "../Keychain"),
            .package(path: "../Logging"),
        ],
        targets: [
            .target(
                name: "Config",
                dependencies: [
                    .product(name: "Keychain", package: "Keychain"),
                    .product(name: "JarvisLogging", package: "Logging"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
            .testTarget(
                name: "ConfigTests",
                dependencies: ["Config"],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
        ]
    )
    ```

    **`packages/Shell/Package.swift`** (depends on Config + JarvisLogging; links `ServiceManagement`, `IOKit`, `Carbon.HIToolbox` — linker flags are set per-target via `linkerSettings`):
    ```swift
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "Shell",
        platforms: [.macOS(.v13)],
        products: [
            .library(name: "Shell", targets: ["Shell"]),
        ],
        dependencies: [
            .package(path: "../Config"),
            .package(path: "../Logging"),
        ],
        targets: [
            .target(
                name: "Shell",
                dependencies: [
                    .product(name: "Config", package: "Config"),
                    .product(name: "JarvisLogging", package: "Logging"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)],
                linkerSettings: [
                    .linkedFramework("AppKit"),
                    .linkedFramework("ServiceManagement"),
                    .linkedFramework("IOKit"),
                    .linkedFramework("Carbon"),
                ]
            ),
            .testTarget(
                name: "ShellTests",
                dependencies: ["Shell"],
                swiftSettings: [.swiftLanguageMode(.v6)]
            ),
        ]
    )
    ```

    **Create placeholder sources** (one `Placeholder.swift` per package — tiny `public let _placeholder: String = "..."` constant so the target has at least one source file and the library builds). Real sources land in Plans 02 and 04.

    Example for `packages/Keychain/Sources/Keychain/Placeholder.swift`:
    ```swift
    // Placeholder. Real sources land in Plan 02.
    public enum KeychainPackagePlaceholder: Sendable {
        public static let marker: String = "keychain-scaffolded"
    }
    ```
    Repeat analogous for `Config` (`ConfigPackagePlaceholder`), `Logging` (`JarvisLoggingPackagePlaceholder`), `Shell` (`ShellPackagePlaceholder`).

    **Create placeholder tests** (one trivial XCTest per package per D-03 — per-package `testTarget` is mandatory):
    ```swift
    import XCTest
    @testable import Keychain

    final class PlaceholderTests: XCTestCase {
        func test_packageBuilds() {
            XCTAssertEqual(KeychainPackagePlaceholder.marker, "keychain-scaffolded")
        }
    }
    ```
    Repeat for `ConfigTests`, `JarvisLoggingTests`, `ShellTests` with their respective marker constants.

    **DO NOT create `packages/Bus/`, `packages/LLM/`, `packages/MCP/`, `packages/Voice/`, `packages/Memory/`** — D-01 explicitly forbids pre-creating later-phase packages.
  </action>
  <verify>
    <automated>cd packages/Keychain &amp;&amp; swift build 2>&amp;1 | tail -3 &amp;&amp; cd ../Logging &amp;&amp; swift build 2>&amp;1 | tail -3 &amp;&amp; cd ../Config &amp;&amp; swift build 2>&amp;1 | tail -3 &amp;&amp; cd ../Shell &amp;&amp; swift build 2>&amp;1 | tail -3</automated>
  </verify>
  <acceptance_criteria>
    - `test -f packages/Keychain/Package.swift && test -f packages/Config/Package.swift && test -f packages/Logging/Package.swift && test -f packages/Shell/Package.swift` all pass
    - `test ! -d packages/Bus && test ! -d packages/LLM && test ! -d packages/MCP && test ! -d packages/Voice && test ! -d packages/Memory` all pass (D-01 — no pre-creation)
    - Each `Package.swift` contains `.swiftLanguageMode(.v6)` at least twice (main target + testTarget): `grep -c '.swiftLanguageMode(.v6)' packages/Keychain/Package.swift` returns ≥ 2; same for Config, Logging, Shell
    - `grep -c 'swift-tools-version:6.0' packages/Keychain/Package.swift` returns 1; same for Config, Logging, Shell
    - `grep -c 'swift-log' packages/Logging/Package.swift` returns ≥ 1 AND version constraint is `from: "1.5.3"` — verify via `grep 'from: "1.5.3"' packages/Logging/Package.swift` returns ≥ 1
    - `grep '.package(path: "../Keychain")' packages/Config/Package.swift` returns 1 match
    - `grep '.package(path: "../Config")' packages/Shell/Package.swift` returns 1 match
    - `grep 'Keychain' packages/Shell/Package.swift` returns NO matches (Shell does NOT directly import Keychain — it goes through Config; per S-9)
    - Each package builds standalone: `cd packages/Keychain && swift build` exits 0; same for Config (after Keychain + Logging resolve), Logging (after swift-log resolve), Shell (after Config + Logging resolve)
    - Each package's tests run: `cd packages/Keychain && swift test` exits 0 with 1 passing test; same for Config, Logging, Shell
    - `grep -r 'linkedFramework("ServiceManagement")' packages/Shell/Package.swift` returns 1 match
  </acceptance_criteria>
  <done>All four packages compile standalone, pass their placeholder tests, and carry Swift 6 strict concurrency on every target. Bus/LLM/MCP/Voice/Memory are NOT pre-created.</done>
</task>

<task type="checkpoint:human-action" gate="blocking">
  <name>Task 3: Enable speech-recognition-assets capability on App ID (human-only step)</name>
  <what-built>
    Entitlements pair is present in `App/Jarvis.entitlements` (Task 1). The `com.apple.developer.speech-recognition-assets` entitlement is a managed capability — Apple validates it against the App ID registration in the Developer portal at runtime. Developer ID Application certificate alone is INSUFFICIENT; the capability must be explicitly enabled on the App ID `com.kingsrook.jarvis` in developer.apple.com, or the entitlement is silently dropped from the effective entitlements at launch on a fresh Mac (RESEARCH §Environment Availability line 1398; AUDIT-R2-S5).
  </what-built>
  <how-to-verify>
    User takes this manual action (no CLI; Apple's Developer portal has no API for capability toggles):

    1. Sign in to https://developer.apple.com/account/ with the Apple Developer account that owns the `Developer ID Application` certificate used to sign Jarvis Release builds.
    2. Navigate to **Certificates, Identifiers & Profiles** → **Identifiers**.
    3. Locate or create the App ID with Bundle ID `com.kingsrook.jarvis`. If it does not exist: click `+`, select "App IDs", then "App", fill Description "Jarvis", Bundle ID "com.kingsrook.jarvis" (Explicit).
    4. Under **Capabilities**, find and enable **SpeechAnalyzer Asset Download** (or the capability matching `com.apple.developer.speech-recognition-assets` — Apple may label it differently in the portal UI).
    5. Click **Save**. If a provisioning profile is auto-generated, regenerate it; if Manual code-signing is used (Task 1), the next build picks up the updated entitlement automatically.
    6. Record the action in `.planning/STATE.md` → Scaffold-Time Verifications → check off "App ID capability enabled".

    **Verification that the capability is actually active:** Ship one Release archive + run `scripts/verify-entitlements.sh` (Plan 05 will create this) on the signed bundle — `codesign -d --entitlements -` MUST show `<key>com.apple.developer.speech-recognition-assets</key><true/>` in the effective entitlements. Independently, Plan 05's `JarvisEntitlementProbeTests` (on an intentionally-stripped archive) confirms the entitlement is load-bearing at runtime.
  </how-to-verify>
  <resume-signal>Type "capability enabled" when done in the Developer portal, OR "defer" if enabling is blocked (phase completion gated on this; defer is acceptable for initial scaffold pass, but MUST be resolved before `/gsd-verify-phase 1` closes).</resume-signal>
  <files>.planning/STATE.md</files>
  <action>User-only: enable SpeechAnalyzer Asset Download capability on App ID `com.kingsrook.jarvis` via developer.apple.com. Detailed steps in `<how-to-verify>` above. When complete, update STATE.md scaffold-time verification row.</action>
  <verify>User confirms completion by updating STATE.md and typing resume signal.</verify>
  <done>STATE.md scaffold-time row "App ID capability enabled" checked OR explicitly marked deferred with reason.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Developer (human) → Xcode project | Developer writes entitlements/plist; build output goes into signed bundle that user's OS trusts |
| Apple Developer portal → App ID runtime validation | Apple validates `speech-recognition-assets` entitlement against App ID registration; missing capability = silent drop at runtime |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-01-01 | Tampering | Jarvis.entitlements | mitigate | Entitlement pair pinned day one; Plan 05 adds build-time grep (`verify-entitlements.sh`) that fails build if `allow-jit` or `speech-recognition-assets` missing. |
| T-01-02 | Denial of Service | Release archive launch | mitigate | Day-one `allow-jit` entitlement prevents WKWebView JIT mprotect kill on cold Release launch (Pitfall 1). Runtime `JarvisEntitlementsVerified` hard-block in AppDelegate (lands in Plan 03) aborts launch if build check failed. |
| T-01-03 | Denial of Service | SpeechAnalyzer on fresh machine | mitigate | `com.apple.developer.speech-recognition-assets` + `NSSpeechRecognitionAssetsUsageDescription` both day-one (Task 1); Task 3 (human step) enables capability on App ID in Developer portal; Plan 05 probe verifies load-bearing. |
| T-01-04 | Elevation of Privilege | Main app entitlements | mitigate | FORBIDDEN keys (`automation.apple-events`, `allow-unsigned-executable-memory`) explicitly excluded from `Jarvis.entitlements`; Plan 05 `verify-entitlements.sh` greps for their absence and fails build if present (MCP-05/MCP-06 cross-reference). |
| T-01-05 | Information Disclosure | Built app bundle | accept | No secrets in the build output at this stage; API key lives in user's Keychain only (SEC-01, Plan 02). Nothing to disclose from scaffolding. |
| T-01-06 | Tampering | Contents/Helpers/ directory | mitigate | Directory exists (empty) so P5 codesign-deepest-first walk has a predictable location; Plan 05 verifies the directory in the signed bundle and enforces `--deep` forbidden in build scripts. |

No `high`-severity residual risk. All day-one entitlement failure modes are covered by Plan 05's build-time grep gate. App ID capability is a documented human action (Task 3) that cannot be automated — disposition is "defer with planner-documented manual step".
</threat_model>

<verification>
**After Task 1:** `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build` exits 0; `.app` bundle exists; entitlements/plist keys all present.

**After Task 2:** `swift build` + `swift test` in each of `packages/Keychain`, `packages/Config`, `packages/Logging`, `packages/Shell` exits 0.

**After Task 3:** User confirms Developer portal capability enabled, or explicitly defers (logged in STATE.md).

**Phase-level:** Scaffolding is complete when all three tasks pass; Plans 02/03 depend on this plan's output.
</verification>

<success_criteria>
- `Jarvis.xcodeproj` builds Debug successfully with zero errors
- All four packages (Keychain, Config, Logging, Shell) resolve dependencies and build standalone
- Each package has a passing placeholder test
- `Jarvis.entitlements` carries `allow-jit`, `speech-recognition-assets`, `device.audio-input`; forbidden keys absent
- `Info.plist` carries `LSUIElement=YES`, all four usage-description keys, `JarvisEntitlementsVerified=NO`
- `Contents/Helpers/` directory exists in the built bundle
- Developer portal capability enabled (or explicitly deferred by user)
- No `.xcworkspace`, no `Podfile`, no `packages/Bus/LLM/MCP/Voice/Memory/` directories (D-01, D-05)
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundations/01-01-SUMMARY.md` documenting:
- Exact pbxproj build-settings applied (paste the key lines)
- Entitlements pair contents (paste plist)
- Info.plist keys (paste)
- Package layout + dep graph (ASCII)
- Whether Task 3 (App ID capability) completed or deferred — flag in STATE.md scaffold-time verifications
</output>
</content>
</invoke>