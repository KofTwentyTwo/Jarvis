# Voice Subsystem Audit — 2026-05-12

Read-only audit, HEAD `a5999e2`. Live host PID 18811 is running with
`installVoice: VoiceController started` in `system.2026-05-12.log`; voice
BootHealthProbe reports `ok` (variant=aecOn, 16 kHz Float32). Audit traced
the canonical wake → STT → orchestrator → TTS → HUD flow line-by-line and
diffed it against the 2026-05-03 / 2026-05-04 findings.

The big lifts from prior audits are real: models bundle into
`Contents/Resources/Models/{openWakeWord,silero}/` (verified in
`build/Build/Products/Debug/Jarvis.app/...`), `LiveSpeechAnalyzerBridge` is
no longer a `_ = chunk` stub, `TTSEngineActor` is constructed in production
via `VoiceOutputWiring.makeTier1Engine()`, `wakeWordDAG.start(ring:)` is
wired against a real ring, `ProductionChunkPump` subscribes via
`AudioGraphOwner.subscribe()` (no SPSC sample-stealing), and
`AudioLevelEmitter` is constructed in `installVoice` against its own
broadcaster subscription.

But three new "wired but dead" bugs and several integration mismatches
remain — concentrated at the rebuild boundary, the STT backend factory, and
the TTS event stream. Voice on a cold-launched, freshly-permitted machine
**does** work for one wake-word turn. Voice **does not** survive any audio
graph rebuild (device change, mic re-grant, ring overflow). And the
ducking/HUD signal the rest of the system depends on is structurally
mismatched against the only place it ever fires.

---

## P0 — Critical (will silently break voice in production)

### P0-1. `cancelInFlight` permanently kills wake-word on every audio-graph rebuild

`App/AppDelegate.swift:1192–1194`:

```swift
await graphOwner.setCancelInFlight { [wakeWordDAG] in
    await wakeWordDAG.cancel()
}
```

`WakeWordDAG.cancel()` (`packages/Voice/.../WakeWordDAG.swift:137–142`) calls
`streamCont.finish()` — the public `wakeWordStream` is now closed forever.
`VoiceController.spawnWakeWordConsumer`'s `for await event in stream` exits.
`AudioGraphOwner.teardown` (`AudioGraphOwner.swift:265–290`) invokes
`cancelInFlight` on **every** rebuild trigger: `.deviceChange`,
`.micRegrant`, `.ringOverflow`, `.aecFallback`. The new graph builds with a
fresh ring, but nothing re-arms the DAG, and the consumer Task has already
exited so even calling `start(ring:)` again wouldn't drive listeners that
have already finished the for-loop.

The DAG file documents the correct contract at line 144–162: a separate
`stopFeed()` method exists *specifically* so `cancelInFlight` can stop the
feed Task **without** finishing the stream, with a literal docstring
warning: *"Previously `cancelInFlight` called `cancel()` which finished the
stream — combined with the `lastMicStatus = false` startup bug in
`AudioGraphOwner.startMicRegrantWatcher`, the wake path died ~2 s after
launch on every cold start."* The mic-regrant startup bug was fixed
(`AudioGraphOwner.swift:340–354` primes `lastMicStatus`); the AppDelegate
wiring of `stopFeed()` was not. The fix is one line.

**Plus** the rebuild-completion consumer at `AppDelegate.swift:1125–1133`
only dismisses the AEC banner; it never calls
`wakeWordDAG.start(ring: newRing)`. So even after switching to `stopFeed()`,
the DAG needs to be re-armed against the new ring inside the rebuild
consumer.

Detection on the live host is hard because the boot probe only checks
`variant != nil` (see P1-2). Symptom is "wake word stopped working after
plugging in headphones" — exactly the canonical "wired but dead" pattern.

### P0-2. STT backend hard-coded; ignores `PerTurnSnapshot.stt`

`App/AppDelegate.swift:1272`:

```swift
sttFactory: { STTBackendSelector.make(backend: "speech_analyzer") },
```

The closure ignores `configStore` entirely. Setting
`stt.whisperKitFallback = true` in config changes nothing for voice — the
factory always builds `SpeechAnalyzerSTT`.

To make it worse, the `get_self_state` tool dispatcher *does* read from
config (`AppDelegate.swift:2025–2028`):

```swift
return snap.stt.whisperKitFallback ? "whisperKit" : "speechAnalyzer"
```

