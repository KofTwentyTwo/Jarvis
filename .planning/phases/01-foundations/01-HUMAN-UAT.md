---
status: partial
phase: 01-foundations
source: [01-VERIFICATION.md]
started: 2026-04-22T23:30:39Z
updated: 2026-04-22T23:30:39Z
---

## Current Test

[awaiting human testing — resume once Xcode 26 Testing.framework seal issue fixes and/or Apple exposes `com.apple.developer.speech-recognition-assets` in the Developer Portal capability picker]

## Tests

### 1. Stripped-archive SpeechAnalyzer probe (SC-2 / SEC-03)
expected: Release archive with `com.apple.developer.speech-recognition-assets` stripped and re-signed with Developer ID Application cert fires `SFSpeechErrorCode.assetUnavailable` (code 1) or macOS 26 "unallocated locales" (code 10) when `AssetInventory.status(forModules:)` is probed. Confirms entitlement is load-bearing.
blocked_by: "Xcode 26.4 / macOS 26.4 Testing.framework seal bug — missing `x86_64-apple-ios-macabi.swiftinterface` prevents JarvisEntitlementProbeTests from launching inside a Developer-ID-re-signed TEST_HOST. Unrelated to entitlement behavior."
infrastructure_verified:
  - scripts/codesign.sh (deepest-first Helpers + PlugIns walker)
  - scripts/verify-entitlements.sh (pre+post codesign modes, `--xml` flag)
  - scripts/verify-codesign-settings.sh (pbxproj linter)
  - scripts/test-verify-entitlements.sh (fault-injection self-test, PASS=3/3)
  - JarvisEntitlementProbeTests target + EntitlementProbe.xcscheme
  - Strip-and-resign manually executed 2026-04-22 — Developer ID Application chain confirmed
  - Release bundle codesign -d --entitlements - --xml returns speech-recognition-assets key
result: pending

### 2. Developer Portal capability enablement (Plan 01-01 Task 3 carry-over)
expected: `com.apple.developer.speech-recognition-assets` (SpeechAnalyzer Asset Download) capability enabled on App ID `com.koftwentytwo.jarvis` at developer.apple.com.
blocked_by: "Apple Developer Portal does not expose the capability in the picker yet (likely macOS 26 Tahoe–new entitlement lag). App ID com.koftwentytwo.jarvis registered 2026-04-22. Entitlement IS present in App/Jarvis.entitlements and every signed Release bundle — not a code defect; purely a portal UI availability issue."
infrastructure_verified:
  - App ID com.koftwentytwo.jarvis registered (2026-04-22)
  - App/Jarvis.entitlements declares the key
  - Every build's signed bundle carries the key (verify-entitlements.sh --post-codesign enforces)
result: pending

### 3. Fresh-Mac cold-launch sanity (SC-1)
expected: Release-signed archive cold-launches on a pristine Apple Silicon Mac; menu-bar icon appears; AppDelegate entitlement hard-block passes (`JarvisEntitlementsVerified=YES` baked in pre-codesign); summon hotkey opens HUD; wizard appears on first launch.
blocked_by: "Current dev host ≠ pristine Mac. No cold-launch has been performed on a fresh system (machine Keychain / TCC / LaunchServices state differs)."
mitigations:
  - verify-entitlements.sh pre/post run on every Debug build
  - JarvisEntitlementsVerified=true baked into built Debug bundle (plutil verified)
  - fault-injection self-test PASS=3/3
  - AppDelegate entitlement hard-block unit tested (AppDelegateEntitlementTests pass)
result: pending

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 2 (test 1 blocked on Xcode/macOS upstream bug; test 2 blocked on Apple Portal UI)

## Gaps

(none blocking Phase 2 start — all items are environmental/upstream, not Phase 1 code defects)
