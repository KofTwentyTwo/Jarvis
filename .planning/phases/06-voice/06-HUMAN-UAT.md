# Phase 6 Voice — Human UAT Checklist

**Plan:** 06-05-controller-wiring  
**Gate type:** checkpoint:human-verify (blocking)  
**UAT machine:** Apple Silicon Mac (physical hardware required)  
**Date:** _to be filled by tester_  
**Tester:** _to be filled_

---

## Pre-flight Checks

Complete all pre-flight items before beginning the UAT session.

- [ ] `swift test --package-path packages/Voice` — all tests green (20 tests expected)
- [ ] `bash scripts/fetch-openwakeword-models.sh` run on test machine — `hey_jarvis` ONNX model present in `Resources/models/openWakeWord/`
- [ ] `bash scripts/fetch-silero-models.sh` run on test machine — Silero VAD v6.2.1 ONNX present in `Resources/models/silero/`
- [ ] `JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests` — TTFA measurement logged
  - Measured TTFA: ___ ms (target < 250 ms)
  - If > 250 ms, active TTS tier: [ ] orpheus  [ ] ttskit (TTSKit fallback activated via `features.tts.tier2`)
- [ ] `swift test --package-path packages/Voice --filter SileroContractTests.testParityProbeAtScaffold` — parity probe green
- [ ] Release archive built; `bash scripts/probe-speech-assets.sh path/to/Jarvis.app` run
  - Result: [ ] PASS  [ ] INCONCLUSIVE  [ ] FAIL
  - Notes: ___

---

## Gate 1: End-to-end Happy Path (VOICE-07)

**Test phrase:** "Hey Jarvis, what time is it"

1. [ ] Cold-launch the Release-signed Jarvis.app
2. [ ] Grant Microphone permission on first TCC prompt
3. [ ] HUD ring renders in `.idle` state (steady, no animation)
4. [ ] Say "Hey Jarvis" — ring transitions to `.listening` within ~500 ms (320 ms hysteresis + tap latency)
5. [ ] Say "what time is it" — ring shows audio-reactive RMS pulse (NOT fake sine — actual amplitude variation)
6. [ ] Stop speaking — ring transitions to `.thinking` within ~300 ms (Silero hangover)
7. [ ] Ring transitions to `.speaking` when TTS audio begins
8. [ ] Spoken answer is natural-sounding (Orpheus tara voice, ~150–250 ms TTFA)
9. [ ] After answer completes, ring returns to `.idle`

**Result:** [ ] PASS  [ ] FAIL  
**Notes:** ___

---

## Gate 2: Barge-in (VOICE-14)

1. [ ] Trigger a long answer (e.g., ask "count to 20")
2. [ ] While Jarvis is speaking (ring is `.speaking`), say "Hey Jarvis" again
3. [ ] TTS stops within ~50 ms — no audible click or pop
4. [ ] Ring transitions from `.speaking` directly to `.listening` (no intermediate `.idle` flash)
5. [ ] New utterance is captured and processed normally

**Result:** [ ] PASS  [ ] FAIL  
**Notes:** ___

---

## Gate 3: Push-to-talk (VOICE-13)

1. [ ] Set a PTT hotkey via the first-launch shortcut recorder or Settings
2. [ ] Hold the PTT hotkey and speak — ring immediately goes to `.listening(.ptt)` (no wake-word delay)
3. [ ] Release the hotkey — STT finalizes, agent processes, TTS speaks
4. [ ] PTT path does not wait for wake-word ("Hey Jarvis" not required)

**Result:** [ ] PASS  [ ] FAIL  [ ] SKIP (hotkey not configured)  
**Notes:** ___

---

## Gate 4: Mute Wake Word (VOICE-12)

1. [ ] Click the menu-bar icon → "Mute Wake Word" → checkmark appears
2. [ ] Say "Hey Jarvis" — no response (wake-word is paused; ring stays `.idle`)
3. [ ] Hold PTT hotkey + speak — PTT STILL WORKS (VOICE-12 explicit contract)
4. [ ] Restart the app — mute state persists (checkmark still shown on next launch)
5. [ ] Toggle un-mute — wake-word resumes, "Hey Jarvis" triggers normally

**Result:** [ ] PASS  [ ] FAIL  
**Notes:** ___

---

## Gate 5: AEC Fallback Banner (VOICE-09)

> Note: Triggering AEC unavailability requires either (a) plugging in a USB audio device that
> doesn't support VPIO, or (b) temporarily force-throwing in AudioGraphOwner for one launch.
> If neither is feasible, mark SKIP with reason.

1. [ ] Trigger AEC-unavailable condition (see note above)
2. [ ] HUD banner shows: **"AEC unavailable; degraded-mode active"**
3. [ ] Banner is native AppKit (NOT a webview modal — verify via Accessibility Inspector)
4. [ ] Switch to built-in mic / fix condition — banner dismisses on next graph rebuild

**Result:** [ ] PASS  [ ] FAIL  [ ] SKIP (hardware not available)  
**Notes:** ___

---

## Gate 6: Mic Re-grant (VOICE-10 trigger)