…and those strings are also **wrong** for `STTBackendSelector.make`. The
selector accepts `"speech_analyzer"` / `"whisperkit"` (snake_case, lower);
the closure returns `"whisperKit"` / `"speechAnalyzer"` (camelCase, capital
W/A). If anyone ever wires the snapshot.stt.backend through, every value
hits the `default` case and falls back to SpeechAnalyzer. Two unrelated
bugs — name mismatch + hard-coded factory — both pointing the same
direction (WhisperKit is unreachable).

Combined with P0-3 (asset-missing maps to STTError), this means: if
SpeechAnalyzer asset download fails on a fresh-install Release, the user
cannot fall back to WhisperKit via config — they have to ship a new build.

### P0-3. `.ttsStopped` is emitted ONLY on barge-in; normal completion never releases ducking

`TTSEngineActor.swift:91–178` runs `synthesize(_:tier:voice:)` and yields
`.started`, `.firstAudio(at:)`, `.finished` — never `.ttsStopped`. The class
header (lines 21–23) and `TTSEvent.swift:7–12` document the canonical
sequence as `started → firstAudio → ... → finished → ttsStopped`, and the
`TTSInterrupt.swift:97` grep gate enforces `wc -l == 1` for `.ttsStopped`
emission sites *across the whole TTS package*. The one site that emits it
is `InterruptSequence.run` — i.e. **only when barge-in fires**.

Per the file-level comment "Ducking releases ONLY on `.ttsStopped`" (and
the I4 test `TTSInterruptTests.swift:181` which validates the release path
against `.ttsStopped`), any future consumer of `ttsEventStream` that
implements ducking will leave the input duck engaged forever after a normal
spoken reply. There is no ducking consumer wired in production yet
(`grep -rn ttsEventStream App/ packages/.../Sources/` only finds the
`TTSEngineActor` definition site itself), so this isn't biting anyone
today — but the design contract is broken and the first production
consumer of `ttsEventStream` will inherit a silent bug. Either
`TTSEngineActor.synthesize` needs to emit `.ttsStopped` on natural
completion (in addition to `.finished`), or the contract docs need to be
rewritten to say "ducking releases on `.finished` for natural completion
and `.ttsStopped` for barge-in" — and the InterruptSequence comment
loosened from "ONLY site that emits".

`AVSpeechSmokeTests` / `TTSEngineActorTier1Tests.swift:37` filter the event
stream for `.ttsStopped` while breaking out of the for-loop. If the test
ran a real synthesis it would hang, but the suite passes because it uses
short test strings and the test runner aborts before timeout. (The
`OrpheusSerializationTests` use `ScriptedSpeechModel` which is a separate
event source.) The contract / test pairing here is exactly the
"impedance mismatch hidden by mocks" shape from the canonical example.

### P0-4. `VoiceTTSAdapter.tierResolver` is never wired; `tts.tier` config is dead

`App/AppDelegate.swift:1236`:

```swift
let ttsAdapter = VoiceTTSAdapter(engine: VoiceOutputWiring.makeTier1Engine())
```

`VoiceTTSAdapter.init` (`App/Voice/VoiceTTSAdapter.swift:29–35`) accepts
`tierResolver: @escaping @Sendable () async -> TTSTier = { .tier1 }` but
AppDelegate passes only `engine:`. So the resolver is the default constant
`{ .tier1 }`. Setting `tts.tier = "tier2"` in config does nothing for the
real synthesis path — only for the `get_self_state` tool, which reads
`snap.tts.tier` directly via a separate closure (line 2020–2024).

Today this hides P0-5 (no Orpheus shipped anyway, so tier-1 is correct).
The moment Orpheus weights ship, the user can't enable tier-2 via config.

---

## P1 — High (real correctness gaps, not yet user-fatal)

### P1-1. `OpenWakeWordSession.melFrameBuffer` and `embeddingBuffer` grow without bound

`packages/Voice/.../OpenWakeWordSession.swift:175–201`. Streaming path
appends mel frames into `melFrameBuffer` on every `feed(samples:)` and
advances `nextEmbStart` by 8 frames at a time. Mel frames are never popped
or trimmed; `embeddingBuffer.append(emb)` (line 191) is also append-only.
The classifier only reads the most recent 16 embeddings (`suffix(16)`),
but the rest of the buffer is retained forever.

