---
phase: 01-foundations
plan: 01
subsystem: infra
tags: [xcode, spm, swift6, entitlements, codesign, macos, hardened-runtime, speech-analyzer]

# Dependency graph
requires: []
provides:
  - "Jarvis.xcodeproj with App target, Hardened Runtime, Swift 6 strict concurrency, Manual codesign"
  - "App/Jarvis.entitlements pair pinned day one: allow-jit + speech-recognition-assets + device.audio-input"
  - "App/Info.plist with LSUIElement=YES, JarvisEntitlementsVerified=NO, four TCC usage-description keys"
  - "packages/Keychain, packages/Config, packages/Logging, packages/Shell — SPM skeletons with Swift 6 strict concurrency and placeholder tests"
  - "Contents/Helpers/ directory materialized in built bundle via PBXCopyFilesBuildPhase + post-build script"
  - ".gitignore covering Xcode/SPM build output"
affects:
  - "01-02-keychain-config-logging (fills Keychain/Config/Logging sources)"
  - "01-03-app-shell-ui (fills App/MenuBar, App/HUD, App/Wizard)"
  - "01-04-shell-wizard-wiring (fills packages/Shell)"
  - "01-05-codesign-entitlement-probe (adds scripts/codesign.sh + verify-entitlements.sh, wires proper signing)"

# Tech tracking
tech-stack:
  added:
    - "xcodegen 2.45.4 (project.yml → Jarvis.xcodeproj generator)"
    - "apple/swift-log 1.5.3+ (transitive via packages/Logging Package.swift)"
  patterns:
    - "S-1: Swift 6 strict concurrency via .swiftLanguageMode(.v6) on every target in every Package.swift"
    - "S-9: Acyclic dep graph — Shell → Config → Keychain; Shell/Config → Logging; Keychain has no SPM deps"
    - "S-10: .xcodeproj at repo root, no .xcworkspace, no CocoaPods (D-05 / R1 H-B2)"
    - "Entitlement pair pinned day one (allow-jit + speech-recognition-assets + device.audio-input); forbidden keys (allow-unsigned-executable-memory, automation.apple-events) explicitly excluded"

key-files:
  created:
    - "Jarvis.xcodeproj/project.pbxproj"
    - "project.yml"
    - "App/Info.plist"
    - "App/Jarvis.entitlements"
    - "App/JarvisApp.swift"
    - "App/AppDelegate.swift"
    - "App/Assets.xcassets/Contents.json"
    - "App/Assets.xcassets/AppIcon.appiconset/Contents.json"
    - "App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json"
    - "packages/Keychain/Package.swift"
    - "packages/Keychain/Sources/Keychain/Placeholder.swift"
    - "packages/Keychain/Tests/KeychainTests/PlaceholderTests.swift"
    - "packages/Config/Package.swift"
    - "packages/Config/Sources/Config/Placeholder.swift"
    - "packages/Config/Tests/ConfigTests/PlaceholderTests.swift"
    - "packages/Logging/Package.swift"
    - "packages/Logging/Sources/JarvisLogging/Placeholder.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/PlaceholderTests.swift"
    - "packages/Shell/Package.swift"
    - "packages/Shell/Sources/Shell/Placeholder.swift"
    - "packages/Shell/Tests/ShellTests/PlaceholderTests.swift"
    - ".gitignore"
    - ".planning/phases/01-foundations/deferred-items.md"
  modified: []

key-decisions:
  - "xcodegen over hand-rolled pbxproj — project.yml is committed alongside so regeneration is deterministic; avoids the class of Xcode-merge pain that a hand-rolled pbxproj invites"
  - "CODE_SIGNING_ALLOWED=NO for Debug only (Release unchanged) — the managed com.apple.developer.speech-recognition-assets entitlement requires a provisioning profile when signing; ad-hoc identity '-' alone is insufficient. Plan 05 wires proper signing and removes this Debug escape hatch."
  - "Logging library product named JarvisLogging (not Logging) to avoid a name collision with swift-log's own Logging module — consumers import JarvisLogging for the factory, import Logging for swift-log's Logger"
  - "Contents/Helpers/ materialized via BOTH a PBXCopyFilesBuildPhase (dstSubfolderSpec=1 for Wrapper, empty files list — satisfies MCP-05 acceptance-criteria grep and registers the codesign destination) AND a post-build shell script (mkdir -p — Xcode skips directory creation for an empty Copy Files phase, so the directory only materializes via the script)"
  - "No helper-app bundle in Contents/Helpers yet — deliberately empty in P1; P5 populates with mcp-applescript.app et al."

