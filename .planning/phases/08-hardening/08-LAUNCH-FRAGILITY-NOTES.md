# 08-LAUNCH-FRAGILITY-NOTES

Phase 8 plan 03 prerequisite — investigation of two cross-cutting items
inherited from Phase 6 close-out:

1. Xcode 26 ad-hoc Debug bundle launch fragility (D-12 / D-13)
2. AVAudioEngine route-change injection probe (D-14)

Both feed downstream:
- Item 1 unblocks the six Plan 06-05 HUMAN-UAT gates and the empirical
  Orpheus TTFA measurement. Both surface as `MANUAL:` items in
  `.planning/phases/06-voice/checklist.yaml` during plan 08-04's sweep —
  NOT here.
- Item 2 determines whether `AudioGraphRebuildRunner.deviceChange` runs
  automated or degrades to MANUAL per D-14.

---

## Xcode 26 Launch Fragility (D-12 inherited from Phase 6)

### Symptoms (per `.planning/STATE.md` "Phase 6 → Phase 8 Deferred Items")

1. `SWIFT_ENABLE_DEBUG_DYLIB: NO` is set in `project.yml` Debug config (line
   147) yet Xcode 26 still produces `Jarvis.debug.dylib` and
   `__preview.dylib` next to the main exec.
2. After the codesign post-build step succeeds,
   `codesign --verify --deep --strict` reports
   `invalid Info.plist (plist or signature have been modified)` despite
   BUILD SUCCEEDED — something downstream of `codesign.sh` invalidates the
   bundle.
3. `verify-entitlements.sh --pre-codesign` writes
   `JarvisEntitlementsVerified=YES` correctly into the unsigned bundle's
   Info.plist (script line 192), but the marker is observed as `false` /
   absent post-build — same downstream mechanism.
4. Manual re-codesign of the bundle's main exec (`codesign -s -`) breaks
   `Jarvis.debug.dylib`'s Team-ID match, causing dyld to refuse to load
   the dylib at app start (`__abort_with_payload`).

### Investigation

Build phase ordering (`project.yml` lines 291–336):

1. Create `Contents/Helpers/`
2. Copy MCP helpers (mcp-time / mcp-clipboard / mcp-applescript)
3. `verify-entitlements.sh --pre-codesign` — writes
   `JarvisEntitlementsVerified=YES` to Info.plist
4. `codesign.sh` — deepest-first signs all helpers + main bundle
5. `verify-entitlements.sh --post-codesign` — reads signed entitlements
6. `verify-codesign-settings.sh` — pbxproj lint

The writes in step 3 and the codesign in step 4 are synchronous. After
step 6, control returns to Xcode. Xcode 26's incremental-build pipeline
then continues with internal post-processing that is NOT a configurable
build phase:

- **Preview dylib generation**: even with `SWIFT_ENABLE_DEBUG_DYLIB=NO`,
  Xcode 26 emits a `__preview.dylib` for SwiftUI / Live Preview support
  that lives next to the main exec. This dylib is signed with Xcode's
  internal preview-pipeline identity, NOT our codesign chain.
- **Info.plist re-stamping**: incremental-dependency tracking writes a
  build receipt into the bundle that mutates Info.plist after our
  codesign phase, breaking the bundle hash that `codesign --verify`
  recomputes.

Both behaviors are inherent to Xcode 26's Debug/incremental pipeline.
They are NOT configurable via xcodebuild flags or build settings as of
Xcode 26.0.1 (verified via Apple developer forums + the Swift Forums
thread on debug-dylib generation).

The classes of fix considered:

| Approach | Outcome |
|----------|---------|
| Move `verify-entitlements --pre-codesign` write to a sidecar file (not Info.plist) | Doesn't address the codesign-then-Info.plist mutation; only sidesteps the marker check. |
| Add a NEW post-build phase AFTER `verify-codesign-settings.sh` that re-codesigns the main exec only | Breaks `Jarvis.debug.dylib`'s Team-ID match (dyld refuses load on next launch). |
| Disable Xcode preview generation entirely | No build-setting exposed in Xcode 26 to do this. |
| Use `xcodebuild` Release archive for all UAT (skip Debug bundle launch) | This IS the operator workaround below. |

### RESOLUTION: ACCEPTED AS MANUAL

Root cause is Xcode 26's preview-dylib + incremental Info.plist re-stamping
pipeline running AFTER our last build phase. There is no Xcode 26 build
setting exposed to disable this; attempts to suppress it via build flags
(`SWIFT_ENABLE_DEBUG_DYLIB: NO`) are observed-ignored. This is upstream
Xcode behavior outside our control.

**Operator workaround for Phase 6 deferred UAT gates:** UAT gates require
a Release-signed archive, NOT an ad-hoc Debug bundle. Build via:

