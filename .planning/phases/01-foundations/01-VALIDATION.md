---
phase: 1
slug: foundations
status: populated
nyquist_compliant: true
wave_0_complete: planned
created: 2026-04-22
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
>
> **Authoritative source of truth for the per-requirement test map lives in `.planning/phases/01-foundations/01-RESEARCH.md` § Validation Architecture.** This file tracks execution status as tasks land; fill the table incrementally as plans are executed.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (default per D-03; per-package discretion) |
| **Config file** | Each package's `Package.swift` declares a `testTarget` — Wave 0 installs |
| **Quick run command** | `xcodebuild test -scheme <PackageName> -destination 'platform=macOS'` |
| **Full suite command** | `xcodebuild test -project Jarvis.xcodeproj -scheme JarvisTestsAll -destination 'platform=macOS'` |
| **Release-archive probes** | `xcodebuild archive -scheme Jarvis -configuration Release -archivePath build/Jarvis.xcarchive && scripts/verify-entitlements.sh build/Jarvis.xcarchive/Products/Applications/Jarvis.app` |
| **Estimated runtime** | ~10s per package; ~30s full P1 suite |

---

## Sampling Rate

- **After every task commit:** Run `xcodebuild test -scheme <affected package>` (< 10s per package)
- **After every plan wave:** Run `xcodebuild test -project Jarvis.xcodeproj -scheme JarvisTestsAll` (~30s)
- **Before `/gsd-verify-phase 1`:** Full suite green + scaffold-time probes (entitlement grep on Release archive + one-shot `JarvisEntitlementProbeTests` on stripped-entitlement archive) green
- **Max feedback latency:** 10 seconds (per-package) / 30 seconds (full suite)

---

## Per-Task Verification Map

*Populated incrementally by gsd-planner and gsd-executor. See RESEARCH.md § Validation Architecture for the complete REQ-ID → test map.*


---

## Wave 0 Requirements

Wave 0 test stubs + scripts (authoritative list in RESEARCH.md § Validation Architecture → Wave 0 Gaps):