patterns-established:
  - "Package.swift shape: // swift-tools-version:6.0 header, .swiftLanguageMode(.v6) on every target, macOS 13 platform floor, explicit library product name, per-package testTarget (D-03)"
  - "App target is lifecycle + wiring only (D-02) — JarvisApp.swift hosts @main + NSApplicationDelegateAdaptor + Settings{EmptyView()} placeholder; AppDelegate.swift is empty stubs until Plan 03 wires the bootstrap chain"
  - "Info.plist carries JarvisEntitlementsVerified=NO at scaffold; Plan 05's verify-entitlements.sh --pre-codesign flips it to YES before codesign runs (order matters — flipping it post-codesign invalidates the signature)"
  - "project.yml + xcodegen regenerate the pbxproj deterministically; manual pbxproj edits (the PBXCopyFilesBuildPhase) are applied on top and will need to be re-applied if xcodegen is re-run — documented here so future contributors know"

requirements-completed: [SHELL-04, SHELL-05, SEC-02, SEC-03, MCP-05]

# Metrics
duration: 30min
completed: 2026-04-22
---

# Phase 1 Plan 01: Scaffold Summary

**Xcode project + four Swift-6-strict SPM packages + day-one entitlement pair + LSUIElement/speech-recognition-assets plist keys, with empty Contents/Helpers directory materialized in built bundle.**

## Performance

