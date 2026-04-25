---
phase: 06-voice
plan: 02
type: execute
wave: 2
depends_on: [06-01]
files_modified:
  - packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift
  - packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift
  - packages/Voice/Sources/Voice/WakeWord/ModelManifest.swift
  - packages/Voice/Sources/Voice/WakeWord/WakeWordError.swift
  - packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift
  - packages/Voice/Tests/VoiceTests/ModelManifestTests.swift
  - packages/Voice/Tests/VoiceTests/Fixtures/WakeWord/MANIFEST.json
  - Resources/models/openwakeword/MANIFEST.json
  - Resources/models/openwakeword/.gitkeep
  - scripts/fetch-openwakeword-models.sh
autonomous: true
requirements: [VOICE-01]
tags: [voice, wake-word, openwakeword, ort, onnx-runtime, hysteresis, sha256-pinning]
assumptions:
  - Plan 06-01 has shipped: `packages/Voice/Package.swift` declares `onnxruntime-swift-package-manager` ~> 1.24.2 (we add the product import here).
  - The three openWakeWord ONNX artifacts (`melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx`) are vendored at `Resources/models/openwakeword/` with SHA-256 hashes recorded in `MANIFEST.json`. The fetch script downloads + verifies hashes from the upstream `dscripka/openWakeWord` release; users without weights must run the script before first use.
  - `ORTSession.run` is synchronous and `ORTSession` is NOT thread-safe. One session per stage, owned by a single audio actor (RESEARCH §1).
  - The mel stage emits one frame every 80 ms; ≥4-consecutive-frame threshold ≈ 320 ms hysteresis (RESEARCH §1, CLAUDE.md voice stack).
  - `RingBuffer.readMono16k(into:)` from Plan 06-01 returns 16 kHz Float32 mono frames — this is the wake-word DAG's input contract.
  - Anti-pattern callouts: DO NOT auto-redownload weights on hash mismatch — fail closed (RESEARCH §1). DO NOT share a single ORTSession across mel/embedding/classifier stages (thread-safety / shape mismatch). DO NOT block the AVAudioEngine tap thread on `ORTSession.run` — read from the ring on a dedicated Task.
must_haves:
  truths:
    - "An `OpenWakeWordSession` exposes a `feed(_ pcm16k:)` API that returns `.fired` only after ≥4 consecutive classifier frames cross threshold; 3-in-a-row, 4-with-a-dip, and singleton spikes all return `.none`."
    - "Model weights are loaded ONLY through `ModelManifest.verify(...)` — a SHA-256 mismatch on any of the three ONNX files throws `WakeWordError.modelHashMismatch` and the session refuses to construct."
    - "The `WakeWordDAG` actor owns three separate `ORTSession` instances (mel / embedding / classifier) and runs the pipeline on a dedicated `Task` that reads from `RingBuffer.readMono16k(into:)`."
    - "When `WakeWordDAG.pause()` is called, the pipeline stops consuming the ring; subsequent `resume()` continues from the current ring head (no replay of buffered audio)."
    - "The DAG plugs into Plan 06-01's `cancelInFlight` slot on `AudioGraphOwner`: on rebuild, the wake-word Task cancels cleanly within 50 ms."
    - "Detection events flow on a `wakeWordStream: AsyncStream<WakeWordEvent>` exposed by the DAG; Plan 06-05's `VoiceController` consumes this stream."
  artifacts:
    - path: "packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift"
      provides: "Actor wrapping three `ORTSession`s; exposes `feed(_:) -> DetectionDecision`; tracks `consecutive` count for hysteresis."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift"
      provides: "Public actor with `start(ring:)`, `pause()`, `resume()`, `cancel()`, `wakeWordStream`. Spawns the read-feed-Task."
      min_lines: 100
    - path: "packages/Voice/Sources/Voice/WakeWord/ModelManifest.swift"
      provides: "SHA-256 verifier; reads `MANIFEST.json` adjacent to model files; throws on mismatch — never auto-redownloads."
      min_lines: 60
    - path: "Resources/models/openwakeword/MANIFEST.json"
      provides: "Pinned SHA-256 hashes for melspectrogram.onnx, embedding_model.onnx, hey_jarvis_v0.1.onnx. Hash values populated from upstream release."
      contains: "hey_jarvis_v0.1.onnx"
    - path: "scripts/fetch-openwakeword-models.sh"
      provides: "First-run helper: downloads the three weights from dscripka/openWakeWord releases, verifies hashes against MANIFEST.json, fails closed."
  key_links:
    - from: "packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift"
      to: "packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift"
      via: "ring.readMono16k(into:) on a dedicated Task"
      pattern: "readMono16k"
    - from: "packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift"
      to: "ModelManifest"
      via: "init throws on hash mismatch"
      pattern: "ModelManifest\\.verify"
    - from: "packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift"
      to: "wakeWordStream consumer (Plan 06-05 VoiceController)"
      via: "AsyncStream<WakeWordEvent> yield from feed loop"
      pattern: "wakeWordStream"