1. [ ] Deny microphone at first launch
2. [ ] Jarvis surfaces a banner with a System Settings deep link
3. [ ] In System Settings → Privacy & Security → Microphone, enable Jarvis
4. [ ] Switch back to Jarvis — audio graph rebuilds (ring shows `.reconfiguring` flicker)
5. [ ] Audio-level RMS updates in `.listening` state (real audio reactivity)

**Result:** [ ] PASS  [ ] FAIL  [ ] SKIP  
**Notes:** ___

---

## Summary

| Gate | Result | Notes |
|------|--------|-------|
| Pre-flight (swift test + scripts) | **PASS** | `swift test` 64/3-skipped/0-failed; `bash scripts/check-app-builds.sh` PASS (compile-only). Model fetch + TTFA probes deferred to Phase 8 (require physical-Mac launch) |
| Gate 1: Happy path (VOICE-07) | **DEFERRED → Phase 8** | Blocked by Xcode 26 ad-hoc-Debug bundle launch fragility; see deferral note below |
| Gate 2: Barge-in (VOICE-14) | **DEFERRED → Phase 8** | Same blocker — code-side correctness covered by `BargeInTests` 4/4 + structural assertion of single `cancelAndSubmit` call site |
| Gate 3: Push-to-talk (VOICE-13) | **DEFERRED → Phase 8** | Same blocker — code-side covered by `PTTTests` 3/3 + `NSEvent.addGlobalMonitorForEvents` wiring assertion |
| Gate 4: Mute wake word (VOICE-12) | **DEFERRED → Phase 8** | Same blocker — code-side covered by `MuteWakeWordTests` 3/3 + UserDefaults persistence test |
| Gate 5: AEC banner (VOICE-09) | **DEFERRED → Phase 8** | Same blocker — code-side covered by `AECFallbackBannerTests` 4/4 + structural reuse of `HUDBannerCoordinator` (modal-lint enforced from Phase 5) |
| Gate 6: Mic re-grant (VOICE-10) | **DEFERRED → Phase 8** | Same blocker — additionally couples to AudioGraph rebuildStream which is Phase 1 territory |

**Overall result:** **PARTIAL — code-side correctness verified, physical-Mac launch UAT deferred to Phase 8**

**Tester signature:** Orchestrator (J.M. session 2026-04-27, agreed via interactive decision)  
**Date:** 2026-04-27

---

## Deferral Note: Why the launch-driven gates ship to Phase 8

During Plan 06-05 post-wave validation, attempts to launch the Debug-built `Jarvis.app` revealed a **pre-existing Xcode 26 / Swift 6 / ad-hoc-Debug-codesign fragility** that is independent of any Plan 06-05 code:

1. Even with `SWIFT_ENABLE_DEBUG_DYLIB: NO` set in the Debug config (commit `fde2aad` from the prior session), Xcode 26 still produces `Jarvis.debug.dylib` and `__preview.dylib` next to the main exec.
2. After the build's post-codesign step succeeds, `codesign --verify` reports `invalid Info.plist (plist or signature have been modified)` — something downstream of post-codesign (likely Xcode 26's preview-mode dylib generation OR Info.plist re-stamping for incremental dependencies) is invalidating the bundle after the build claims success.
3. The pre-codesign script writes `JarvisEntitlementsVerified=YES` correctly into the built bundle's Info.plist, but the marker is observed as `false` post-build — same downstream mechanism.
4. Manual re-codesign of the bundle's main exec breaks `Jarvis.debug.dylib`'s Team-ID match, causing dyld to refuse to load the dylib.

**This is Phase 8 (Hardening) territory.** Phase 8 explicitly owns Developer ID Application signing, notarization, and codesign chain stability per `.planning/ROADMAP.md`. The pre-existing CDHash drift on ad-hoc Debug bundles (noted in `.planning/STATE.md`'s Decisions/context section from the prior session) is the same class of issue. Continuing to debug this in Phase 6 is scope creep.

**What IS verified for Phase 6 close-out:**
- `swift test --package-path packages/Voice` — 64 cases / 3 env-gated skips / 0 failed (20 new tests from Plan 06-05: VoiceController, BargeIn, PTT, MuteWakeWord, AECFallbackBanner, VoiceWiring)
- `bash scripts/check-app-builds.sh` — App target compiles cleanly with the new Voice-package wiring
- All five Plan 06-05 invariants (VOICE-07/09/12/13/14) covered structurally by deterministic XCTest cases
- `OrpheusTTFATests` env-gated probe ships and is runnable interactively (`JARVIS_REAL_MODELS=1`) once Phase 8's signing chain unblocks Release-archive launch

**What ships to Phase 8:**
- Resolve Xcode 26 ad-hoc-Debug-bundle launch fragility (Info.plist marker stability + dylib Team-ID consistency)
- Drive the six gates above on a Release-signed archive
- Sign back here with PASS / FAIL / NOTES per gate

---

## Resume Signal

After completing UAT, reply to the agent with:

- `"voice UAT passed"` — if all blocking gates pass (gates 1, 2, 4 are blocking; 3, 5, 6 are non-blocking)
- Or describe any failures with details

If TTFA was > 250 ms during OrpheusTTFATests, mention which TTS tier (orpheus / ttskit) was active during UAT.  
If the AEC fallback couldn't be triggered, note "AEC fallback untested" — Phase 8 hardening will revisit.

---

_Generated by: GSD executor (06-05-controller-wiring Task 4)_