- **Duration:** ~30 min
- **Completed:** 2026-04-22
- **Tasks:** 2 of 3 complete (Task 3 deferred per plan's own `<resume-signal>` — see "User Setup Required" and "Issues Encountered")
- **Files created:** 24

## Accomplishments

- `Jarvis.xcodeproj` builds Debug successfully via plain `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build` — no overrides required.
- `App/Jarvis.entitlements` carries all three required keys (`com.apple.security.cs.allow-jit`, `com.apple.developer.speech-recognition-assets`, `com.apple.security.device.audio-input`) and excludes both forbidden keys (`com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.automation.apple-events`) per T-01-04 mitigation.
- `App/Info.plist` carries `LSUIElement=YES`, `JarvisEntitlementsVerified=NO`, and all four TCC usage-description strings (Speech/Mic/Camera/AppleEvents) — pre-pinned for P5/P6/P7 so the OS prompts at the right feature boundary, not at P1.
- Four SPM packages (`Keychain`, `Config`, `Logging`, `Shell`) build standalone with `swift build` and each passes one placeholder XCTest. Every target opts into `.swiftLanguageMode(.v6)` so data-race errors are compile-time failures from day one (D-04).
- `Contents/Helpers/` exists in the built bundle at `build/Build/Products/Debug/Jarvis.app/Contents/Helpers` — MCP-05 codesign infrastructure is in place before any P5 helper ships.
- Bus/LLM/MCP/Voice/Memory packages deliberately NOT pre-created per D-01.
- No `.xcworkspace` at repo root, no `Podfile` — D-05 / R1 H-B2 honored.

## Task Commits

Each task was committed atomically on the parallel-execution worktree branch:

1. **Task 1: Xcode project + App skeleton + entitlements/plist** — `98c58f0` (feat)
2. **Task 2: Four SPM package manifests with Swift 6 strict concurrency** — `d8617ff` (feat)
3. **Task 3: Enable speech-recognition-assets capability on App ID (developer.apple.com)** — **DEFERRED** (human-action checkpoint; plan's own `<resume-signal>` explicitly permits `"defer"` for initial scaffold pass; must resolve before `/gsd-verify-phase 1` closes)

## Files Created/Modified

### Xcode project
- `project.yml` — xcodegen source of truth; commit alongside pbxproj so regeneration is deterministic
- `Jarvis.xcodeproj/project.pbxproj` — App target, 4 local SPM package refs (`Keychain`, `Config`, `Logging` → product `JarvisLogging`, `Shell`), Hardened Runtime YES, Swift 6 strict concurrency complete, Manual codesign with `-` identity, `--options=runtime --timestamp` in OTHER_CODE_SIGN_FLAGS, `CODE_SIGNING_ALLOWED=NO` for Debug only, `PBXCopyFilesBuildPhase` with `dstPath="Contents/Helpers"` + `dstSubfolderSpec=1` (Wrapper), post-build `PBXShellScriptBuildPhase` that `mkdir -p`s the directory
- `Jarvis.xcodeproj/project.xcworkspace/contents.xcworkspacedata` — Xcode's intra-project workspace (does NOT count as a top-level `.xcworkspace`; still inside `Jarvis.xcodeproj/`)

### App target
- `App/JarvisApp.swift` — `@main struct JarvisApp: App` with `NSApplicationDelegateAdaptor` + placeholder `Settings{EmptyView()}` scene (real windows land in Plan 03)
- `App/AppDelegate.swift` — `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate` with empty `applicationWillFinishLaunching` / `applicationDidFinishLaunching` stubs; Plan 03 wires the bootstrap chain
- `App/Info.plist` — see "Entitlements & Info.plist" section below
- `App/Jarvis.entitlements` — see "Entitlements & Info.plist" section below
- `App/Assets.xcassets/Contents.json` — standard catalog metadata
- `App/Assets.xcassets/AppIcon.appiconset/Contents.json` — empty 16/32/128/256/512 @1x+@2x slots (placeholder per UI-SPEC Open Items §2; real art post-P1)
- `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` — `"template-rendering-intent": "template"` + `"preserves-vector-representation": true` (the actual PDF lands in Plan 03)

### SPM packages
- `packages/Keychain/Package.swift` + `Sources/Keychain/Placeholder.swift` + `Tests/KeychainTests/PlaceholderTests.swift`
- `packages/Config/Package.swift` + `Sources/Config/Placeholder.swift` + `Tests/ConfigTests/PlaceholderTests.swift`
- `packages/Logging/Package.swift` + `Sources/JarvisLogging/Placeholder.swift` + `Tests/JarvisLoggingTests/PlaceholderTests.swift`
- `packages/Shell/Package.swift` + `Sources/Shell/Placeholder.swift` + `Tests/ShellTests/PlaceholderTests.swift`

### Tooling
- `.gitignore` — `build/`, `.build/`, `.swiftpm/`, `*.xcuserstate`, `xcuserdata/`, `.DS_Store`, `.claude/worktrees/`
- `.planning/phases/01-foundations/deferred-items.md` — tracks the ATS public-key pinning semgrep finding as out-of-P1-scope

## Build Settings Applied (Jarvis target, Debug + Release except where noted)

```
PRODUCT_BUNDLE_IDENTIFIER = com.kingsrook.jarvis
PRODUCT_NAME              = Jarvis
MACOSX_DEPLOYMENT_TARGET  = 13.0
SWIFT_VERSION             = 6.0
SWIFT_STRICT_CONCURRENCY  = complete
ENABLE_HARDENED_RUNTIME   = YES
CODE_SIGN_STYLE           = Manual
CODE_SIGN_IDENTITY        = -
CODE_SIGN_ENTITLEMENTS    = App/Jarvis.entitlements
INFOPLIST_FILE            = App/Info.plist
GENERATE_INFOPLIST_FILE   = NO
OTHER_CODE_SIGN_FLAGS     = --options=runtime --timestamp
LD_RUNPATH_SEARCH_PATHS   = @executable_path/../Frameworks
CODE_SIGNING_ALLOWED      = NO   (Debug only — see Deviations § Rule 3 #2)
CODE_SIGNING_REQUIRED     = NO   (Debug only — see Deviations § Rule 3 #2)
```

## Entitlements & Info.plist (pasted verbatim)

### `App/Jarvis.entitlements`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.developer.speech-recognition-assets</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
```

FORBIDDEN keys explicitly absent: `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.automation.apple-events`.

### `App/Info.plist` (relevant keys)
```
LSUIElement                                    = true
JarvisEntitlementsVerified                     = false   (Plan 05 flips to true pre-codesign)
NSSpeechRecognitionAssetsUsageDescription      = "Jarvis uses on-device speech recognition …"
NSMicrophoneUsageDescription                   = "Jarvis listens for voice commands when …"
NSCameraUsageDescription                       = "Jarvis uses the camera only when vision features are active …"
NSAppleEventsUsageDescription                  = "Jarvis uses AppleScript automation only after you approve …"
CFBundleIdentifier                             = $(PRODUCT_BUNDLE_IDENTIFIER)
CFBundleShortVersionString                     = 0.1.0
CFBundleVersion                                = 1
LSMinimumSystemVersion                         = $(MACOSX_DEPLOYMENT_TARGET)
NSHighResolutionCapable                        = true
NSSupportsAutomaticGraphicsSwitching           = true
```

## Package Dependency Graph

```
Shell ──→ Config ──→ Keychain        (Keychain has no SPM deps; Security.framework at link)
  │         │
  └──┬──────┘
     ↓
  JarvisLogging ──→ apple/swift-log 1.5.3+

Shell also links at the system-framework level: AppKit, ServiceManagement, IOKit, Carbon
```

## Decisions Made

- **xcodegen over hand-rolled pbxproj.** Project.yml committed alongside the generated pbxproj so regeneration is deterministic; we avoid the class of Xcode-merge pain that a hand-rolled pbxproj invites. Manual post-xcodegen patches (the `PBXCopyFilesBuildPhase` — xcodegen drops empty copy-files phases entirely) are documented in this SUMMARY so future contributors know to re-apply them if `xcodegen generate` is re-run. If that maintenance becomes painful, the alternative is to delete project.yml and own the pbxproj by hand.
- **`Logging` library product renamed `JarvisLogging`.** Declaring `.library(name: "Logging", ...)` collides with swift-log's own `Logging` module at consumer import time (e.g. `packages/Config/Sources/Config/SomeFile.swift` would see an ambiguous `Logging` name). Product name is `JarvisLogging`; the SPM package directory stays `packages/Logging/` to match PATTERNS.md row I. Consumers `import JarvisLogging` for the factory and `import Logging` for swift-log's own `Logger`.
- **`CODE_SIGNING_ALLOWED=NO` for Debug only.** Release signing is wired properly in Plan 05 and unchanged here; Debug disables the signing step entirely so the managed `com.apple.developer.speech-recognition-assets` entitlement doesn't trigger Xcode's provisioning-profile requirement. Rationale detailed in Deviations § Rule 3 #2.
- **`Contents/Helpers/` materialized via BOTH a Copy Files phase AND a post-build script.** The Copy Files phase (dstSubfolderSpec=1, empty files list) satisfies MCP-05 acceptance criteria and registers the codesign destination for Plan 05's deepest-first walk. The post-build `mkdir -p` script is necessary because Xcode skips directory creation for an empty Copy Files phase; without the script the directory never appears in the built bundle.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added `.gitignore` covering Xcode/SPM build output**
- **Found during:** Pre-Task-1-commit `git status` pass
- **Issue:** No `.gitignore` existed at repo root; `git status` would track `build/`, `.build/`, `.swiftpm/`, `*.xcuserstate`, `.claude/worktrees/` once those were generated, polluting commits
- **Fix:** Wrote `.gitignore` at repo root covering Xcode (`build/`, `DerivedData/`, `*.xcuserstate`, `xcuserdata/`), SPM (`.build/`, `.swiftpm/`, `Package.resolved`), macOS (`.DS_Store`), and GSD worktrees (`.claude/worktrees/`)
- **Files modified:** `.gitignore` (created)
- **Verification:** `git status --short` after write shows no `build/` / `.claude/worktrees/` entries (they're ignored); `.gitignore` itself is the only newly-tracked file from this change
- **Committed in:** `98c58f0` (Task 1 commit)

**2. [Rule 3 - Blocking] Disabled codesigning for Debug (`CODE_SIGNING_ALLOWED=NO` + `CODE_SIGNING_REQUIRED=NO`)**
- **Found during:** Task 1 verification (`xcodebuild … Debug build` exited non-zero)
- **Issue:** With `CODE_SIGN_IDENTITY="-"` (ad-hoc) and the managed `com.apple.developer.speech-recognition-assets` entitlement present, Xcode 26 refuses to sign: "Jarvis requires a provisioning profile. Enable development signing and select a provisioning profile in the Signing & Capabilities editor." Managed `com.apple.developer.*` entitlements require a profile to validate against the App ID's Developer-portal capability registration; ad-hoc alone is insufficient.
- **Options considered:**
  - (a) Strip `speech-recognition-assets` from Debug entitlements → violates Task 1's "entitlements pair day one" mandate and Task 1's explicit acceptance criterion (`grep '<key>com.apple.developer.speech-recognition-assets</key>' App/Jarvis.entitlements` must return 1)
  - (b) Use separate Debug/Release entitlements files → adds complexity not specified by the plan
  - (c) Set `CODE_SIGNING_ALLOWED=NO` on Debug only → standard CI/scaffold escape hatch; keeps Release build config untouched; Plan 05 will wire proper signing
- **Fix:** Option (c). Added `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO` to the Jarvis Debug build config in `Jarvis.xcodeproj/project.pbxproj` (lines ~213). `project.yml` updated with a `configs: Debug:` override block so regeneration is idempotent. Release build config is unchanged.
- **Files modified:** `Jarvis.xcodeproj/project.pbxproj`, `project.yml`
- **Verification:** `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build` (no overrides) exits 0; `build/Build/Products/Debug/Jarvis.app/Contents/Helpers/` exists; `plutil -extract LSUIElement raw Contents/Info.plist` returns `true`; `plutil -extract JarvisEntitlementsVerified raw Contents/Info.plist` returns `false`
- **Committed in:** `98c58f0` (Task 1 commit)
- **Cleanup owed to Plan 05:** Plan 05 wires `scripts/codesign.sh` and proper signing flow. When Plan 05 lands, remove `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO` from the Debug config (both in `project.pbxproj` and `project.yml`) so Debug builds produce signed-with-ad-hoc-identity output matching the codesign walk. Documented here so the Plan 05 executor finds this breadcrumb.

**3. [Rule 3 - Blocking] Added post-build `mkdir -p` script for `Contents/Helpers/`**
- **Found during:** Task 1 verification (built bundle lacked `Contents/Helpers/` directory)
- **Issue:** The `PBXCopyFilesBuildPhase` with `dstSubfolderSpec=1` (Wrapper) + `dstPath="Contents/Helpers"` + an empty `files` list does NOT materialize the directory in the built bundle. Xcode skips directory creation when there are no files to copy.
- **Fix:** Added a `PBXShellScriptBuildPhase` after the Copy Files phase with `shellScript = "mkdir -p \"${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Helpers\"\n"` and `alwaysOutOfDate=1`. Registered in `project.yml` as a `postBuildScripts:` entry so regeneration is idempotent.
- **Files modified:** `Jarvis.xcodeproj/project.pbxproj`, `project.yml`
- **Verification:** `test -d build/Build/Products/Debug/Jarvis.app/Contents/Helpers` returns 0 after `xcodebuild Debug build`
- **Committed in:** `98c58f0` (Task 1 commit)

**4. [Rule 3 - Blocking] Tracked ATS public-key pinning semgrep finding as deferred**
- **Found during:** Task 1 (Info.plist creation) — semgrep mcp post-tool-cli-scan flagged CWE-296 (the Info.plist lacks `NSAppTransportSecurity` pinning)
- **Issue:** Out of P1 scope. P1 creates zero networking code; `AnthropicProvider` (the only TLS egress in v1) lands in P4; `OllamaProvider` binds to `127.0.0.1` only (validated by `OllamaConfig` decoder per AGENT-05). Phase 1 threat register (T-01-01 … T-01-06) does not include TLS trust-chain attacks.
- **Fix:** Logged to `.planning/phases/01-foundations/deferred-items.md` with disposition + rationale. Not a P1 fix; if pinning is pursued later, it's a Rule-4 architectural decision for P4 or P8.
- **Files modified:** `.planning/phases/01-foundations/deferred-items.md` (created)
- **Verification:** File exists, documents the finding with scope analysis
- **Committed in:** `98c58f0` (Task 1 commit)

---

**Total deviations:** 4 auto-fixed (all Rule 3 - Blocking)
**Impact on plan:** All four are mechanical blockers that the plan didn't predict — none changed plan scope or security posture. Deviations 1, 3, 4 are one-shot plumbing; Deviation 2 (Debug codesigning escape hatch) is an explicit breadcrumb for Plan 05 to clean up.

## Issues Encountered

- **Task 3 (App ID capability on developer.apple.com) deferred per plan's own `<resume-signal>`.** This is a `checkpoint:human-action` that the plan explicitly permits deferring on initial scaffold pass ("defer is acceptable for initial scaffold pass, but MUST be resolved before `/gsd-verify-phase 1` closes"). No CLI API exists for Apple Developer portal capability toggles. Parallel worktree executors cannot drive interactive human steps, so Task 3 remains pending for the orchestrator + user to resolve before `/gsd-verify-phase 1`. See "User Setup Required" below for the exact steps.
- **xcodegen overwrote Info.plist on first `generate` run** — fixed by removing the `info:` stanza from `project.yml` and adding `excludes: ["Info.plist", "Jarvis.entitlements"]` to the `sources:` entry so xcodegen leaves both files alone. Info.plist was restored to the Task-1 spec content before the first commit; the overwritten intermediate was not committed.

## User Setup Required

**Task 3 — Enable SpeechAnalyzer Asset Download capability on App ID `com.kingsrook.jarvis` (human-only; cannot be automated).**

Steps (no CLI available for Apple's Developer portal capability UI):

1. Sign in to https://developer.apple.com/account/ with the Apple Developer account that owns the Developer ID Application certificate used to sign Jarvis Release builds.
2. Navigate to **Certificates, Identifiers & Profiles** → **Identifiers**.
3. Locate or create the App ID with Bundle ID `com.kingsrook.jarvis`. If it does not exist: `+` → **App IDs** → **App**; Description `Jarvis`, Bundle ID `com.kingsrook.jarvis` (Explicit).
4. Under **Capabilities**, enable **SpeechAnalyzer Asset Download** (Apple may label it differently; the underlying entitlement key is `com.apple.developer.speech-recognition-assets`).
5. Click **Save**. If a provisioning profile is auto-generated, regenerate it; with Manual code-signing (Task 1), the next Release build picks up the updated entitlement automatically.
6. Update `.planning/STATE.md` → Scaffold-Time Verifications row: check off "App ID capability enabled" (or mark "deferred until Plan 05 probe" if preferred).

**Verification that the capability is actually active** (Plan 05 owns this probe mechanically):
- `scripts/verify-entitlements.sh` on a Release archive — `codesign -d --entitlements -` must show `<key>com.apple.developer.speech-recognition-assets</key><true/>` in the EFFECTIVE (signed) entitlements, not just the source plist.
- `JarvisEntitlementProbeTests` on an intentionally-stripped archive — confirms the entitlement is load-bearing at runtime (RESEARCH-DELTAS.md entry: "KEEP R2-S5 as a load-bearing but unverified claim" until probe confirms).

**Status recorded here:** Task 3 DEFERRED on initial scaffold pass per plan's `<resume-signal>`. Phase 1 verify gate (`/gsd-verify-phase 1`) MUST resolve this before Phase 1 is declared complete.

## Known Stubs

Stubs intentionally present at end of this plan (wire-up lands in later plans in the same phase — all documented in the plan's own `<action>` blocks):

- `App/JarvisApp.swift` — `Settings { EmptyView() }` placeholder scene; real HUD window + wizard windows land in Plan 03
- `App/AppDelegate.swift` — empty `applicationWillFinishLaunching` / `applicationDidFinishLaunching`; Plan 03 wires logging bootstrap → entitlement hard-block → config → keychain → menu bar → HUD panel → hotkey
- `packages/Keychain/Sources/Keychain/Placeholder.swift` — `KeychainPackagePlaceholder.marker`; real `KeychainItem`, `KeychainStore`, `SystemKeychainStore` land in Plan 02
- `packages/Config/Sources/Config/Placeholder.swift` — `ConfigPackagePlaceholder.marker`; real `LaunchSnapshot`, `PerTurnSnapshot`, `ConfigLoader`, etc. land in Plan 02
- `packages/Logging/Sources/JarvisLogging/Placeholder.swift` — `JarvisLoggingPackagePlaceholder.marker`; real `FileLogHandler`, `OSLogHandler`, `Redact`, `LoggingBootstrap` land in Plan 02
- `packages/Shell/Sources/Shell/Placeholder.swift` — `ShellPackagePlaceholder.marker`; real `HotkeyBinder`, `ShortcutRecorderView`, `LaunchAtLoginController`, etc. land in Plan 04
- `App/Assets.xcassets/AppIcon.appiconset/` — empty slots (placeholder per UI-SPEC Open Items §2; real art post-P1; Xcode emits warnings at build, accepted for P1)
- `App/Assets.xcassets/Icon-MenuBar-Template.imageset/` — metadata only; actual PDF lands in Plan 03 when the menu-bar icon is wired

None of these stubs prevent Plan 01-01's goal (compilable empty shell) — they ARE the goal per the plan's `<objective>`.

## Next Phase Readiness

- `Jarvis.xcodeproj` opens in Xcode 26.4.1, compiles Debug cleanly, produces a `.app` bundle with `Contents/Helpers/` in place. Plans 02 (`keychain-config-logging`) and 03 (`app-shell-ui`) are unblocked — they can fill in package sources and App/ wiring on top of this scaffold.
- Task 3 (Developer portal capability) remains pending for user; does not block Plans 02/03 (both are non-networking, non-codesign-dependent). It MUST be resolved before `/gsd-verify-phase 1` closes; the Plan 05 stripped-archive probe depends on the capability being enabled (or on the probe being intentionally run against a stripped build to confirm load-bearing — see RESEARCH-DELTAS).
- Plan 05 cleanup breadcrumb: remove `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO` Debug overrides once `scripts/codesign.sh` + `scripts/verify-entitlements.sh` wire proper signing.

## Self-Check: PASSED

Verified:
- `Jarvis.xcodeproj/project.pbxproj` — FOUND
- `App/Info.plist` — FOUND (contains `LSUIElement=true`, `JarvisEntitlementsVerified=false`, all four usage-description keys)
- `App/Jarvis.entitlements` — FOUND (all three required keys present, both forbidden keys absent)
- `App/JarvisApp.swift` — FOUND
- `App/AppDelegate.swift` — FOUND
- `packages/{Keychain,Config,Logging,Shell}/Package.swift` — all four FOUND
- `packages/{Keychain,Config,Logging,Shell}/Sources/.../Placeholder.swift` — all four FOUND (note Logging's source dir is `Sources/JarvisLogging/`)
- `packages/{Keychain,Config,Logging,Shell}/Tests/.../PlaceholderTests.swift` — all four FOUND
- `.gitignore` — FOUND
- `.planning/phases/01-foundations/deferred-items.md` — FOUND
- Commit `98c58f0` (Task 1) — FOUND in `git log`
- Commit `d8617ff` (Task 2) — FOUND in `git log`
- Built bundle `build/Build/Products/Debug/Jarvis.app/Contents/Helpers/` — FOUND (post clean rebuild)
- `swift test` passes in all four packages (1 placeholder test each)
- `xcodebuild Debug build` succeeds with no overrides
- No `.xcworkspace` outside `Jarvis.xcodeproj/`; no `Podfile` at repo root
- `packages/{Bus,LLM,MCP,Voice,Memory}/` — all ABSENT

---
*Phase: 01-foundations*
*Plan: 01 (scaffold)*
*Completed: 2026-04-22 (Task 3 deferred per plan's resume-signal)*
