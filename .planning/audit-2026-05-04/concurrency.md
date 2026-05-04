# Concurrency, Correctness & Safety Audit — 2026-05-04

## Verdict: MOSTLY-SAFE

The architecture is disciplined: actor boundaries are respected almost everywhere, single-writer chains for `nonisolated(unsafe)` storage are well-documented, the `BufferBroadcaster` fan-out is correctly lock-free on the publish path, and `ChildSpawnGate` is enforced in production. There are, however, two HIGH-severity findings that should be fixed before considering the voice loop production-grade — most importantly an unstored `Task` in `VoiceController.startSTTSession` that retains `self` strongly, lives across session boundaries, and re-enters the actor with stale text — plus several MEDIUM issues around RingBuffer memory ordering, AudioLevelEmitter not yet wired through the broadcaster (acknowledged in SESSION-STATE), and a fragile error-domain substring match in `SpeechAnalyzerSTT.mapError`. None of the today-churn commits (Track A → Track D) introduces a fresh CRITICAL race, but several extend existing patterns that already had known issues.

## Findings

### CRITICAL

_None observed._

### HIGH

- **`packages/Voice/Sources/Voice/VoiceController.swift:374-386` — unstored partials/finalize Task strongly retains `self`, has no cancellation hook, and can re-enter the actor with stale results.**

  `startSTTSession` spawns three tasks: `chunkPumpTask`, `vadInterceptorTask`, and an **unstored** `Task { [self] in ... }` that drains partials, then calls `provider.finalize()`, then `await self.handleSTTFinalized(text:)`. None of `endSTTSession`, `shutdown`, or a fresh `startSTTSession` cancels this task. Because it captures `[self]` (strong) it also keeps the controller alive past `shutdown()`.

  - **Repro:** Start a session, end it via VAD or `pttUp`, then immediately call `startSTTSession` again before `provider.finalize()` returns (Whisper or sluggish SpeechAnalyzer can take seconds). The first session's drain Task eventually calls `handleSTTFinalized(text: "hello")` while `state` is now `.listening` for a NEW utterance — `guard case .listening = state` passes — and the controller submits the OLD text. There is no per-session generation guard.
  - **Fix:** Store the drain as a property (`partialsDrainTask: Task<Void, Never>?`); cancel it in both `endSTTSession` and `shutdown`; capture a session-id local at start and have `handleSTTFinalized` early-return if session-id is stale. Use `[weak self]` instead of `[self]`.

- **`packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:89-92` — fire-and-forget `Task { try await self.bridge.finish() }` is unstored; `finalize()` can hang or race the bridge.**

  Inside `feedTask`, after the chunk loop completes, an inline anonymous Task calls `bridge.finish()`. That Task is the only thing that drives `inputBuilder.finish()` and `analyzer.finalizeAndFinishThroughEndOfInput()`. The outer `finalize()` then does `await feedTask?.value` (which returns as soon as the anonymous Task is *spawned*, not completed) and immediately calls `bridge.finalText()`, which awaits `resultsTask?.value` inside the bridge — and `resultsTask` only completes once the analyzer sees end-of-input.

  - **Repro:** If the anonymous Task is cancelled (e.g. via a future structured cancellation propagation) or starves, `finalText()` blocks forever. Today the chain works because nothing cancels it, but the comment "DO NOT block on await analyzer.finish() synchronously" was applied here too aggressively — the reason was VAD deadlock, not feed-loop deadlock. Inside `feedTask` the synchronous form is correct.
  - **Fix:** Replace lines 89-92 with `try? await self.bridge.finish()` directly inside `feedTask`. The whole point of `feedTask` is to be the serial owner of feed→finish ordering.