- [ ] `packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/ConfigSplitTests.swift`
- [ ] `packages/Keychain/Tests/KeychainTests/KeychainTests.swift`
- [ ] `packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift`
- [ ] `packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift`
- [ ] `packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift` (bootstrap + multiplex)
- [ ] `App/Tests/AppTests/MenuBarIconControllerTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/WizardTCCStageTests.swift`
- [ ] `App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` (excluded from default plan; `EntitlementProbe` xcscheme)
- [ ] `scripts/codesign.sh`
- [ ] `scripts/verify-entitlements.sh`
- [ ] `scripts/verify-codesign-settings.sh`
- [ ] `scripts/test-verify-entitlements.sh` (self-test harness with broken-fixtures injection)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Icon animates state transitions without flicker | SHELL-01 | Visual quality judgment | Launch Release build; manually drive state changes via DevOverlay; inspect for dropped frames or template-render artifacts |
| WKWebView initializes without crash in Release | SHELL-04 | JIT crash fires only on cold Release launch on fresh Apple Silicon Mac | Archive Release; copy to a fresh Mac (or reset TCC); cold-launch; confirm no crash |
| SpeechAnalyzer entitlement is load-bearing | SHELL-05 / SEC-03 | Requires stripping entitlement from signed archive | Build Release archive; run `scripts/strip-entitlement-and-run.sh` on a copy; expect `assetUnavailable` or code-10 from probe |
| Developer portal App ID capability enabled | SEC-03 | Apple web UI — not automatable from code | Sign in to developer.apple.com → Certificates → Identifiers → `com.koftwentytwo.jarvis` → enable SpeechAnalyzer Asset Download capability; document in STATE.md |
| First-launch wizard surfaces correctly over fullscreen apps | Wizard UX | Space/fullscreen interaction — per Open Question #5 in RESEARCH.md | Launch Xcode in fullscreen; uninstall Jarvis + delete Application Support; launch Jarvis; confirm wizard appears |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01-T1 | 01-01-scaffold | 1 | SHELL-04, SEC-02 | T-01-02 | Hardened Runtime + allow-jit entitlement | scaffold-probe | `grep '<key>com.apple.security.cs.allow-jit</key>' App/Jarvis.entitlements` | App/Jarvis.entitlements | ⬜ pending |
| 01-01-T1 | 01-01-scaffold | 1 | SHELL-05, SEC-03 | T-01-03 | speech-recognition-assets entitlement + Info.plist key day one | scaffold-probe | `grep speech-recognition-assets App/Jarvis.entitlements && plutil -extract NSSpeechRecognitionAssetsUsageDescription raw App/Info.plist` | App/Jarvis.entitlements, App/Info.plist | ⬜ pending |
| 01-01-T1 | 01-01-scaffold | 1 | MCP-05 | T-01-06 | Contents/Helpers/ directory exists in built bundle | scaffold-probe | `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build && test -d build/Build/Products/Debug/Jarvis.app/Contents/Helpers` | build/Build/Products/Debug/Jarvis.app/Contents/Helpers | ⬜ pending |
| 01-01-T2 | 01-01-scaffold | 1 | SEC-02 | — | Swift 6 strict concurrency on every package | lint | `grep -c '.swiftLanguageMode(.v6)' packages/*/Package.swift` ≥ 2 per package | packages/Keychain/Package.swift, packages/Config/Package.swift, packages/Logging/Package.swift, packages/Shell/Package.swift | ⬜ pending |
| 01-01-T3 | 01-01-scaffold | 1 | SEC-03 | T-01-03 | Developer portal App ID capability enabled | manual (checkpoint:human-action) | user confirms via developer.apple.com UI | STATE.md scaffold row | ⬜ pending |
| 01-02-T1 | 01-02-keychain-config-logging | 2 | SEC-01 | T-02-01 | API key round-trips through Keychain via SystemKeychainStore at com.koftwentytwo.jarvis.anthropic | unit | `cd packages/Keychain && swift test` (test_setGetDeleteRoundTrip, test_anthropicConstantMatchesD10) | packages/Keychain/Tests/KeychainTests/KeychainTests.swift | ⬜ pending |
| 01-02-T2 | 01-02-keychain-config-logging | 2 | AGENT-05 | T-02-02 | ollama.base_url rejected at decode time if host not in {127.0.0.1, localhost, ::1} | unit | `cd packages/Config && swift test --filter LaunchSnapshotTests.test_ollamaBaseURLMustBeLocalhost` | packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift | ⬜ pending |
| 01-02-T2 | 01-02-keychain-config-logging | 2 | SEC-05 | T-02-03 | LaunchSnapshot vs PerTurnSnapshot split enforced via reflection | unit | `cd packages/Config && swift test --filter ConfigSplitTests.test_securityKeysInLaunchOnly` | packages/Config/Tests/ConfigTests/ConfigSplitTests.swift | ⬜ pending |
| 01-02-T2 | 01-02-keychain-config-logging | 2 | OBS-05 | — | FeatureFlags lives in PerTurnSnapshot only (not LaunchSnapshot) | unit | `cd packages/Config && swift test --filter LaunchSnapshotTests.test_featureFlagsNotInLaunchSnapshot` | packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift | ⬜ pending |
| 01-02-T2 | 01-02-keychain-config-logging | 2 | SEC-08 | T-02-04 | No AppleScript skip-allowlist / bypass / regex field exists in any schema | unit | `cd packages/Config && swift test --filter ConfigSplitTests.test_noSkipAllowlistKey` | packages/Config/Tests/ConfigTests/ConfigSplitTests.swift | ⬜ pending |
| 01-02-T2 | 01-02-keychain-config-logging | 2 | SEC-01 | T-02-01 | API key never appears in config.json encoding (defense-in-depth) | unit | `cd packages/Config && swift test --filter ApiKeyNotInConfigTests.test_apiKeyNotInConfigJSON` | packages/Config/Tests/ConfigTests/ApiKeyNotInConfigTests.swift | ⬜ pending |
| 01-02-T3 | 01-02-keychain-config-logging | 2 | OBS-06 | T-02-05 | Four channels (agent, tools, ui, system) multiplex to FileLogHandler + OSLogHandler | unit | `cd packages/Logging && swift test --filter LoggingTests.test_fourChannelsAreDefined` | packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift | ⬜ pending |
| 01-02-T3 | 01-02-keychain-config-logging | 2 | OBS-06 | T-02-05 | Redact masks 5 patterns exactly (sk-ant-, Authorization:Bearer, sk-, AKIA, ghp_) | unit | `cd packages/Logging && swift test --filter RedactTests` | packages/Logging/Tests/JarvisLoggingTests/RedactTests.swift | ⬜ pending |
| 01-02-T3 | 01-02-keychain-config-logging | 2 | OBS-06 | — | File log rotates daily, retains last 7 days | unit | `cd packages/Logging && swift test --filter FileLogHandlerTests` | packages/Logging/Tests/JarvisLoggingTests/FileLogHandlerTests.swift | ⬜ pending |
| 01-03-T1 | 01-03-app-shell-ui | 2 | SHELL-03 | — | HudState enum declares the five state cases (idle, listening, thinking, speaking, awaitingConfirmation) that downstream state-reflection surfaces (menu-bar icon, HUD panel, banner) bind against | scaffold-probe | `test -f App/Theme/HudState.swift && grep -c 'case idle\|case listening\|case thinking\|case speaking\|case awaitingConfirmation' App/Theme/HudState.swift \| grep -q '^5$'` | App/Theme/HudState.swift | ⬜ pending |
| 01-03-T2 | 01-03-app-shell-ui | 2 | SHELL-01 | — | Menu-bar NSStatusItem installed on launch with template PDF icon; state transitions update accessibility label | unit | `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/MenuBarIconControllerTests` | App/Tests/AppTests/MenuBarIconControllerTests.swift | ⬜ pending |
| 01-03-T3 | 01-03-app-shell-ui | 2 | SHELL-03, SHELL-04 | T-03-01, T-03-04 | Borderless transparent NSPanel with correct style flags; entitlement hard-block on missing JarvisEntitlementsVerified | unit | `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/JarvisHUDPanelTests -only-testing:JarvisAppTests/AppDelegateEntitlementTests` | App/Tests/AppTests/JarvisHUDPanelTests.swift, App/Tests/AppTests/AppDelegateEntitlementTests.swift | ⬜ pending |
| 01-04-T1 | 01-04-shell-wizard-wiring | 3 | SHELL-02 | — | Default hotkey ships unset; HotkeyBinder installs global+local monitor pair when granted, local-only when denied | unit | `cd packages/Shell && swift test --filter HotkeyBindingTests` | packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift | ⬜ pending |
| 01-04-T1 | 01-04-shell-wizard-wiring | 3 | SHELL-06 | T-04-03 | Input Monitoring denial → banner enqueued (not silent no-op) | unit | `cd packages/Shell && swift test --filter InputMonitoringDenialTests` | packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift | ⬜ pending |
| 01-04-T1 | 01-04-shell-wizard-wiring | 3 | SHELL-05 | — | LaunchAtLoginController wraps SMAppService.mainApp (no deprecated SMLoginItemSetEnabled) | unit | `cd packages/Shell && swift test --filter LaunchAtLoginTests` | packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift | ⬜ pending |
| 01-04-T2 | 01-04-shell-wizard-wiring | 3 | SHELL-02 | — | ShortcutRecorder rejects modifier-only / shift-only, aborts on Escape, captures valid combos | unit | `cd packages/Shell && swift test --filter ShortcutRecorderTests` | packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift | ⬜ pending |
| 01-04-T3 | 01-04-shell-wizard-wiring | 3 | SEC-04 | T-04-06 | Wizard stage 2 actively prompts Input Monitoring ONLY — Mic/Camera/Automation rows are explainer-only (D-08) | unit | `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/WizardTCCStageTests` | App/Tests/AppTests/WizardTCCStageTests.swift | ⬜ pending |
| 01-04-T3 | 01-04-shell-wizard-wiring | 3 | OBS-06 | T-04-07 | AppDelegate calls JarvisLogHandlerFactory.bootstrap exactly once (S-8 one-bootstrap discipline) | unit | `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/AppDelegateWiringTests/test_loggingBootstrapCalled` | App/Tests/AppTests/AppDelegateWiringTests.swift | ⬜ pending |
| 01-04-T3 | 01-04-shell-wizard-wiring | 3 | SEC-01 | T-04-02 | State dump does NOT include API key value; only boolean presence indicator | lint | grep 'apiKeyStored' App/AppDelegate.swift returns 1 match; raw API key is not fetched into a payload var | App/AppDelegate.swift | ⬜ pending |
| 01-05-T1 | 01-05-codesign-entitlement-probe | 4 | MCP-06 | T-05-01, T-05-02, T-05-03 | verify-entitlements.sh fails build on missing/forbidden entitlements (fault-injection) | scaffold-probe | `scripts/test-verify-entitlements.sh` returns PASS=3 FAIL=0 | scripts/test-verify-entitlements.sh | ⬜ pending |
| 01-05-T1 | 01-05-codesign-entitlement-probe | 4 | MCP-06 | T-05-04, T-05-05 | verify-codesign-settings.sh lints pbxproj for --deep and CodeSignOnCopy=YES | scaffold-probe | `SRCROOT=$(pwd) scripts/verify-codesign-settings.sh` exits 0 on clean pbxproj | scripts/verify-codesign-settings.sh | ⬜ pending |
| 01-05-T2 | 01-05-codesign-entitlement-probe | 4 | MCP-06, SEC-02, SEC-03 | T-05-01, T-05-02, T-05-06 | Build pipeline: pre-codesign writes JarvisEntitlementsVerified=YES BEFORE codesign; post-codesign is read-only | integration | `xcodebuild build -configuration Debug -derivedDataPath build` emits `✓ pre-codesign` + `✓ post-codesign` in log; `plutil -extract JarvisEntitlementsVerified raw build/Build/Products/Debug/Jarvis.app/Contents/Info.plist` returns true | Jarvis.xcodeproj/project.pbxproj (4 Run Script phases) | ⬜ pending |
| 01-05-T3 | 01-05-codesign-entitlement-probe | 4 | SEC-03 | T-05-02 | JarvisEntitlementProbeTests target compiles under EntitlementProbe scheme with JARVIS_ENTITLEMENT_PROBE build flag | scaffold-probe | `xcodebuild build -scheme EntitlementProbe -configuration Debug -derivedDataPath build` exits 0 | App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift | ⬜ pending |
| 01-05-T4 | 01-05-codesign-entitlement-probe | 4 | SEC-03 | T-05-02 | Stripped-entitlement Release archive probe confirms speech-recognition-assets is load-bearing (or refutes, recorded in STATE.md) | manual (checkpoint:human-verify) | `xcodebuild test -scheme EntitlementProbe -derivedDataPath build TEST_HOST=<stripped-archive>` against stripped archive | STATE.md scaffold-time verifications | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*