At one mel frame per `feed` call (80 ms @ 16 kHz, the production cadence),
24 hours of always-on listening accumulates roughly:

- ~1.08M mel frames × 32 floats × 4 B  ≈ 130 MB live retained
- ~135k embeddings × 96 × 4 B          ≈ 50 MB

Plus the `[[Float]]` Swift Array-of-Array overhead. The system survives
overnight because `WakeWordDAG` cancels and rebuilds on every audio-graph
rebuild — *if you fix P0-1*. Today the leak is masked by P0-1: the DAG
dies before it can leak. Fix one without the other and memory grows
unbounded. Recommend trimming `melFrameBuffer` and `embeddingBuffer` on a
rolling-window basis (keep last `76 + embStride` mel frames; keep last 16
embeddings).

### P1-2. `VoiceBootHealthProbe` doesn't probe anything voice-specific

`App/Boot/BootHealthProbes.swift:213–266`. Status `.ok` only requires:
1. `audioGraphOwner` non-nil
2. `micStatus == .authorized`
3. `currentVariant != nil`

It does **not** verify:
- the wake-word DAG is actually feeding (P0-1 leaves the probe reporting
  `ok` even after the wake path is dead)
- SpeechAnalyzer assets are downloaded (`SFSpeechErrorCode.assetUnavailable`
  doesn't surface until the first `transcribe()` call)
- WhisperKit fallback model weights exist (only matters once P0-2 is fixed)
- TTS engine is alive (Tier-1 AVSpeechSynth always claims success even
  on a denied audio output route)

Hence the live log shows `voice state=ok` every probe interval despite
P0-3 / P0-4 being latent. Recommend: cheap watchdog that asserts the
wakeWordTask is still alive *and* the wakeWordDAG's feed Task isn't nil.

### P1-3. `VoiceController.vadFactory` returns same `SileroVAD` every session; never `reset()`

`App/AppDelegate.swift:1271`: `vadFactory: { sileroVAD }` captures the
single instance constructed at line 1080. `SileroVAD.reset()` exists
(`packages/Voice/.../SileroVAD.swift:292`) and zeroes the LSTM hidden
state `h, c` plus the `wasSpeech` flag — but `VoiceController` never
calls it. `startSTTSession` (line 380 of VoiceController) creates a fresh
chunk stream and pump but reuses the same VAD instance.

Effect: LSTM hidden state from the end of session N persists into the
start of session N+1. After session N's `.speechEnd`, the LSTM state
encodes "we just exited speech"; the first 1–3 windows of session N+1
inherit that bias and may misclassify quiet onset as `.silence`. Worst
case: a soft-spoken first syllable goes undetected and the user's
opening word is dropped from the STT input.

This is hard to detect in tests because most tests construct a fresh
VAD per case. Recommend: call `await vad.reset()` at the top of
`startSTTSession` (one line; VAD is constructed lazily-per-call via the
factory, but the closure pattern caches the single instance, so reset is
the right idempotency primitive).

### P1-4. `voiceHudCont.finish()` on `shutdown()` is a one-way ratchet

`packages/Voice/.../VoiceController.swift:181` finishes the HUD continuation.
The continuation flows into `HudStateCoordinator` (constructed at
`AppDelegate.swift:2475`). After `voiceController.shutdown()`, the
coordinator's voice subscriber Task exits its for-loop and the HUD
permanently ignores future voice intents — even if voice is reinstalled.

Today `shutdown()` is called from one site (`applicationWillTerminate`,
`AppDelegate.swift:993` if memory serves), so this doesn't bite in normal
exits. But the install path's failure branches (line 1163, 1174–1177,
1219) **don't** call `shutdown` — they `return` early after constructing
some subset of state. If we ever add a `reinstall on resume from sleep`
path, finishing the cont on shutdown means voice can't come back without
restarting HudStateCoordinator. Recommend: don't finish the cont in
`shutdown`; the actor's drop already releases its end of the stream.

### P1-5. AgentHudIntent stream is dormant — HUD has no signal during thinking/speaking

`AppDelegate.swift:2487–2490` constructs the AgentHudIntent stream and
stores `dormantAgentContinuation`, but **no production code ever yields
into it**. `grep -rn dormantAgentContinuation App/` returns only the
declaration and the assignment.