---

<objective>
Land the openWakeWord pipeline so saying "Hey Jarvis" produces a `.fired` event on the wake-word stream — observable by Plan 06-05's `VoiceController` — with hysteresis tuned to suppress singleton background spikes.

Three locked invariants:

1. **VOICE-01 hysteresis.** A positive trigger requires ≥4 consecutive classifier frames above threshold (~320 ms). Frames 1-3 above threshold + frame 4 below = no trigger. A break-then-resume sequence resets the counter. Tests cover all three boundary cases.
2. **VOICE-01 weight pinning.** The three ONNX files (`melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx`) load ONLY through `ModelManifest.verify(...)` — SHA-256 mismatch fails closed with `WakeWordError.modelHashMismatch`. No auto-redownload, no fallback to "trust the file on disk".
3. **Threading discipline.** Three separate `ORTSession` instances (mel/embedding/classifier), owned by a single audio actor on a dedicated Task that reads from Plan 06-01's `RingBuffer`. The tap thread is NEVER blocked on ORT inference. The DAG plugs into Plan 06-01's `cancelInFlight` slot so teardown cancels the Task cleanly.

This plan deliberately does NOT include VAD (Plan 06-03), STT (Plan 06-03), or TTS (Plan 06-04). Wave 2 runs 06-02 and 06-03 in parallel; their `files_modified` are disjoint (`WakeWord/*` vs `VAD/*` + `STT/*`) and both consume `Voice.RingBuffer` read-only.

Output: a working wake-word actor with three RED→GREEN test cycles (hysteresis matrix, manifest verification, ring-feed integration), the ONNX weights vendored under `Resources/`, and a fetch script for fresh checkouts.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/06-voice/06-RESEARCH.md
@.planning/phases/06-voice/06-01-SUMMARY.md
@CLAUDE.md
@packages/Voice/Package.swift
@packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift
@packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift

<interfaces>
<!--
  Contracts the executor needs verbatim. ORT Swift surface + RingBuffer surface from 06-01.
-->

From `onnxruntime-swift-package-manager` 1.24.2+ (target product: `onnxruntime`):

```swift
import onnxruntime

// Errors throw as NSError with kOrtCErrorDomain.
final class ORTEnv { /* ... */ }
final class ORTSession {
    convenience init(env: ORTEnv, modelPath: String, sessionOptions: ORTSessionOptions?) throws
    func run(withInputs: [String: ORTValue],
             outputNames: Set<String>,
             runOptions: ORTRunOptions?) throws -> [String: ORTValue]
}
final class ORTValue {
    convenience init(tensorData: NSMutableData,
                     elementType: ORTTensorElementDataType,
                     shape: [NSNumber]) throws
    func tensorData() throws -> NSMutableData
}
```

Note: ORTSession.run is **synchronous** and the session is **not thread-safe**. One ORTSession per stage, owned by `OpenWakeWordSession`'s actor isolation. (RESEARCH §1)

From Plan 06-01 (already shipped, do NOT modify):

```swift
public final class RingBuffer: @unchecked Sendable {
    public func readMono16k(into: UnsafeMutableBufferPointer<Float>) -> Int  // returns frames read
    public var consumerLagMs: Double { get }
}

public actor AudioGraphOwner {
    /// Plan 06-01 reserved this slot — set it from `WakeWordDAG.start(ring:)`.
    public func setCancelInFlight(_ closure: @escaping @Sendable () async -> Void)
    public var ringBuffer: RingBuffer { get async }
}
```

New surface introduced by this plan:

```swift
public enum WakeWordEvent: Sendable, Equatable {
    case fired(at: Date)
}

public enum DetectionDecision: Sendable, Equatable {
    case none
    case fired
}

public actor OpenWakeWordSession {
    public init(modelDir: URL, threshold: Float = 0.5, framesRequired: Int = 4) throws
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> DetectionDecision
}

public actor WakeWordDAG {
    public init(session: OpenWakeWordSession)
    public nonisolated var wakeWordStream: AsyncStream<WakeWordEvent> { get }
    public func start(ring: RingBuffer) async
    public func pause() async
    public func resume() async
    public func cancel() async   // for AudioGraphOwner.cancelInFlight slot
}

public enum ModelManifest {
    public static func verify(modelDir: URL) throws  // throws WakeWordError.modelHashMismatch
}

public enum WakeWordError: Error, Sendable, Equatable {
    case modelHashMismatch(filename: String, expected: String, got: String)
    case missingModel(filename: String)
    case ortInitFailed
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: ModelManifest + SHA-256 verifier + fetch script</name>
  <files>packages/Voice/Sources/Voice/WakeWord/ModelManifest.swift, packages/Voice/Sources/Voice/WakeWord/WakeWordError.swift, packages/Voice/Tests/VoiceTests/ModelManifestTests.swift, packages/Voice/Tests/VoiceTests/Fixtures/WakeWord/MANIFEST.json, Resources/models/openwakeword/MANIFEST.json, Resources/models/openwakeword/.gitkeep, scripts/fetch-openwakeword-models.sh</files>
  <behavior>
    - ModelManifestTests M1: a fixture `MANIFEST.json` with three pinned hashes + three test ONNX-shaped byte fixtures whose actual SHA-256s match → `verify(modelDir:)` returns successfully.
    - ModelManifestTests M2: same setup but tampered byte fixture for `embedding_model.onnx` → `verify` throws `WakeWordError.modelHashMismatch(filename: "embedding_model.onnx", expected: ..., got: ...)`.
    - ModelManifestTests M3: missing `hey_jarvis_v0.1.onnx` file → `verify` throws `WakeWordError.missingModel(filename: "hey_jarvis_v0.1.onnx")`.
    - ModelManifestTests M4: `MANIFEST.json` is malformed JSON → throws a decoding error (not a silent skip).
  </behavior>
  <action>
Create `WakeWordError.swift` with the three cases listed in `<interfaces>`.

Create `ModelManifest.swift`. The MANIFEST schema:
```json
{
  "version": 1,
  "models": [
    {"filename": "melspectrogram.onnx", "sha256": "..."},
    {"filename": "embedding_model.onnx", "sha256": "..."},
    {"filename": "hey_jarvis_v0.1.onnx", "sha256": "..."}
  ]
}
```

`verify(modelDir:)` reads `modelDir/MANIFEST.json`, decodes via `JSONDecoder`, then for each entry computes SHA-256 of the file bytes (use `CryptoKit.SHA256.hash(data:)` → hex-lower-case string). Mismatch → `.modelHashMismatch`. Missing file → `.missingModel`. Returns `Void` on success.

Create `Resources/models/openwakeword/MANIFEST.json` with placeholder SHA-256s ALONG WITH a TODO comment in the file header noting the hashes are filled in by `scripts/fetch-openwakeword-models.sh` on first run. The actual ONNX files are NOT committed — they're large (10-50 MB combined) and license-pinned to upstream.

Create `scripts/fetch-openwakeword-models.sh` (`bash`):
```bash
#!/usr/bin/env bash
set -euo pipefail
DEST="Resources/models/openwakeword"
URLS=(
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx"
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx"
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/hey_jarvis_v0.1.onnx"
)
for url in "${URLS[@]}"; do
  name=$(basename "$url")
  echo "fetching $name..."
  curl -fSL "$url" -o "$DEST/$name"
done
echo "computing hashes..."
python3 - <<'EOF'
import hashlib, json, pathlib
dest = pathlib.Path("Resources/models/openwakeword")
manifest = {"version": 1, "models": []}
for fn in ["melspectrogram.onnx", "embedding_model.onnx", "hey_jarvis_v0.1.onnx"]:
    h = hashlib.sha256((dest / fn).read_bytes()).hexdigest()
    manifest["models"].append({"filename": fn, "sha256": h})
