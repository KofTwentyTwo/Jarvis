---
phase: 1
slug: foundations
status: draft
nyquist_compliant: false
wave_0_complete: false
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

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| _pending planner output_ | | | | | | | | | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Wave 0 test stubs + scripts (authoritative list in RESEARCH.md § Validation Architecture → Wave 0 Gaps):

- [ ] `packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/ConfigSplitTests.swift`
- [ ] `packages/Keychain/Tests/KeychainTests/KeychainTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/RedactTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/FileLogHandlerTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/LoggingTests.swift` (bootstrap + multiplex)
- [ ] `packages/Shell/Tests/ShellTests/MenuBarIconControllerTests.swift`
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
| Developer portal App ID capability enabled | SEC-03 | Apple web UI — not automatable from code | Sign in to developer.apple.com → Certificates → Identifiers → `com.kingsrook.jarvis` → enable SpeechAnalyzer Asset Download capability; document in STATE.md |
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