Combined with `VoiceController.hudIntentFor` (lines 626–632), which maps
`.thinking` / `.speaking` / `.idle` all to `.silent`, the HUD ring sees:
- `.listening` when wake-word fires (real signal)
- `.reconfiguring` during audio graph rebuilds (real signal)
- `.silent` everywhere else (thinking and speaking look the same as idle)

The HUD ring doesn't change shape during agent thinking or TTS playback.
This is cross-cutting with the HUD audit, but the voice surface owns one
end of it: `VoiceController` could emit a distinguishing `.speaking` /
`.thinking` intent (extends VoiceHudIntent enum), or the agent install
path could pump AgentHudIntent values from the orchestrator events
broadcaster. Either fix is fine; neither exists.

---

## P2 — Medium (correctness drift, hygiene, lurking)

### P2-1. `STTBackendSelector` string mismatch is a documentation lie

`STTBackendSelector.backendSpeechAnalyzer = "speech_analyzer"` (snake_case)
vs `AppDelegate.swift:2028`'s `"speechAnalyzer"` (camelCase). Selector
exposes its constants as `public static let backend*` so callers shouldn't
hard-code strings, but both sides do. Recommend: rename the constants OR
use them at the call sites; pick one shape consistently. (See P0-2.)

### P2-2. `SpeechSynthDelegate.setPendingContinuation` overwrites without resuming

`AVSpeechSynth.swift:89–93`. If two concurrent `speak` calls arrive,
the second `setPendingContinuation` replaces the stored continuation
without resuming the first. The lost continuation never resumes and the
first `withCheckedContinuation` block hangs forever. Today this can't
fire because `TTSEngineActor`'s serial executor serializes access — but
the type itself is `@unchecked Sendable` and exposes the race. If anyone
ever uses `AVSpeechSynth` outside the actor, the bug ships. Recommend:
on `setPendingContinuation`, if there's an existing continuation, resume
it before replacing (matches the `didCancel` semantics from
`stopSpeaking(at:.immediate)`).

### P2-3. WhisperKit feature flag exists but no path through reaches it

`Config/Sources/Config/STTConfig.swift` has `whisperKitFallback: Bool`;
default-config.json sets it `false`. Even if a user flips it, the
hard-coded factory at `AppDelegate.swift:1272` ignores them. The flag is
test-quality dead code — it appears in `PerTurnSnapshot` because the
config-to-snapshot pipeline is generic, but no production consumer
exists. Tracks alongside P0-2.

### P2-4. Vision-isolation invariant is enforced; vision-audit may want to flag inverse

`scripts/check-presence-vision-isolation.sh` Layer 3 gate keeps TTS
engine references out of `AppDelegate.swift` — that's the reason
`VoiceOutputWiring.swift` lives in `App/Voice/` (per its docstring). The
invariant is intact (no `TTSEngineActor(` in `AppDelegate.swift`).
Voice-side cleanliness OK; flagging here as documentation more than a
bug.

---

## Verified healthy

These were burned in prior audits and survived end-to-end re-trace:

- **Model files bundle correctly.** `scripts/copy-voice-models.sh` runs
  as an Xcode build phase (`project.yml:309–324`), maps lowercase
  `openwakeword` → `openWakeWord`, validates manifests have no
  `PLACEHOLDER_` SHA, hard-fails on missing files, and `rsync -a
  --delete` keeps the bundle clean. Verified physical files at
  `build/Build/Products/Debug/Jarvis.app/Contents/Resources/Models/`.
- **`LiveSpeechAnalyzerBridge` actually wires SpeechAnalyzer.**
  `SpeechAnalyzerSTT.swift:185–323` constructs `SpeechTranscriber`,
  queries `bestAvailableAudioFormat`, builds an `AVAudioConverter` when
  needed, and spawns the result-drain Task **before** `analyzer.start`
  so early partials aren't lost. The 2026-05-03 `_ = chunk` stub is
  gone. `feed()` packs PCM via `PCMBufferBuilder`, converts if needed,
  yields `AnalyzerInput(buffer:)` on the input continuation. `finish()`
  finishes the builder, calls `finalizeAndFinishThroughEndOfInput()`,
  awaits the results task.
- **`ProductionChunkPump` uses subscriber fan-out.**
  `App/Voice/ProductionChunkPump.swift` subscribes via
  `AudioGraphOwner.subscribe()` (per-subscriber ring), drains at
  1024-frame windows, unsubscribes on exit. Track B-7 sample-stealing
  invariant intact.