- **`packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift:148-150,67-94,101-112` — `writeIdx` / `readIdx` / `_overflowFirstObservedAt` are plain `var` accessed cross-thread, not atomic.**

  The doc comment claims "atomic load/store via `nonisolated(unsafe)` + explicit memory-ordering conventions" (line 25), but the implementation is plain `&+=` and direct reads of `UInt64` and `var [Float] storage`. On Apple Silicon (ARM64) aligned 64-bit loads/stores ARE atomic by the architecture, so torn reads will not occur — but Swift's optimizer is free to reorder, hoist, or coalesce these accesses across function boundaries because there is no `Atomic`, no memory-fence, and no `volatile`. The producer-side write of `writeIdx` and the consumer-side read of `writeIdx` (`computeLagMs`, `readMono16k`) communicate sample availability — without a release/acquire pair, the consumer may see `writeIdx` advanced while `storage[slot]` still holds the prior value.

  - **Repro:** Hard to trigger empirically (ARM64 has a relatively strong memory model and AVAudioEngine's tap thread does its own work that flushes), but the contract is technically broken. `OutOfOrderRead` is the failure mode: consumer reads `into[i] = storage[slot]` before producer's write to that slot is visible. Probability is low but not zero.
  - **Fix:** Use `Atomic<UInt64>` from `swift-atomics` (already a dep elsewhere) or `OSAllocatedUnfairLock` for the index pair. Stick a `withMemoryRebound` + atomic load/store on indices; storage[] doesn't need to be atomic if indices are. Same for `_overflowFirstObservedAt` — it's read by `overflowWatcher` (in an actor Task) while written on the tap thread.

- **`App/AppDelegate.swift` (no audio-level wiring) — `AudioLevelEmitter` is built only in tests; production HUD pulse never reflects mic RMS.**

  Confirmed via `rg -n "AudioLevelEmitter\("` — only `VoiceControllerTests.swift:89` constructs one. SESSION-STATE flags this. The code shape that DOES wire it (`VoiceController.audioLevelEmitter`) takes a `RingBuffer`, not a `BufferBroadcaster.Subscription`, and `AudioLevelEmitter.init(ring:bus:)` accepts a raw ring directly — meaning a future production wire-up that passes `audioGraphOwner.ringBuffer` will steal samples from `WakeWordDAG`, regressing exactly the bug Track B-7 fixed.

  - **Repro:** Naive future commit: `voiceController.audioLevelEmitter = AudioLevelEmitter(ring: audioGraphOwner.ringBuffer, bus: ...)`. Wake word stops firing (or fires intermittently) because the emitter is reading from the same primary subscription.
  - **Fix:** Change `AudioLevelEmitter.init` to accept a `BufferBroadcaster.Subscription` (or call `audioGraphOwner.subscribe()` internally and store the subscription so it can be unsubscribed in `stop()`). Document that NEW consumers MUST go through the broadcaster — comment on the public init is the right place to enforce by docs since the type system cannot distinguish "primary" from "subscribed" rings.

### MEDIUM

- **`packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:128-141` — `mapError` uses `nsError.domain.contains("speech")` and `localizedDescription.lowercased().contains("asset")`.**

  Substring match on the error domain is fragile. Apple's domain is `com.apple.speech.SFSpeechErrorDomain` today; that's stable, but the substring catch is too loose ("speech" matches anything localizable that happens to share the substring) and too tight (case-sensitive on the user-facing locale-dependent description). The bigger issue: `SFSpeechErrorCode.assetUnavailable` raw value isn't necessarily `1` on every macOS — the audit comment claims it but I couldn't find a doc confirmation. If Apple renumbers in a point release (or the result is wrapped by Foundation translation), the mapping silently degrades to `STTError.finalizationFailed(underlying:)` and the operator never sees the asset-missing banner.

  - **Fix:** Match by `nsError.domain == SFSpeechErrorDomain` (typed constant) and `nsError.code == SFSpeechErrorCode.assetUnavailable.rawValue`. Drop the `localizedDescription` fallback — if the typed match misses, log the raw error rather than silently classifying it.

- **`packages/Voice/Sources/Voice/VoiceController.swift:374,219,252` — closures capture `[self]` strongly on long-lived Task chains.**

  `wakeWordTask`, `orchestratorTask`, and the unstored partials drain Task all capture `[self]` (strong) rather than `[weak self]`. The first two are stored and cancelled in `shutdown()`, so this is OK in practice — but the convention across the codebase elsewhere is `[weak self]`, and the partials drain (HIGH finding above) is a real leak.

  - **Fix:** Standardize on `[weak self]` and early-return on nil. Cosmetic for the stored ones, load-bearing for the unstored one.

- **`packages/Vision/Sources/Vision/CameraCapture.swift:153-170` — `frameStream(forPresence:)` has a registration race where samples between stream creation and `attachFrameContinuation` running are dropped.**

  `frameStream` is `nonisolated`, returns a fresh `AsyncStream` immediately, but registration with the live `VideoSampleDelegate` happens via `Task { ... await self.attachFrameContinuation(...) }` which crosses the actor boundary. Any frames the AVCapture queue delivers between the synchronous return of the stream and the Task running are seen by the delegate but not yet routed to the new continuation. This isn't a correctness bug for `PresenceMonitor` (which ingests at video frame rate and tolerates frame drops), but if a future consumer asserts "I should see at least one frame within N ms of subscribing" they'll flake.

  Secondary nit: `cont.onTermination = { ... await self?.detachFrameContinuation(token:) }` schedules detach for a token that may never have been registered (if termination fires before the attach Task runs). `VideoSampleDelegate.remove(token:)` is no-op-safe so this is benign.

  - **Fix:** Make `frameStream` `async` and do the attach synchronously inside the actor. Or pre-register the token in a separate atomic step before returning the stream.

- **`App/AppDelegate.swift:892-922` — chunk pump's `Task.detached` does not propagate cancellation observability through `MainActor.run` hop.**

  The pump is a detached Task that resolves the audio graph owner via `await MainActor.run(body: { self?.audioGraphOwner })`. If `VoiceController.endSTTSession` cancels `chunkPumpTask`, cancellation propagates fine via `Task.isCancelled`. But if the pump is in the middle of `await MainActor.run(...)` waiting for the main thread (e.g., a UI burst is hogging it), `Task.isCancelled` doesn't preempt — `MainActor.run` doesn't observe cancellation. In practice the main thread is rarely contended hard enough to matter; flagged as smell.

- **`packages/Vision/Sources/Vision/VllmMlxSidecar.swift:148-162` — `startupTask` cleanup on success leaves a completed task referenced.**

  On the success path, `startupTask = task` is set but never cleared. Subsequent `ensureRunning` calls hit the `if let h = handle, h.isRunning { return }` early exit and bypass the task path, so functionally fine — but `startupTask` retains the completed task indefinitely until the actor deinits. Trivial leak.

  - **Fix:** Set `startupTask = nil` after `await task.value` on success too.

### LOW

- **`packages/Voice/Sources/Voice/TTS/AudioSink.swift:37` — `public nonisolated(unsafe) var lastFadeSamples` is a writable test seam on a public API.**

  Test seam exposed as public mutable state. If production code mistakenly writes to it from anywhere but the cosineFadeOut path, no compiler check catches it. Style-only; mark `internal` or move into a test-only protocol.

- **`packages/Vision/Sources/Vision/VllmMlxSidecar.swift:140-142` — `URL(string: "http://127.0.0.1:\(port)/health")!` force-unwrap.**

  Literal http URL with a constructed integer port; safe but conventionally avoided. `URLComponents` would make linters happy.

- **`packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:170-191` — six `nonisolated(unsafe)` fields rely on the documented "single-writer-per-phase" discipline.**

  This is correct as documented (the surrounding `SpeechAnalyzerSTT` chains start → feed* → finish → finalText through one feedTask). But the bridge type itself is class-shaped and the discipline is not type-enforced. A test that exercised the bridge directly without going through the chain would race. Acceptable risk given the surrounding contract; flagged for awareness.

- **`packages/AgentCore/Sources/AnthropicProvider/SSELineReader.swift:31` — comment notes `@unchecked Sendable` would be wrong; correctly chose to leave it constrained.**

  Good. Credit.

- **`packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:62` — `Task.detached { ... while !Task.isCancelled }` is the right pattern; `try? await Task.sleep` swallows cancellation.**

  The `try? await Task.sleep(nanoseconds:)` swallows `CancellationError` then `guard !Task.isCancelled else { break }` catches it. Slightly redundant but defensive — fine.

## Today's churn — concurrency review

Reviewing each commit on `develop` since 2026-05-03 for concurrency-relevant changes:

- **`bce725b` Track B-7 (BufferBroadcaster):** The fan-out implementation is correctly lock-free in steady state. `OSAllocatedUnfairLock<[Subscription]>` snapshot copy is the right primitive for a real-time tap thread (Apple blesses unfair lock for tap threads when contention is rare). `Subscription.unsubscribe` is idempotent (`broadcaster = nil` after first call). No concerns.

- **`c7f9ece` Track B-6 (VAD-gated session end):** The VAD interceptor's `Task { [weak self] in await self?.endSTTSession() }` (line 470) is the correct pattern to avoid actor-reentry deadlock. The break-after-trigger plus `didTrigger` guard is correct. One subtle correctness point: when `endSTTSession` calls `vadInterceptorTask?.cancel()`, the current VAD task is the one being cancelled — but it has already broken out of the loop and is returning, so the cancel is a no-op. Fine.

- **`61aed20` Track B-5 (chunk pump):** `chunkPumpTask = Task.detached { [pump] in await pump(rawCont) }` is correct. Cancellation propagates because the pump's `while !Task.isCancelled` loop checks each iteration. The `rawCont.onTermination = { _ in /* pump's Task cancellation handles cleanup */ }` is a comment-only no-op which is correct: if `rawStream` is finished externally, the pump still runs until cancelled and its `cont.finish()` at loop exit closes the rawCont a second time — `AsyncStream.Continuation.finish()` is idempotent. Fine.

- **`e9c0a34` Track B-4 (LiveSpeechAnalyzerBridge):** This commit introduced the unstored `Task { try await self.bridge.finish() }` pattern (HIGH finding above). It also introduced the six new `nonisolated(unsafe)` fields on the bridge (LOW). The audit notes promised the discipline is enforced by `SpeechAnalyzerSTT` serialization — that's true for `start → feed* → finish`, but `finalText()` runs in parallel with the unstored finish Task, so a writer-after-reader race on `collectedText` is theoretically possible if the result drain Task fires partials during finalText().

- **`ad93dac` BLOCKER-INT-1 (MCPBusGatewayAdapter):** `actor MCPBusGatewayAdapter` is correctly isolated. The `resolveBatcher: @Sendable () async -> OutboundBatcher?` pattern correctly defers OutboundBatcher resolution past capture-time. `try?` swallowing on `flushAndSend` is appropriate (failure to emit a tool-call card is non-fatal — the replay log still records it). No concerns.

- **`df6a4d2` Track C-4 (MissingT2Provider):** `AsyncThrowingStream { continuation in continuation.finish(throwing: ...) }` is correct — the continuation closure is called synchronously inside the stream init, so the throw is raised on the FIRST iteration of `for try await` rather than buffered. Verified by reading `AsyncThrowingStream.makeStream` semantics: the unfolding closure is called eagerly on creation, but `finish(throwing:)` is queued and delivered on the next consumer poll. Production callers gate on `t2Available: false` and never invoke it — but if reached, the failure is observable.

- **`ea09fd4` Track C-2 (frameStream delegate):** The `VideoSampleDelegate` lock-snapshot pattern is correct (snapshot continuations under NSLock, yield outside). Registration race is the MEDIUM finding above. `finishAllStreams()` correctly snapshots, clears, then finishes outside the lock — no lock-while-holding-stream-side semantics. Good.

- **`7a5543a` Track C-1 (PhotoCaptureProxy):** Self-retaining delegate pattern is correct: AVCapturePhotoOutput holds delegate weakly, proxy holds itself strongly until first callback, then `defer { selfRetain = nil }` breaks the cycle. Continuation guarded by `guard let cont = continuation else { return }` + `continuation = nil` ensures one-shot resume. Solid.

- **`75a10be` Track D-1 (installMemory cascade):** No new concurrency surface. Closure captures `[weak self]` and routes `applyOp` through. Fine.

- **`51750c1` Track D-3 (priorFactsLookup):** Throws degraded to empty list with log — drain task survives. No new concurrency surface.

- **`c3bd0a5` Track D-4 (RememberBrutusEndToEndTests):** `FakeStore` is an actor — serialization enforced by runtime. `BrutusProvider`'s `Task { ... cont.yield(...); cont.finish() }` inside `AsyncThrowingStream { cont in ... }` is fine because `AsyncThrowingStream`'s continuation handles concurrent access.

- **`0ad14c7`, `412caa9`, `b61ea72`, `e135093`, `6afccac`, `831bee6`, `045755d` (docs(session)):** No code.

- **`19362f6` Track C-6 (real-hardware test):** Pure test, gated by env var. Fine.

- **`eac16c9` Track C-5 (confirmSend):** Reads from `FrameAttachController` actor through await. No new surface.

- **`4159d44` Track C-3 (HUD button):** TS/JS only. Out of scope.

- **`6e249ee` Track D-5/D-6 (build scripts):** Bash skeletons. Out of scope.

- **`08125a4`, `5cd46c9`, `6f6617e` (cleanup):** No concurrency surface.

## Things that are actually good

- **`BufferBroadcaster` publish path is genuinely wait-free in steady state.** `OSAllocatedUnfairLock<[Subscription]>` is the correct Apple primitive for real-time threads with rare contention; the snapshot-then-iterate pattern keeps the lock held only for a CoW pointer-array copy, never across `RingBuffer.write`. The choice to refactor `AudioGraph.tap` to publish through this and let `WakeWordDAG.start(ring:)` keep its single-ring contract via a private "primary" subscription is exactly right — back-compat without compromising fan-out semantics.

- **`ChildSpawnGate` actually enforces both invariants** (FD_CLOEXEC sweep + minimal env) and the path-aware Debug fatalError vs Release retrofit policy is the right pragmatic line — strict enough to catch our own regressions, lenient enough to not break Xcode `⌘R` runs that inherit lldb pipes.

- **`ConfirmationBroker.response` first-write-wins guard plus explicit `do/catch` on `Task.sleep` for the timer task** is textbook correct (file note WR-03 calls out exactly the right reasoning). This is the cleanest "timer + cancel + caller wins" pattern in the repo.

- **`AudioGraphOwner` six-step teardown is single-call-site DRY**, all four `RebuildTrigger` variants flow through one `teardown(trigger:)` method, and the `inTeardown` guard on each watcher prevents the rebuild→watcher→rebuild thrash that classic AVAudioEngine code falls into.

- **`MCPBusGatewayAdapter` deferred-batcher resolution via `@Sendable () async -> OutboundBatcher?` closure** is the right answer to the install-order temporal coupling between `mcpInstallTask` (step 10) and `installAgent` (step 13). The actor isolation + late-binding combo is clean.

- **`PhotoCaptureProxy` self-retain pattern** — given AVCapturePhotoOutput's weak delegate, retaining self on init and breaking the cycle in `defer { selfRetain = nil }` on the first callback is exactly right, with the continuation nil-out preventing double-resume.

- **`MemoryExtractionOrchestrator` is correctly best-effort:** every `applyOp` failure is caught and logged; the producer's `turnEnd` path can never fail because of memory extraction. The bounded channel (capacity 32, dropOldest) ensures even runaway extraction load can't backpressure the agent loop.

- **`VoiceController` cancellation hygiene is mostly correct:** `wakeWordTask`, `orchestratorTask`, `chunkPumpTask`, `vadInterceptorTask` are all stored properties cancelled in `shutdown()` and `endSTTSession`. The unstored partials drain (HIGH finding) is the lone exception.

- **`@unchecked Sendable` is documented every place it appears**, with rationale tied to the actual serialization mechanism (lock, actor caller, single-writer phase). This is rare in Swift codebases and discipline-ahead-of-warnings.