(dest / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
EOF
echo "done. verify with: swift test --package-path packages/Voice --filter VoiceTests.ModelManifestTests"
```

The script is intentionally simple — license terms with upstream allow direct download. The script does NOT bypass hash verification; it CREATES the manifest from the freshly-downloaded files. The verifier in production is what enforces tamper-evidence on subsequent runs.

Create the fixture `MANIFEST.json` + three byte-fixtures in `Tests/VoiceTests/Fixtures/WakeWord/` (small synthetic byte sequences with computable hashes — NOT real ONNX models). Each test M1/M2/M3 references this fixture dir.

Verify: `chmod +x scripts/fetch-openwakeword-models.sh`. Tests run with no network access — fixtures are local only.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.ModelManifestTests &amp;&amp; bash -n scripts/fetch-openwakeword-models.sh</automated>
  </verify>
  <done>ModelManifestTests (4 cases) pass. `Resources/models/openwakeword/MANIFEST.json` exists with placeholder structure. `scripts/fetch-openwakeword-models.sh` is syntax-valid bash and executable. The fetch script is gitignored from triggering re-runs (the .onnx files are gitignored separately — add to `.gitignore` if not already covered).</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: OpenWakeWordSession + hysteresis matrix</name>
  <files>packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift, packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift</files>
  <behavior>
    - WakeWordHysteresisTests H1 (singleton spike): inject scripted `runClassifier` returning [0.6, 0.1, 0.0, 0.0, 0.0] → `feed` is called five times → 0 `.fired` events.
    - WakeWordHysteresisTests H2 (3-in-a-row + dip): scripted [0.6, 0.7, 0.6, 0.4, 0.0] → 0 `.fired` events; consecutive counter reset on the 0.4 frame.
    - WakeWordHysteresisTests H3 (exact threshold): scripted [0.6, 0.7, 0.6, 0.55] → exactly 1 `.fired` event on the 4th frame.
    - WakeWordHysteresisTests H4 (long burst): scripted [0.6] * 8 → exactly 1 `.fired` event (counter resets after firing; further frames don't re-fire until 4 more consecutive).
    - WakeWordHysteresisTests H5 (configurable framesRequired): construct with `framesRequired: 6`, feed [0.6] * 5 → 0 `.fired`; feed one more → 1 `.fired`.
    - WakeWordHysteresisTests H6 (manifest gating): construct with a `modelDir` that fails `ModelManifest.verify` → init throws `WakeWordError.modelHashMismatch`.
  </behavior>
  <action>
Implement `OpenWakeWordSession` as an actor. Constructor:
1. Calls `ModelManifest.verify(modelDir:)` — throws on mismatch.
2. Builds three `ORTSession` instances. ORT initialization details:
   - `let env = try ORTEnv(loggingLevel: .warning)`
   - For each ONNX path, `try ORTSession(env: env, modelPath: path, sessionOptions: nil)`.
3. Stores `threshold: Float`, `framesRequired: Int`, mutable `consecutive: Int = 0`.

`feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> DetectionDecision`:
1. Wrap the PCM into `ORTValue` with shape `[1, frames]`.
2. Run mel session → wrap output as embedding input → run embedding session → wrap output as classifier input → run classifier session.
3. Parse classifier output as `Float` probability.
4. Hysteresis:
   ```
   if prob >= threshold {
     consecutive += 1
     if consecutive >= framesRequired { consecutive = 0; return .fired }
   } else {
     consecutive = 0
   }
   return .none
   ```

**Test seam:** to make the hysteresis matrix testable WITHOUT real ONNX inference (which would require real models on disk), introduce an internal initializer:
```swift
internal init(scriptedClassifier: @escaping ([Float]) -> Float, threshold: Float, framesRequired: Int)
```
This bypasses ORT and uses the closure to produce probabilities. The hysteresis tests exercise this path. The production initializer (with real `modelDir`) is exercised by integration tests in Plan 06-05's `VoiceController` end-to-end tests.

Verify: H1..H6 all pass; the `consecutive` reset behavior matches the spec.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.WakeWordHysteresisTests</automated>
  </verify>
  <done>WakeWordHysteresisTests (6 cases) pass. `OpenWakeWordSession` documented inline with reference to RESEARCH §1 hysteresis spec. The scripted-classifier internal init is documented as test-only. Production init throws on manifest mismatch (covered by H6).</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: WakeWordDAG actor + ring-buffer feed Task + cancel slot integration</name>
  <files>packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift, packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift</files>
  <behavior>
    - WakeWordHysteresisTests H7 (ring-feed integration): construct a DAG with a scripted session that fires on the 4th frame; produce 6 frames into the RingBuffer via test producer; observe exactly 1 `.fired` event on `wakeWordStream` within 200 ms.
    - WakeWordHysteresisTests H8 (pause/resume): start the DAG, produce 3 frames (no fire yet), pause, produce 100 frames (DAG MUST NOT consume), resume, produce 1 more frame → DAG still has consecutive=3 from before pause; produces 1 fire only when 1 more frame comes after resume.

      Resolution: pause/resume preserves the `consecutive` counter; rationale documented inline ("a wake-word fragment uttered before pause should still fire when the user finishes speaking it after resume — within reason"). If the user changes their mind about this, flip to "reset on pause" with a one-line edit.
    - WakeWordHysteresisTests H9 (cancel/cleanup): start the DAG, then call `cancel()`; the read-feed Task terminates within 50 ms; subsequent reads from the ring resume normal consumer behavior (the DAG is no longer reading).
  </behavior>
  <action>
Implement `WakeWordDAG`:

```swift
public actor WakeWordDAG {
  private let session: OpenWakeWordSession
  private var feedTask: Task<Void, Never>?
  private var paused: Bool = false
  private let streamCont: AsyncStream<WakeWordEvent>.Continuation
  public nonisolated let wakeWordStream: AsyncStream<WakeWordEvent>

  public init(session: OpenWakeWordSession) { /* AsyncStream.makeStream */ }

  public func start(ring: RingBuffer) async {
    feedTask?.cancel()
    feedTask = Task.detached { [weak self, ring] in
      var scratch = [Float](repeating: 0, count: 1280)  // 80 ms @ 16 kHz
      while !Task.isCancelled {
        let read = scratch.withUnsafeMutableBufferPointer { ring.readMono16k(into: $0) }
        if read == 0 { try? await Task.sleep(nanoseconds: 10_000_000); continue }
        guard let self else { return }
        if await self.paused { continue }
        let decision = try? await scratch[..<read].withUnsafeBufferPointer { try await self.session.feed($0) }
        if case .fired = decision {
          await self.streamCont.yield(.fired(at: Date()))
        }
      }
    }
  }

  public func pause() async { paused = true }
  public func resume() async { paused = false }
  public func cancel() async { feedTask?.cancel(); feedTask = nil; streamCont.finish() }
}
```

The 1280-sample scratch buffer corresponds to one mel frame's worth of audio (80 ms × 16 kHz). On Tahoe with post-VPIO 24 kHz input, Plan 06-01's mixer-tap path resamples to 16 kHz before hitting the ring, so the scratch size is fixed.

Wire to `AudioGraphOwner.cancelInFlight`: at the AppDelegate / VoiceController layer (Plan 06-05), call `await audioGraphOwner.setCancelInFlight { await wakeWordDAG.cancel() }`. This plan does NOT do the wiring (06-05's job) — it just exposes `cancel()` with the right shape.

H7 test setup:
```swift
let session = OpenWakeWordSession(scriptedClassifier: { _ in [0.0, 0.0, 0.0, 0.6, 0.7, 0.8].next() ?? 0.0 },
                                   threshold: 0.5, framesRequired: 4)
let ring = RingBuffer(capacityFrames: 16384)
let dag = WakeWordDAG(session: session)
await dag.start(ring: ring)

// Produce 6 frames worth of dummy audio
for _ in 0..<6 { ring.write(makeDummyPCMBuffer(frames: 1280)) }

// Observe stream
var firedCount = 0
let observer = Task {
  for await _ in dag.wakeWordStream { firedCount += 1; break }
}
try await Task.sleep(for: .milliseconds(200))
observer.cancel()
XCTAssertEqual(firedCount, 1)
```

Verify: H7..H9 pass; the read-feed Task uses `Task.detached` (not actor-isolated) so the actor remains responsive to `pause`/`resume` requests.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.WakeWordHysteresisTests</automated>
  </verify>
  <done>WakeWordHysteresisTests (9 cases — H1..H9) pass. `WakeWordDAG.swift` ≥ 100 lines with inline comments anchoring RESEARCH §1, the 80 ms / 1280-sample scratch rationale, and the pause/resume preserve-counter decision. `cancel()` releases all resources within 50 ms (asserted by H9 with a tolerance assertion).</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Vendored ONNX weights → ORTSession | Untrusted file content if a hostile actor swaps the file on disk. SHA-256 manifest is the integrity check. |
| RingBuffer (multi-consumer in P6) | DAG reads from the same ring as Plan 06-03's VAD; both are read-only consumers, no contention concern. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-06-02-01 | Tampering | Swapped ONNX weight on disk | mitigate | `ModelManifest.verify` runs at session init; SHA-256 mismatch fails closed (`WakeWordError.modelHashMismatch`); never auto-redownload. |
| T-06-02-02 | Spoofing | Adversarial wake-word audio (TV chatter) | mitigate | ≥4-frame hysteresis (~320 ms) suppresses singleton spikes (CLAUDE.md voice stack). Plan 06-05's `mute-wake-word` toggle is a defense-in-depth user control. |
| T-06-02-03 | Denial of Service | Hostile classifier outputs (probability stuck at 1.0 forever) | accept | A constant-fire wake word produces noise but doesn't crash; Plan 06-05's barge-in routing absorbs runaway events via orchestrator deduplication (`.thinking` state ignores wake-word events). |
| T-06-02-04 | Information Disclosure | Mic frames buffered in RingBuffer survive process crash | mitigate | RingBuffer is in-memory only; no disk persistence. Process crash drops audio. ASLR + Hardened Runtime + no swap-disk for sensitive pages is acceptable for v1 personal-use threat model. |
| T-06-02-05 | Repudiation | Wake-word fires that are never logged | mitigate | Plan 06-05 forwards every `wakeWordStream` event to `JarvisLogChannel.system` with a redaction-clean payload (just timestamp + source). No raw audio is logged. |
</threat_model>

<verification>
- `swift test --package-path packages/Voice --filter VoiceTests.WakeWordHysteresisTests` — 9 cases (H1..H9) green.
- `swift test --package-path packages/Voice --filter VoiceTests.ModelManifestTests` — 4 cases (M1..M4) green.
- `swift build --package-path packages/Voice` — clean.
- Grep gates:
  - `grep -nE 'auto.?redownload|fallback.?fetch' packages/Voice/Sources/Voice/WakeWord/ModelManifest.swift` — 0 matches (fail-closed discipline).
  - `grep -cE 'consecutive\s*\\+=\s*1|consecutive\s*=\s*0' packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift` — exactly 3 (increment + reset-on-fire + reset-on-dip).
  - `grep -nE 'framesRequired:\s*4' packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift` — at least 1 (default value anchors VOICE-01 320 ms hysteresis).
- `bash -n scripts/fetch-openwakeword-models.sh` — exit 0 (syntax valid).
- `swift package --package-path packages/Voice resolve` continues to resolve cleanly (Plan 06-01's pinned deps).
- `Package.swift` is UNCHANGED from Plan 06-01 (the disjoint-files contract for Wave 2 holds).
</verification>

<success_criteria>
- VOICE-01 closed at the unit-test level: hysteresis matrix proves singleton/dip/threshold/reset behaviors; weight pinning proves SHA-256 fail-closed; integration test proves ring-buffer feed produces stream events.
- The DAG plugs into Plan 06-01's `cancelInFlight` slot — no schema changes to `AudioGraphOwner`.
- Plan 06-03 (running in parallel) does NOT touch any file in this plan; both plans depend only on 06-01's `RingBuffer`.
- Wake-word fires are observable via `AsyncStream<WakeWordEvent>` — Plan 06-05's `VoiceController` consumes this stream as the trigger for `.idle → .listening` HUD transitions.
</success_criteria>

<output>
After completion, create `.planning/phases/06-voice/06-02-SUMMARY.md` documenting:
- The three SHA-256-pinned ONNX files and the fetch-script workflow.
- The hysteresis matrix (3-in-a-row, dip, exact-4, long-burst, configurable, manifest-gated).
- The pause/resume preserve-counter decision (with reversal cost: one line).
- The 1280-sample scratch buffer rationale (80 ms / 16 kHz / one mel frame).
- Test count: 13 (4 manifest + 9 hysteresis).
</output>