- **`AudioLevelEmitter` is wired in production.**
  `AppDelegate.swift:1287–1292` subscribes via the broadcaster and
  hands the subscription to `AudioLevelEmitter`. `VoiceController`
  starts/stops it on listening-boundary transitions. P1-1 from the
  2026-05-04 audit closed correctly.
- **Mic TCC permission is requested.** `installVoice` blocks on
  `AVCaptureDevice.requestAccess(for: .audio)` before
  `graphOwner.open()` (line 1149–1151). Verified in live log:
  `installVoice: requesting mic permission (.notDetermined)` →
  `mic permission granted`.
- **AEC fallback is real.** `AudioGraphOwner.buildGraph(preferAec:)`
  catches `aecUnavailable`, emits degradation event, retries with
  `aec=false`, throws `bothVariantsFailed` if both fail. Live log
  shows `variant=aecOn` and BootHealth `voice state=ok` —
  consistent.
- **`OrchestratorEventBroadcaster` voice priority** correctly protects
  `.turnEnd` and `.error` from drop; voice translator subscriber at
  `AppDelegate.swift:1855–1889` gates on `turnSourceWasVoice` before
  emitting `turnEnded` into `VoiceOrchestratorAdapter`.
- **Single-writer HudState gate passes.**
  `bash scripts/check-single-writer-hudstate.sh` clean.
- **`check-no-null-voice-adapters.sh` passes.** Confirmed
  `VoiceTTSAdapter(engine: nil)` from the 2026-05-03 audit is gone;
  AppDelegate constructs a real engine.
- **VoiceController shutdown cancels all background tasks** including
  `sttFinalizeTask` (P1-3 closure from 2026-05-04). The session-id
  generation guard at `handleSTTFinalized(text:sessionId:)` is in
  place.
- **Anti-pattern guards intact.** Transcript text never logged (T-06-05-03);
  `transcriptStore?.append` is called on submit/cancelAndSubmit
  (BLOCKER-1); single `cancelAndSubmit` call site in `bargeIn()`
  (VOICE-14); 200 ms barge-in debounce (T-06-05-04).

---

## Open questions

1. **Does the user observe wake-word still working after plugging
   headphones in?** P0-1 predicts "no, until app restart". If the
   live host is producing voice turns post-headphone-swap, my read
   of the rebuild path is wrong somewhere; please cross-check.
2. **Is `tts.tier = "tier2"` ever actually expected to wire through
   today?** P0-4 is technically dead config because Orpheus weights
   aren't shipped, but the chain breaks before it gets to the
   "tier-2 → tier-1 degrade" path documented at
   `TTSEngineActor.swift:114–116`.
3. **`AVSpeechSynthesisVoice(identifier: "en-US")` returns nil but
   the fallback `language: "en-US"` works.** Worth a config sanity
   check that future custom voices use `com.apple.voice…` identifier
   strings.

---

## Top-3 summary

1. **P0-1 — wake-word dies on every audio-graph rebuild.**
   AppDelegate wires `cancelInFlight → wakeWordDAG.cancel()`
   (finishes the stream) instead of the existing `stopFeed()`
   (preserves stream across rebuilds). The fix was already coded and
   documented in the DAG; the call site was never updated. Plus the
   rebuild consumer never re-arms the DAG against the new ring. Net
   effect: wake word stops working on first device-change /
   mic-regrant / ring-overflow event of the session.

2. **P0-2 — STT backend hard-coded; WhisperKit fallback unreachable.**
   `STTBackendSelector.make(backend: "speech_analyzer")` is a literal
   string in `installVoice`, ignoring `PerTurnSnapshot.stt`. Compound
   bug: the `get_self_state` tool emits `"whisperKit"` / `"speechAnalyzer"`
   (camelCase) while the selector accepts `"whisperkit"` /
   `"speech_analyzer"` (snake_case) — even fixing the hard-code would
   land in the default `unknown backend` fallthrough.

3. **P0-3 — `.ttsStopped` contract broken; normal synthesis never
   releases ducking.** `TTSInterrupt.swift` grep-gates `.ttsStopped`
   emission to **one** site (the barge-in path), but the
   `TTSEngineActor` header and `TTSEvent.swift` say
   ducking-release fires only on `.ttsStopped`. Natural completion
   emits `.finished` and nothing else. No production ducking consumer
   exists yet, so this isn't biting today — but the contract is
   structurally broken and will silently dock any future consumer.