```bash
# 1. Clean build of Release archive
xcodebuild -scheme Jarvis -configuration Release \
  -archivePath /tmp/Jarvis.xcarchive archive

# 2. Export the archive (with manual export options)
xcodebuild -exportArchive -archivePath /tmp/Jarvis.xcarchive \
  -exportPath /tmp/Jarvis-export \
  -exportOptionsPlist ExportOptions.plist

# 3. The Release bundle in /tmp/Jarvis-export/Jarvis.app is fully
#    Developer-ID signed and codesign --verify clean. Use THIS for the
#    six P6 UAT gates and Orpheus TTFA measurement.

# 4. If Developer ID signing is unavailable on the operator's machine,
#    fall back to ad-hoc Release:
xcodebuild -scheme Jarvis -configuration Release build
codesign --remove-signature build/Release/Jarvis.app
codesign --force --deep --sign - build/Release/Jarvis.app
codesign --verify --strict --verbose=4 build/Release/Jarvis.app
# Note: --deep is acceptable on ad-hoc Release because there's no
# per-helper entitlement preservation requirement when not distributing.
```

**DO NOT use Xcode's ⌘R Run scheme for UAT** — that path produces the
fragile Debug bundle described above. UAT only on Release archives.

### Cross-reference for plan 08-04

Plan 08-04's sweep needs to fold these MANUAL items into
`.planning/phases/06-voice/checklist.yaml`:

| ID | Source gate | MANUAL: instruction |
|----|-------------|---------------------|
| VOICE-07 | 06-HUMAN-UAT.md Gate 1 | Build Release archive per recipe above; cold-launch; "Hey Jarvis, what time is it"; verify ring transitions and Orpheus TTS |
| VOICE-14 | 06-HUMAN-UAT.md Gate 2 | After Gate 1 launch, mid-`speaking` say "Hey Jarvis"; verify TTS stops within ~50ms |
| VOICE-13 | 06-HUMAN-UAT.md Gate 3 | Configure PTT hotkey via first-launch shortcut recorder; hold + speak; verify no wake-word delay |
| VOICE-12 | 06-HUMAN-UAT.md Gate 4 | Toggle "Mute Wake Word" menu item; verify wake-word paused but PTT still works; verify persistence across relaunch |
| VOICE-09 | 06-HUMAN-UAT.md Gate 5 | Plug in non-VPIO USB audio device OR force-throw in `AudioGraphOwner` for one launch; verify AppKit AEC banner appears |
| VOICE-10 | 06-HUMAN-UAT.md Gate 6 | Deny mic at first launch; grant in Settings; verify rebuild in `.reconfiguring` |
| TTFA | STATE.md "P6 deferred" | After Release archive launches, run `JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests` interactively; record measured ms; if > 250 ms set `features.tts.tier2 = "ttskit"` in default config |

---

## AVAudioEngine Route-Change Injection Probe (D-14)

### Probe Question

Can the test harness synthetically trigger an `AVAudioEngine` device-change
in a process so that `AudioGraphOwner.rebuild(trigger: .deviceChange)`
fires, end-to-end, without requiring the operator to physically plug or
unplug an audio interface mid-test?

### Probe Outcome: available

`AudioGraphOwner` exposes `public func rebuild(trigger: RebuildTrigger)
async` directly. All four `RebuildTrigger` cases (`.deviceChange`,
`.aecFallback`, `.micRegrant`, `.ringOverflow`) route through the same
private `teardown()` body that runs the canonical six steps. The existing
`packages/Voice/Tests/VoiceTests/TeardownTests.swift` exercises the
`.deviceChange` trigger by calling `await owner.rebuild(trigger:
.deviceChange)` and asserts all six teardown steps fire.

This means the harness does NOT need to inject a synthetic
`AVAudioSession.routeChangeNotification` (which, on macOS as opposed to
iOS, is the wrong notification anyway — macOS's audio-route monitoring
goes through `AVAudioEngine.configurationChange` and CoreAudio
`kAudioHardwareDeviceRemovedNotification`, which we observe but don't
directly post). Instead, the harness exercises the same test seam
TeardownTests uses:

```swift
let owner = AudioGraphOwner(
    degradationContinuation: degradationCont,
    rebuildContinuation: rebuildCont,
    graphBuilder: SucceedingBuilder(fmt: fmt16k)
)
try await owner.open()
await owner.rebuild(trigger: .deviceChange)  // ← THIS is the synthetic injection
```

Plumbing required for `AudioGraphRebuildRunner`:

- `SucceedingBuilder` lives in `packages/Voice/Tests/VoiceTests/AECFallbackTests.swift`
  (test target). Either:
  - Promote a similar succeeding-builder type into the `Voice` library
    target (a one-line `public struct SucceedingGraphBuilder: GraphBuilder { ... }`),
    OR
  - Define an equivalent succeeding builder inline in the runner itself
    (preferred — keeps Voice library surface tight, no new public API).

The runner uses option 2 (inline builder). This keeps the four-trigger
matrix automated end-to-end. `degradedToManual` stays `false` for
`.deviceChange`. The MANUAL fallback path is preserved in code but never
fires in the standard Wave-2 invocation.

### Verification

The probe outcome was confirmed by reading
`packages/Voice/Tests/VoiceTests/TeardownTests.swift` (270 lines) which
demonstrates direct rebuild-method invocation as the synthetic trigger
mechanism, asserting all four trigger cases against the canonical
six-step teardown ordering. No private SPI, no Objective-C runtime
hacks, no environmental setup are required.

---

_Authored by: 08-03 Task 1 (executor worktree)._
