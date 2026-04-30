---
phase: 08-hardening
plan: 03
type: execute
wave: 2
depends_on: [01]
files_modified:
  - packages/Harness/Sources/Harness/FDLeakDetector.swift
  - packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift
  - packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift
  - packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift
  - packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift
  - packages/Harness/Sources/Harness/CapturingURLProtocol.swift
  - packages/Harness/Sources/jarvis-eval/main.swift
  - packages/Harness/Tests/HarnessTests/FDLeakDetectorTests.swift
  - packages/Harness/Tests/HarnessTests/MCPCrashRunnerTests.swift
  - packages/Harness/Tests/HarnessTests/AudioGraphRebuildRunnerTests.swift
  - packages/Harness/Tests/HarnessTests/ToolCapRecoveryRunnerTests.swift
  - .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md
autonomous: true
requirements: [OBS-04]
must_haves:
  truths:
    - "FDLeakDetector wraps lsof -p <pid> -F ftn and returns FDSnapshot for delta comparison"
    - "MCPCrashRunner runs at least 50 helper crashes (or 100 if per-crash time <= 200ms) with FDLeakDetector delta = 0 against a steady-state whitelist per D-19"
    - "MCPCrashRunner profiles per-crash cycle time before deciding 50 vs 100 per D-19"
    - "AudioGraphRebuildRunner exercises 4 canonical triggers (device change, AEC fallback, mic re-grant, sustained ring overflow) each with the 6-step teardown in order"
    - "Audio-graph device-change trigger downgrades to MANUAL: checklist item with operator instructions if AVAudioEngine synthetic device-change injection unavailable per D-14"
    - "ToolCapRecoveryRunner asserts BOTH zero .toolUseRequested events AND outbound HTTP request body confirms tool_choice: {type: none} (Anthropic) / no tools array (Ollama) per D-21"
    - "LiveOllamaRunner preflights with curl http://127.0.0.1:11434/api/tags; fails loud if unreachable or qwen2.5-coder:32b missing; never auto-pulls per D-06"
    - "Live mode dual-gated: --live flag AND JARVIS_LIVE_EVAL=1 env var required per D-04"
    - "Xcode 26 ad-hoc Debug bundle launch fragility resolved or documented as MANUAL per D-12 / D-13"
    - "jarvis-eval CLI exposes cap-recovery, mcp-crash, audio-rebuild subcommands; corpus-ndjson --live extended"
  artifacts:
    - path: "packages/Harness/Sources/Harness/FDLeakDetector.swift"
      provides: "lsof-based FD enumeration + snapshot/delta API"
      exports: ["FDLeakDetector", "FDSnapshot"]
    - path: "packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift"
      provides: "100-cycle (or 50) helper crash injection with FD-leak detection"
      exports: ["MCPCrashRunner", "CrashReport"]
    - path: "packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift"
      provides: "4-trigger × 6-step canonical teardown matrix"
      exports: ["AudioGraphRebuildRunner", "RebuildReport"]
    - path: "packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift"
      provides: "R4-L1 regression: zero tool-use events + outbound body inspection"
      exports: ["ToolCapRecoveryRunner", "CapRecoveryReport"]
    - path: "packages/Harness/Sources/Harness/CapturingURLProtocol.swift"
      provides: "URLProtocol subclass capturing httpBody + canned SSE response for ToolCapRecoveryRunner"
      exports: ["CapturingURLProtocol"]
    - path: "packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift"
      provides: "Ollama daemon preflight + live qwen2.5-coder:32b eval; never auto-pulls"
      exports: ["LiveOllamaRunner"]
    - path: ".planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md"
      provides: "Resolution log or MANUAL operator instructions for Xcode 26 launch fragility per D-12"
      contains: "SWIFT_ENABLE_DEBUG_DYLIB"
  key_links:
    - from: "packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift"
      to: "packages/MCP/Tests/MCPTests/MCPRestartTests.swift (analog 100-cycle loop)"
      via: "extracts MockHelper builder + countOpenFDs() into Harness module"
      pattern: "MockHelperBuilder|MOCK_HELPER_CRASH_AFTER"
    - from: "packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift"
      to: "packages/Voice/Tests/VoiceTests/TeardownTests.swift (4-trigger matrix)"
      via: "wraps existing test methods as runner scenarios"
      pattern: "deviceChange|aecFallback|micReGrant|sustainedRingOverflow"
    - from: "packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift"
      to: "packages/AgentCore (LLMProvider.stream + RequestBody serialization)"
      via: "URLProtocol mock captures outbound bytes"
      pattern: "URLProtocol.registerClass"
    - from: "packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift"
      to: "http://127.0.0.1:11434/api/tags (preflight) + /api/chat (eval)"
      via: "URLSession against localhost-only Ollama daemon"
      pattern: "127\\.0\\.0\\.1:11434"
---

<phase_goal>
Phase 8 Plan 03 builds the integration + live-mode runners that exercise pieces of the
production stack the offline corpora cannot: real MCP helper crashes (FD-leak detection
under sustained restart), real audio-graph rebuilds (4-trigger × 6-step teardown matrix),
tool-cap recovery with outbound-body inspection (R4-L1 regression), and opt-in live Ollama
evaluation against `qwen2.5-coder:32b`. Implements OBS-04 pillars (c-live), (d), (f), (g).
This plan also inherits the P6 deferred debt per D-12 / D-13: Xcode 26 ad-hoc Debug bundle
launch fragility is resolved (or definitively documented as MANUAL) as a Wave-1 prerequisite
inside this plan, since pillar (g) audio-graph rebuild and the manual Orpheus TTFA gate both
transitively depend on launch resolution. Plan runs in parallel with 08-02 (Wave 2;
disjoint files_modified — corpus paths vs runner+integration paths).
</phase_goal>

<truths>
This plan executes against these LOCKED context decisions (08-CONTEXT.md):

- **D-04:** Fixture is the shipping gate; live is opt-in. `--live` flag AND `JARVIS_LIVE_EVAL=1` env var both required.
- **D-06:** Live Ollama preflights with `curl http://127.0.0.1:11434/api/tags`; fails loud with operator instructions on missing daemon or missing `qwen2.5-coder:32b` model. Never auto-pulls.
- **D-12 / D-13:** P8 inherits 3 deferred items from STATE.md "Phase 6 → Phase 8 Deferred Items":
  1. Resolve Xcode 26 ad-hoc Debug bundle launch fragility (`SWIFT_ENABLE_DEBUG_DYLIB=NO` ignored; Info.plist marker reverted post-build; codesign --verify reports invalid Info.plist after BUILD SUCCEEDED).
  2. Drive Plan 06-05's six UAT gates (VOICE-07/09/12/13/14) on a Release-signed Developer ID archive — surface as `MANUAL:` checklist items in `.planning/phases/06-voice/checklist.yaml` (sweep-authored in plan 08-04, NOT here).
  3. Empirical Orpheus TTFA measurement (target 150–250 ms); flip `features.tts.tier2 = "ttskit"` if > 250 ms — surface as MANUAL in 08-04 sweep.
- **D-14:** Audio-graph rebuild pillar (g) graceful degradation: probe `AVAudioEngine` synthetic device-change injection API early in this plan; if missing, device-change trigger downgrades to a `MANUAL:` checklist item with explicit operator instructions ("plug in / unplug USB-C audio interface mid-utterance"). The other 3 triggers stay automated. **No degradation is silent.**
- **D-19:** MCP crash-recovery profiles per-crash cycle time first. If <= 200 ms/crash, run 100 crashes as ROADMAP specifies. If > 200 ms/crash, reduce to 50 crashes (still enough to detect linear FD leaks) with `--extended` flag for 500. Any reduction below 100 documented in REQUIREMENTS.md OBS-04 commentary.
- **D-21:** Tool-cap recovery test asserts BOTH (a) zero `.toolUseRequested` events on the recovery turn AND (b) outbound HTTP request body bytes captured by a URL-protocol mock confirm `tool_choice: {"type": "none"}` (Anthropic) / no `tools` key (Ollama). Event-count assertion alone is necessary-but-not-sufficient (researcher Pitfall 5).

This plan depends on 08-01 (Wave 1) for: `packages/Harness` SPM substrate, `MockLLMProvider`, `jarvis-eval` CLI shell.

This plan does NOT depend on 08-02 (sibling Wave 2 plan) — runs parallel with disjoint files_modified.
</truths>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/REQUIREMENTS.md
@.planning/phases/08-hardening/08-CONTEXT.md
@.planning/phases/08-hardening/08-RESEARCH.md
@.planning/phases/08-hardening/08-PATTERNS.md
@.planning/phases/08-hardening/08-VALIDATION.md
@.planning/phases/06-voice/06-HUMAN-UAT.md
@.planning/phases/08-hardening/08-01-replay-oracle-PLAN.md
@CLAUDE.md
@packages/MCP/Tests/MCPTests/MCPRestartTests.swift
@packages/MCP/Tests/MCPTests/MCPServerHandleInitFailureFDLeakTests.swift
@packages/Voice/Tests/VoiceTests/TeardownTests.swift
@packages/AgentCore/Tests/AgentOrchestratorTests
@packages/AgentCore/Sources/AgentCore/ToolChoice.swift
@packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift

<interfaces>
From PATTERNS.md §2.9 — FDLeakDetector:

    public struct FDSnapshot: Equatable, Sendable {
        public let pid: Int32
        public let fds: Set<String>  // normalized "fd=7 path=/tmp/jarvis-replay.sqlite" entries
    }

    public enum FDLeakDetector {
        public static func snapshot(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> FDSnapshot
        public static func delta(from before: FDSnapshot, to after: FDSnapshot)
            -> (added: Set<String>, removed: Set<String>)
    }

From PATTERNS.md §2.8 — CapturingURLProtocol (Pitfall 5):

    final class CapturingURLProtocol: URLProtocol {
        static var capturedBodies: [Data] = []
        static var cannedResponse: Data = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let body = request.httpBody { Self.capturedBodies.append(body) }
            // Also handle httpBodyStream (Anthropic uses streaming uploads in some shapes)
            // ...
        }
        override func stopLoading() {}
    }

From PATTERNS.md §2.6 — AudioGraphRebuildRunner orchestration shape:

    public actor AudioGraphRebuildRunner {
        public enum Trigger: String, Sendable, CaseIterable {
            case deviceChange       // D-14 may downgrade to MANUAL
            case aecFallback
            case micReGrant
            case sustainedRingOverflow
        }
        public struct RebuildReport: Sendable {
            public let trigger: Trigger
            public let teardownStepsObserved: [String]  // canonical 6-step
            public let rebuildSucceeded: Bool
            public let degradedToManual: Bool
        }
        public func run() async throws -> [RebuildReport]
    }

From PATTERNS.md §2.5 — MCPCrashRunner shape (extends MCPRestartTests' 100-cycle pattern):

    public actor MCPCrashRunner {
        public struct CrashReport: Sendable {
            public let crashCount: Int
            public let perCrashCycleTimeMs: [Double]
            public let fdDelta: (added: Set<String>, removed: Set<String>)
            public let passed: Bool
        }
        public func run(targetCrashes: Int = 100, extended: Bool = false) async throws -> CrashReport
    }
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Resolve Xcode 26 launch fragility (D-12 prerequisite) + AVAudioEngine device-change injection probe (D-14)</name>

  <read_first>
    - .planning/phases/06-voice/06-HUMAN-UAT.md (Deferral Note section)
    - .planning/STATE.md "Phase 6 → Phase 8 Deferred Items" section
    - project.yml (find target build settings — search for SWIFT_ENABLE_DEBUG_DYLIB)
    - App/Info.plist (current Info.plist marker management)
    - scripts/codesign.sh (or whatever the codesign script is — find via `ls scripts/*codesign*` or `grep -rn codesign scripts/`)
    - scripts/verify-codesign-settings.sh
    - .planning/phases/01-foundations/ for relevant codesign / pbxproj-linter scripts
    - Apple developer documentation on AVAudioEngine route-change injection (search for `AVAudioSession.routeChangeNotification` in Apple docs and any existing Swift sample)
  </read_first>

  <files>
    .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md,
    project.yml (if a build-settings change resolves the issue),
    scripts/codesign.sh (if the script needs a fix),
    scripts/verify-codesign-settings.sh (if a new check is added)
  </files>

  <action>
1. **Investigate Xcode 26 launch fragility** (D-12 deferred item #1). Run a Release-Debug archive build:

    xcodebuild -scheme Jarvis -configuration Debug clean build 2>&1 | tee /tmp/jarvis-debug-build.log

   Then inspect:

    codesign --verify --deep --strict --verbose=4 build/Debug/Jarvis.app 2>&1 | tee /tmp/jarvis-codesign-verify.log

   Diagnose the root cause based on the symptoms in STATE.md:
   - `SWIFT_ENABLE_DEBUG_DYLIB=NO` set in xcconfig but ignored at build time → check if the build setting is on the wrong target / configuration; ensure it's on every target including helper bundles.
   - Info.plist marker reverted post-build → identify which post-build phase rewrites Info.plist; verify-entitlements.sh writes `JarvisEntitlementsVerified=YES` and per Phase 1 deviation it must run PRE-codesign — check the build phase ordering.
   - `codesign --verify` reports `invalid Info.plist (plist or signature have been modified)` → confirms the codesign-then-Info.plist-mutation race. Possible fix: ensure the entitlement-verification script writes to a sidecar file, NOT Info.plist, and the codesign phase consumes the verification result via build-phase dependency rather than via Info.plist marker.

   Apply the fix narrowly. If the fix is non-obvious or requires a substantial Xcode-config refactor, fall back to plan B: document the workaround as `MANUAL:` operator instructions and surface it via 08-04 sweep into a checklist item.

2. **Document outcome** in `.planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md`:
   - Root cause (one paragraph, citing symptom -> diagnostic -> fix-or-acceptance)
   - Resolution: either "RESOLVED — see commit X" with diff hash, OR "ACCEPTED AS MANUAL — see operator instructions below"
   - If MANUAL: provide step-by-step operator instructions for cold-launching the Debug ad-hoc bundle. Include workaround commands (e.g., `codesign --remove-signature build/Debug/Jarvis.app && codesign -s - build/Debug/Jarvis.app`).
   - Cross-reference: this resolution unblocks the P6 HUMAN-UAT gates (driven manually after this lands) AND the empirical Orpheus TTFA measurement (also manually). Both surface as `MANUAL:` items in `.planning/phases/06-voice/checklist.yaml` during plan 08-04's sweep — NOT here.

3. **Probe AVAudioEngine synthetic device-change injection API** (D-14). Apple docs reference: `AVAudioSession.routeChangeNotification` is consumer-side; the question is whether the test harness can POST one synthetically. Approaches to try, in order:

    a. `NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), userInfo: [...])` — try synthesizing the notification with the canonical userInfo keys (`AVAudioSessionRouteChangeReasonKey`, `AVAudioSessionRouteChangePreviousRouteKey`).

    b. AVAudioEngine `notify(_ notification:)` private API — search the Apple-private headers; if not exposed via Foundation, this approach is unavailable.

    c. `_AVAudioSession.simulateRouteChange()` — undocumented method; check if available via Objective-C runtime.

   Run the probe in a small Swift script:

    cat > /tmp/probe-route-change.swift << 'SWIFT'
    import AVFoundation
    let exp = expectation(...)
    NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
        exp.fulfill()
    }
    NotificationCenter.default.post(
        name: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        ]
    )
    SWIFT

   If posting the notification synchronously triggers our `AudioGraphOwner.handleRouteChange(...)` consumer: **available**. If it requires a real hardware event: **degrade** the device-change trigger to MANUAL per D-14.

   Document the probe outcome in `08-LAUNCH-FRAGILITY-NOTES.md` (same file, separate section "AVAudioEngine Route-Change Injection Probe"):
   - Available → record the posting recipe; AudioGraphRebuildRunner uses it directly in Task 3.
   - Unavailable → record the operator instructions for the MANUAL fallback ("plug in / unplug USB-C audio interface mid-utterance during a `.speaking` turn"); AudioGraphRebuildRunner emits `degradedToManual: true` for the deviceChange trigger.
  </action>

  <acceptance_criteria>
    - File `.planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md` exists and is non-empty
    - File contains either "RESOLUTION: RESOLVED" or "RESOLUTION: ACCEPTED AS MANUAL" (substring): `grep -cE "RESOLUTION:\s*(RESOLVED|ACCEPTED AS MANUAL)" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md` returns 1
    - File contains a section titled `AVAudioEngine Route-Change Injection Probe`: `grep -c "AVAudioEngine Route-Change Injection Probe" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md` returns 1
    - Probe outcome documented as either "available" (with recipe) or "unavailable" (with MANUAL operator instructions): `grep -cE "available|unavailable" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md` returns at least 1
    - If RESOLVED via build setting: `xcodebuild -scheme Jarvis -configuration Debug build` exits 0 AND `codesign --verify build/Debug/Jarvis.app` exits 0 (no `invalid Info.plist` error)
    - If ACCEPTED AS MANUAL: the file contains `MANUAL:` operator instructions section with explicit shell commands or steps
  </acceptance_criteria>

  <verify>
    <automated>test -s .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md && grep -qE "RESOLUTION:\s*(RESOLVED|ACCEPTED AS MANUAL)" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md</automated>
  </verify>

  <done>Xcode 26 launch fragility is either resolved (with verifiable build+codesign success) or definitively documented as MANUAL with operator instructions. AVAudioEngine route-change injection probe outcome is recorded with either an available recipe or a MANUAL fallback. Both feed downstream: Task 3 of this plan uses the probe outcome; plan 08-04's sweep folds the MANUAL items (if any) into 06-voice/checklist.yaml.</done>
</task>

<task type="auto">
  <name>Task 2: FDLeakDetector + MCPCrashRunner with D-19 cycle-time profiling + mcp-crash subcommand</name>

  <read_first>
    - packages/MCP/Tests/MCPTests/MCPRestartTests.swift (full file; the 100-cycle crash loop + countOpenFDs() pattern per PATTERNS.md §2.5)
    - packages/MCP/Tests/MCPTests/MCPServerHandleInitFailureFDLeakTests.swift (analog FD-assertion test)
    - packages/MCP/Tests/MCPTests/MockHelperBuilder.swift (or wherever the MockHelper builder lives — find via grep)
    - packages/MCP/Sources/MCP/MCPClient.swift (find restart mutex, register, callTool methods)
    - packages/MCP/Sources/MCP/ChildSpawnGate.swift (FD_CLOEXEC enforcement seam)
    - packages/MCP/Sources/MCP/MCPServerHandle.swift lines 86-117 (Process + Pipe spawn analog for FDLeakDetector)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.9 (FDLeakDetector hybrid pattern)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.5 (MCPCrashRunner extension)
    - .planning/phases/08-hardening/08-RESEARCH.md §FD-Leak Detector lines 553-578
    - .planning/phases/08-hardening/08-RESEARCH.md §Pitfall 6 lines 441-449
    - .planning/phases/08-hardening/08-CONTEXT.md D-19
  </read_first>

  <files>
    packages/Harness/Sources/Harness/FDLeakDetector.swift,
    packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift,
    packages/Harness/Sources/jarvis-eval/main.swift,
    packages/Harness/Tests/HarnessTests/FDLeakDetectorTests.swift,
    packages/Harness/Tests/HarnessTests/MCPCrashRunnerTests.swift
  </files>

  <action>
1. Create `packages/Harness/Sources/Harness/FDLeakDetector.swift` per PATTERNS.md §2.9. Hybrid pattern: Process spawn template from MCPServerHandle.swift + lsof -F ftn parsing.

    import Foundation

    public struct FDSnapshot: Equatable, Sendable, Codable {
        public let pid: Int32
        public let fds: Set<String>  // each entry: "fd=<N> type=<TYPE> path=<PATH>"
    }

    public enum FDLeakDetector {
        public enum Error: Swift.Error {
            case lsofFailed(exitCode: Int32, stderr: String)
            case parseFailure(line: String)
        }

        public static func snapshot(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> FDSnapshot {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-p", "\(pid)", "-F", "ftn"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // S-2: route through ChildSpawnGate.shared.prepare() if available; lsof
            // is short-lived enough that minimal env (PATH=/usr/bin:/bin) suffices.
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw Error.lsofFailed(exitCode: process.terminationStatus, stderr: stderr)
            }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return FDSnapshot(pid: pid, fds: try parseLsofTerse(data))
        }

        public static func delta(from before: FDSnapshot, to after: FDSnapshot)
            -> (added: Set<String>, removed: Set<String>) {
            (added: after.fds.subtracting(before.fds), removed: before.fds.subtracting(after.fds))
        }

        /// Parse lsof -F ftn terse output. Each FD block:
        ///   p<pid>
        ///   f<fd>
        ///   t<type>
        ///   n<name>
        /// Defends against non-UTF8 path bytes (replaces invalid sequences with U+FFFD).
        internal static func parseLsofTerse(_ data: Data) throws -> Set<String> {
            // ... per-FD record assembly; combine f/t/n into a single "fd=<N> type=<T> path=<P>" string ...
            // Use String(decoding: lossy) to defend against non-printable bytes per RESEARCH §FD-Leak Detector
        }
    }

2. Create `packages/Harness/Tests/HarnessTests/FDLeakDetectorTests.swift` covering:
   - Happy path: snapshot of self returns a non-empty set; subsequent snapshot has bounded delta.
   - Open a known FD (`open(...)` a temp file); snapshot before/after; assert added contains a `path=` entry pointing at the temp file.
   - Close the FD; snapshot after; assert removed contains the same entry.
   - Malformed lsof output: feed `parseLsofTerse(data:)` 5 fixture byte arrays covering: happy path, FIFO (`tFIFO`), socket (no `n` line), non-UTF-8 path bytes, empty data. None throw; all return a Set.
   - lsof not found: temporarily symlink lsof to a non-existent path or use a build-flag-gated test that simulates `Error.lsofFailed`.

3. Create `packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` per PATTERNS.md §2.5. CRITICAL D-19 detail: profile per-crash cycle time on the FIRST crash (or first 5 for averaging), then decide whether to run 100 vs 50:

    import Foundation
    import MCP

    public actor MCPCrashRunner {
        public struct CrashReport: Sendable, Codable {
            public let crashCount: Int
            public let perCrashCycleTimeMs: [Double]
            public let medianCycleTimeMs: Double
            public let fdSnapshotBaseline: FDSnapshot
            public let fdSnapshotFinal: FDSnapshot
            public let fdAddedSinceBaseline: Set<String>
            public let fdRemovedSinceBaseline: Set<String>
            public let steadyStateWhitelistMatched: Bool
            public var passed: Bool {
                fdAddedSinceBaseline.isEmpty || steadyStateWhitelistMatched
            }
        }

        /// Steady-state FD whitelist per RESEARCH §Pitfall 6 + D-20:
        /// FDs that EXIST after MCPClient init and are NOT considered leaks.
        /// (Replay-log SQLite WAL FD, SQLite journal FD, three pipes per registered helper after CR-01 cleanup, stderr handler.)
        public static let steadyStateWhitelist: Set<String> = [
            // Pattern-match path: regex via the matcher in `applyWhitelist`
            // Initial seed:
            "path=/tmp/jarvis-replay-",
            "path=*-wal",
            "path=*-shm",
            "type=PIPE",
        ]

        public func run(targetCrashes: Int = 100, extended: Bool = false) async throws -> CrashReport {
            // 1. Build MockHelper using existing MockHelperBuilder from MCP test target
            let helper = try MockHelperBuilder.build()
            let client = MCPClient()
            try await client.register(
                name: "mock-helper", binaryURL: helper,
                requiresConfirmation: false,
                extraEnvironment: ["MOCK_HELPER_CRASH_AFTER": "1"]
            )

            let baseline = try FDLeakDetector.snapshot()
            var perCrashTimes: [Double] = []

            // D-19: profile first 5 crashes
            for _ in 0..<5 {
                let t0 = ContinuousClock.now
                _ = try? await client.callTool("mock-helper", "anything", [:])  // crashes after 1 call
                // wait for restart mutex to allow next call
                _ = try? await client.callTool("mock-helper", "anything", [:])
                let elapsed = (ContinuousClock.now - t0).components.attoseconds / 1_000_000_000_000_000  // ms
                perCrashTimes.append(Double(elapsed))
            }
            let medianSoFar = perCrashTimes.sorted()[perCrashTimes.count / 2]

            // D-19 decision
            let actualTarget: Int
            if extended {
                actualTarget = 500
            } else if medianSoFar <= 200 {
                actualTarget = max(targetCrashes, 100)  // ROADMAP literal 100
            } else {
                actualTarget = 50  // reduced — still detects linear FD leaks
            }

            // Run remaining crashes (already did 5)
            for _ in perCrashTimes.count..<actualTarget {
                let t0 = ContinuousClock.now
                _ = try? await client.callTool("mock-helper", "anything", [:])
                _ = try? await client.callTool("mock-helper", "anything", [:])
                let elapsed = (ContinuousClock.now - t0).components.attoseconds / 1_000_000_000_000_000
                perCrashTimes.append(Double(elapsed))
            }

            let final = try FDLeakDetector.snapshot()
            let delta = FDLeakDetector.delta(from: baseline, to: final)
            let whitelisted = applyWhitelist(delta.added)
            return CrashReport(
                crashCount: actualTarget,
                perCrashCycleTimeMs: perCrashTimes,
                medianCycleTimeMs: perCrashTimes.sorted()[perCrashTimes.count / 2],
                fdSnapshotBaseline: baseline,
                fdSnapshotFinal: final,
                fdAddedSinceBaseline: delta.added,
                fdRemovedSinceBaseline: delta.removed,
                steadyStateWhitelistMatched: whitelisted
            )
        }

        private func applyWhitelist(_ added: Set<String>) -> Bool {
            // Every "added" FD must match at least one whitelist pattern; otherwise it's a real leak.
            added.allSatisfy { fd in
                Self.steadyStateWhitelist.contains { pattern in
                    fd.contains(pattern.replacingOccurrences(of: "*", with: ""))
                }
            }
        }
    }

   The MockHelperBuilder must be available to the Harness target. If it's currently in the MCP test target only, expose it via a `@testable import MCP` if MCP's Package.swift allows, OR copy-and-rename the builder into `packages/Harness/Sources/Harness/Adapters/MockHelperBuilder.swift` (lift, don't reauthor — verbatim copy with minimal namespace edit).

4. Update `packages/Harness/Sources/jarvis-eval/main.swift` to register `McpCrash` subcommand:

    struct McpCrash: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp-crash",
            abstract: "Inject N MCP helper crashes; assert no FD leaks (D-19)."
        )
        @Option(help: "Target crash count. D-19 default 100 if median cycle <= 200ms, else 50.")
        var crashes: Int = 100
        @Flag(help: "Extended 500-crash mode (operator-driven longevity test).")
        var extended: Bool = false

        func run() async throws {
            let runner = MCPCrashRunner()
            let report = try await runner.run(targetCrashes: crashes, extended: extended)
            print("Crashes: \(report.crashCount), median cycle: \(report.medianCycleTimeMs) ms")
            print("FD delta: added=\(report.fdAddedSinceBaseline.count) removed=\(report.fdRemovedSinceBaseline.count)")
            print("Steady-state whitelist match: \(report.steadyStateWhitelistMatched)")
            if !report.passed {
                print("FAIL: unexpected FDs:")
                for fd in report.fdAddedSinceBaseline { print("  \(fd)") }
                throw ExitCode.failure
            }
        }
    }

5. Create `packages/Harness/Tests/HarnessTests/MCPCrashRunnerTests.swift` with at least:
   - 10-crash short run (test budget) verifies report shape + median time computed.
   - Whitelist match assertion: a known steady-state FD (e.g., the replay-log SQLite WAL) is whitelisted; a non-whitelisted artificial FD opened mid-loop fails the report.
   - D-19 cycle-time decision logic: mock crash times feeding into a unit-testable decision function (extract `decideTarget(medianMs:extended:userTarget:) -> Int` as a pure helper); test the boundary at 200 ms.
  </action>

  <acceptance_criteria>
    - File `packages/Harness/Sources/Harness/FDLeakDetector.swift` exists and contains `public enum FDLeakDetector` and `public struct FDSnapshot`
    - File `packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` exists and contains `public actor MCPCrashRunner`
    - D-19 profiling logic present: `grep -cE "medianSoFar|medianCycleTimeMs|<= 200|>= 200" packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` returns at least 2
    - Steady-state whitelist exists: `grep -c "steadyStateWhitelist" packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` returns at least 2
    - `swift run --package-path packages/Harness jarvis-eval mcp-crash --help` exits 0
    - `swift test --package-path packages/Harness --filter FDLeakDetectorTests` exits 0
    - `swift test --package-path packages/Harness --filter MCPCrashRunnerTests` exits 0
    - FDLeakDetector parses lsof terse output without throwing on edge cases (FIFO, socket, non-UTF-8 path) — verified by FDLeakDetectorTests
    - MCPCrashRunner does NOT replicate ChildSpawnGate FD_CLOEXEC enforcement; spawn must route through MCPClient as in production: `grep -c "Process()" packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift` returns 0 (only callTool through real MCPClient)
  </acceptance_criteria>

  <verify>
    <automated>swift test --package-path packages/Harness --filter FDLeakDetectorTests && swift test --package-path packages/Harness --filter MCPCrashRunnerTests && swift run --package-path packages/Harness jarvis-eval mcp-crash --help</automated>
  </verify>

  <done>FDLeakDetector + MCPCrashRunner ship with D-19 cycle-time profiling + 50-or-100 decision logic. Steady-state whitelist defined. mcp-crash subcommand wired and pass.</done>
</task>


<task type="auto">
  <name>Task 3: AudioGraphRebuildRunner (4 triggers × 6 steps) + ToolCapRecoveryRunner (D-21 dual assertion) + LiveOllamaRunner (D-06 preflight) + 3 subcommands</name>

  <read_first>
    - packages/Voice/Tests/VoiceTests/TeardownTests.swift (full file; 4-trigger × 6-step matrix per PATTERNS.md §2.6)
    - packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift (find rebuild trigger + teardown step ordering)
    - packages/AgentCore/Sources/AgentCore/ToolChoice.swift (ToolChoice.none enum case)
    - packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift (where tool_choice serializes — find via grep)
    - packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift (where tools array is dropped on .none)
    - packages/AgentCore/Tests/AgentOrchestratorTests (existing R4-L1 cap-recovery assertions — find via grep "cap-recovery\|toolChoice")
    - packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift (URLSession host that intercepts)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.6 (AudioGraphRebuildRunner)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.8 (ToolCapRecoveryRunner with CapturingURLProtocol)
    - .planning/phases/08-hardening/08-RESEARCH.md §Pitfall 5 lines 431-439 (D-21 rationale)
    - .planning/phases/08-hardening/08-RESEARCH.md §Pitfall 7 lines 451-459 (audio rebuild test isolation)
    - .planning/phases/08-hardening/08-CONTEXT.md D-04, D-06, D-14, D-21
    - .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md (just authored — read AVAudioEngine probe outcome)
  </read_first>

  <files>
    packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift,
    packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift,
    packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift,
    packages/Harness/Sources/Harness/CapturingURLProtocol.swift,
    packages/Harness/Sources/jarvis-eval/main.swift,
    packages/Harness/Tests/HarnessTests/AudioGraphRebuildRunnerTests.swift,
    packages/Harness/Tests/HarnessTests/ToolCapRecoveryRunnerTests.swift
  </files>

  <action>
1. Create `packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` per PATTERNS.md §2.6. Wraps the existing TeardownTests.swift 4-trigger × 6-step matrix as runner scenarios. Uses the AVAudioEngine route-change injection recipe from `08-LAUNCH-FRAGILITY-NOTES.md` (Task 1). If the probe outcome was "unavailable", emit `degradedToManual: true` for the deviceChange trigger:

    import Foundation
    import Voice

    public actor AudioGraphRebuildRunner {
        public enum Trigger: String, Sendable, CaseIterable, Codable {
            case deviceChange
            case aecFallback
            case micReGrant
            case sustainedRingOverflow
        }

        public struct RebuildReport: Sendable, Codable {
            public let trigger: Trigger
            public let teardownStepsObserved: [String]
            public let teardownStepsExpected: [String]
            public let rebuildSucceeded: Bool
            public let degradedToManual: Bool
            public let manualOperatorInstructions: String?
            public var passed: Bool {
                degradedToManual || (rebuildSucceeded && teardownStepsObserved == teardownStepsExpected)
            }
        }

        /// Canonical 6-step teardown sequence per VOICE-10. Source: TeardownTests.swift expectations.
        public static let canonicalTeardownSteps: [String] = [
            // Pull from TeardownTests.swift; expected order (PATTERNS.md §2.6):
            "stopEngine",
            "removeTaps",
            "disconnectNodes",
            "deactivateAVAudioSession",
            "releaseEngine",
            "reactivateAVAudioSession",
        ]

        public func run() async throws -> [RebuildReport] {
            var reports: [RebuildReport] = []
            for trigger in Trigger.allCases {
                // Pitfall 7: each trigger gets its OWN engine + setUp/tearDown. NEVER share state.
                let report = try await runSingleTrigger(trigger)
                reports.append(report)
            }
            return reports
        }

        private func runSingleTrigger(_ trigger: Trigger) async throws -> RebuildReport {
            switch trigger {
            case .deviceChange:
                // Per D-14: probe outcome from 08-LAUNCH-FRAGILITY-NOTES.md
                if Self.deviceChangeInjectionAvailable {
                    return try await runAutomatedTrigger(trigger, injection: { try await self.synthesizeDeviceChange() })
                } else {
                    return RebuildReport(
                        trigger: .deviceChange,
                        teardownStepsObserved: [],
                        teardownStepsExpected: Self.canonicalTeardownSteps,
                        rebuildSucceeded: false,
                        degradedToManual: true,
                        manualOperatorInstructions: "Plug in / unplug a USB-C audio interface during a `.speaking` turn; verify HUD enters reconfiguring state and rebuilds within 500ms."
                    )
                }
            case .aecFallback:
                return try await runAutomatedTrigger(trigger, injection: { try await self.synthesizeAecFallback() })
            case .micReGrant:
                return try await runAutomatedTrigger(trigger, injection: { try await self.synthesizeMicReGrant() })
            case .sustainedRingOverflow:
                return try await runAutomatedTrigger(trigger, injection: { try await self.synthesizeRingOverflow() })
            }
        }

        /// Set at task-1 conclusion based on AVAudioEngine route-change probe.
        /// Hard-coded here; if probe outcome changes, this constant updates.
        public static let deviceChangeInjectionAvailable: Bool = {
            // Pull from 08-LAUNCH-FRAGILITY-NOTES.md probe outcome.
            // Default: false (safe fallback to MANUAL per D-14 if we can't confirm).
            return false  // <-- update based on probe outcome
        }()

        private func runAutomatedTrigger(
            _ trigger: Trigger,
            injection: () async throws -> Void
        ) async throws -> RebuildReport {
            // Build fresh AudioGraphOwner with TeardownRecorder per Pitfall 7 / TeardownTests pattern
            let recorder = TeardownRecorder()
            let owner = AudioGraphOwner(builder: SucceedingBuilder())
            await owner.installRecorderSlots(recorder)
            try await owner.open()
            try await injection()
            let observed = await recorder.steps
            let succeeded = await owner.isReady
            return RebuildReport(
                trigger: trigger,
                teardownStepsObserved: observed,
                teardownStepsExpected: Self.canonicalTeardownSteps,
                rebuildSucceeded: succeeded,
                degradedToManual: false,
                manualOperatorInstructions: nil
            )
        }
    }

   The `synthesizeDeviceChange()` / `synthesizeAecFallback()` / `synthesizeMicReGrant()` / `synthesizeRingOverflow()` private methods invoke the same trigger paths TeardownTests.swift uses; lift them or expose them via @testable import. If the AudioGraphOwner production type is not directly accessible, pass through whatever Voice module's existing test helper exposes (`OwnerTestHelper.rebuild(trigger:)` or equivalent — find via grep at task start).

2. Create `packages/Harness/Sources/Harness/CapturingURLProtocol.swift` per PATTERNS.md §2.8:

    import Foundation

    public final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
        public static let lock = NSLock()
        nonisolated(unsafe) public static var capturedBodies: [Data] = []
        nonisolated(unsafe) public static var capturedRequests: [URLRequest] = []
        nonisolated(unsafe) public static var cannedResponse: Data = Data()
        nonisolated(unsafe) public static var cannedHeaders: [String: String] = ["Content-Type": "text/event-stream"]

        public override class func canInit(with request: URLRequest) -> Bool { true }
        public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        public override func startLoading() {
            Self.lock.lock()
            Self.capturedRequests.append(request)
            // Capture httpBody (may be nil if streaming — capture httpBodyStream too)
            if let body = request.httpBody {
                Self.capturedBodies.append(body)
            } else if let stream = request.httpBodyStream {
                stream.open()
                var buffer = Data()
                let bufSize = 4096
                var chunk = [UInt8](repeating: 0, count: bufSize)
                while stream.hasBytesAvailable {
                    let n = stream.read(&chunk, maxLength: bufSize)
                    if n <= 0 { break }
                    buffer.append(chunk, count: n)
                }
                stream.close()
                Self.capturedBodies.append(buffer)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: Self.cannedHeaders)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.cannedResponse)
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.unlock()
        }

        public override func stopLoading() {}

        public static func reset() {
            lock.lock()
            capturedBodies.removeAll()
            capturedRequests.removeAll()
            cannedResponse = Data()
            cannedHeaders = ["Content-Type": "text/event-stream"]
            lock.unlock()
        }
    }

3. Create `packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift` per PATTERNS.md §2.8 with D-21 dual assertion:

    import Foundation
    import AgentCore

    public actor ToolCapRecoveryRunner {
        public enum Provider: String, Sendable, Codable {
            case anthropic
            case ollama
        }

        public struct CapRecoveryReport: Sendable, Codable {
            public let provider: Provider
            public let toolUseEventCount: Int
            public let recoveryRequestBody: Data
            public let toolChoiceSerializedAsNone: Bool   // Anthropic: tool_choice == {type:"none"}; Ollama: no tools key
            public let toolsArrayPresent: Bool             // Anthropic: ignored; Ollama: must be false on recovery
            public var passed: Bool {
                toolUseEventCount == 0
                  && toolChoiceSerializedAsNone
                  && (provider == .anthropic || !toolsArrayPresent)
            }
        }

        public func run(provider: Provider) async throws -> CapRecoveryReport {
            URLProtocol.registerClass(CapturingURLProtocol.self)
            defer { URLProtocol.unregisterClass(CapturingURLProtocol.self) }
            CapturingURLProtocol.reset()

            // Stage canned cap-exhaustion SSE/NDJSON response so the orchestrator's
            // cap-recovery branch fires deterministically.
            CapturingURLProtocol.cannedResponse = try Self.cannedCapExhaustionResponse(for: provider)

            // Build orchestrator with capacity-1 tool-call budget so cap triggers immediately.
            // Drive a turn that exhausts the cap (the canned response says "tool_use" twice; budget
            // accepts one, second is over-cap → orchestrator sets tool_choice: .none for next call).
            // ... orchestrator submit ...
            let toolUseEventCount = ...  // count from event stream

            // D-21: inspect the LAST captured request body (the recovery turn's outbound)
            let recoveryBody = CapturingURLProtocol.capturedBodies.last ?? Data()
            let json = try JSONSerialization.jsonObject(with: recoveryBody) as? [String: Any] ?? [:]

            let toolChoiceSerializedAsNone: Bool
            let toolsArrayPresent: Bool
            switch provider {
            case .anthropic:
                let tc = json["tool_choice"] as? [String: Any]
                toolChoiceSerializedAsNone = tc?["type"] as? String == "none"
                toolsArrayPresent = json["tools"] != nil  // Anthropic keeps the tools array; tool_choice gates them
            case .ollama:
                // Ollama: drop tools array entirely; no separate tool_choice field
                toolChoiceSerializedAsNone = json["tools"] == nil
                toolsArrayPresent = json["tools"] != nil
            }

            return CapRecoveryReport(
                provider: provider,
                toolUseEventCount: toolUseEventCount,
                recoveryRequestBody: recoveryBody,
                toolChoiceSerializedAsNone: toolChoiceSerializedAsNone,
                toolsArrayPresent: toolsArrayPresent
            )
        }

        private static func cannedCapExhaustionResponse(for provider: Provider) throws -> Data {
            // Bundle.module fixture: corpus contains a cap-exhausting SSE/NDJSON stream
            // ...
        }
    }

4. Create `packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` per D-06:

    import Foundation
    import AgentCore

    public actor LiveOllamaRunner {
        public enum Error: Swift.Error, Equatable {
            case daemonUnreachable(advice: String)
            case modelMissing(modelId: String, advice: String)
            case liveGateNotEnabled
        }

        public struct LiveReport: Sendable, Codable {
            public let modelId: String
            public let scenarioCount: Int
            public let passedCount: Int
            public var passed: Bool { passedCount == scenarioCount }
        }

        public func run(scenarios: [String]) async throws -> LiveReport {
            // D-04: verify JARVIS_LIVE_EVAL=1 env var
            guard ProcessInfo.processInfo.environment["JARVIS_LIVE_EVAL"] == "1" else {
                throw Error.liveGateNotEnabled
            }

            // D-06: preflight curl http://127.0.0.1:11434/api/tags
            let url = URL(string: "http://127.0.0.1:11434/api/tags")!
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(from: url)
            } catch {
                throw Error.daemonUnreachable(advice: "Ollama not running; start `ollama serve`")
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Error.daemonUnreachable(advice: "Ollama not running; start `ollama serve`")
            }
            // Verify qwen2.5-coder:32b in models array
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let models = (json["models"] as? [[String: Any]]) ?? []
            let names = models.compactMap { $0["name"] as? String }
            guard names.contains("qwen2.5-coder:32b") else {
                throw Error.modelMissing(
                    modelId: "qwen2.5-coder:32b",
                    advice: "Run `ollama pull qwen2.5-coder:32b` (~20 GB; do this manually)"
                )
            }

            // ... drive scenarios through real OllamaProvider against 127.0.0.1:11434 ...
            return LiveReport(...)
        }
    }

5. Update `packages/Harness/Sources/jarvis-eval/main.swift` to register `CapRecovery`, `AudioRebuild`, and extend `CorpusNDJSON` with `--live` flag:

    struct CapRecovery: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cap-recovery",
            abstract: "R4-L1 regression: cap-recovery turn passes tool_choice: .none (D-21 dual assertion)."
        )
        @Option(help: "Provider: anthropic | ollama")
        var provider: String = "anthropic"

        func run() async throws {
            let p: ToolCapRecoveryRunner.Provider = (provider == "ollama") ? .ollama : .anthropic
            let report = try await ToolCapRecoveryRunner().run(provider: p)
            print("Provider: \(report.provider)")
            print("Tool-use events: \(report.toolUseEventCount) (must be 0)")
            print("tool_choice serialized as none: \(report.toolChoiceSerializedAsNone)")
            print("tools array present: \(report.toolsArrayPresent)")
            if !report.passed { throw ExitCode.failure }
        }
    }

    struct AudioRebuild: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "audio-rebuild",
            abstract: "4 canonical triggers × 6-step teardown matrix (D-14 graceful degradation)."
        )
        func run() async throws {
            let reports = try await AudioGraphRebuildRunner().run()
            for r in reports {
                if r.degradedToManual {
                    print("MANUAL: \(r.trigger.rawValue) — \(r.manualOperatorInstructions ?? "")")
                } else {
                    print("\(r.trigger.rawValue): \(r.passed ? "PASS" : "FAIL")")
                }
            }
            if reports.contains(where: { !$0.passed && !$0.degradedToManual }) {
                throw ExitCode.failure
            }
        }
    }

   Extend the existing `CorpusNDJSON` subcommand (from 08-02 if landed first; otherwise this plan adds the subcommand) with a `--live` flag that, when set + `JARVIS_LIVE_EVAL=1`, invokes `LiveOllamaRunner` AFTER the fixture run. Note: 08-02 and 08-03 both touch `main.swift`; this is acceptable because they ARE in the same wave and share that file — but Wave-2 orchestration must serialize them at the file level. The cleaner approach is for 08-03 to author `LiveOllamaRunner` and a NEW `corpus-ndjson-live` subcommand here, leaving the offline `corpus-ndjson` to 08-02; later in 08-04 the operator can fold both into a single subcommand. Use `corpus-ndjson-live` here for clean separation.

6. Create tests:
   - `packages/Harness/Tests/HarnessTests/AudioGraphRebuildRunnerTests.swift`: parameterized over `Trigger.allCases`. Each trigger gets its own fresh AudioGraphOwner per Pitfall 7. The deviceChange trigger asserts EITHER automated success OR `degradedToManual: true`.
   - `packages/Harness/Tests/HarnessTests/ToolCapRecoveryRunnerTests.swift`: D-21 dual assertion test. Mocks the orchestrator with a canned cap-exhaustion stream; asserts BOTH (a) zero tool-use events AND (b) outbound body contains the correct serialization. Includes a regression test: if a refactor removes the `ToolChoice` parameter from `LLMProvider.stream(...)`, this test must fail (contributes the R4-L1 regression guard).
  </action>

  <acceptance_criteria>
    - File `packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` contains all 4 cases: `grep -cE "case deviceChange|case aecFallback|case micReGrant|case sustainedRingOverflow" packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` returns at least 4
    - Canonical 6-step teardown list present: `grep -c "canonicalTeardownSteps" packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` returns at least 2
    - D-14 manual degradation path present: `grep -c "degradedToManual" packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift` returns at least 2
    - File `packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift` contains D-21 dual assertion: `grep -cE "toolChoiceSerializedAsNone|toolsArrayPresent" packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift` returns at least 2
    - Both Anthropic and Ollama provider variants present: `grep -cE "case anthropic|case ollama" packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift` returns at least 2
    - File `packages/Harness/Sources/Harness/CapturingURLProtocol.swift` contains `URLProtocol` subclass and captures both httpBody and httpBodyStream: `grep -cE "httpBody|httpBodyStream" packages/Harness/Sources/Harness/CapturingURLProtocol.swift` returns at least 2
    - File `packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` exists; D-06 preflight present: `grep -c "127\.0\.0\.1:11434" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` returns at least 1
    - LiveOllamaRunner never auto-pulls: `grep -cE "ollama pull|exec.*ollama" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` returns 0 (and any reference to "pull" appears only in operator-advice strings)
    - D-04 dual gate enforced: `grep -c "JARVIS_LIVE_EVAL" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift` returns at least 1
    - `swift run --package-path packages/Harness jarvis-eval cap-recovery --help` exits 0
    - `swift run --package-path packages/Harness jarvis-eval audio-rebuild --help` exits 0
    - `swift test --package-path packages/Harness --filter AudioGraphRebuildRunnerTests` exits 0
    - `swift test --package-path packages/Harness --filter ToolCapRecoveryRunnerTests` exits 0
    - `swift build --package-path packages/Harness` exits 0
  </acceptance_criteria>

  <verify>
    <automated>swift build --package-path packages/Harness && swift test --package-path packages/Harness --filter AudioGraphRebuildRunnerTests && swift test --package-path packages/Harness --filter ToolCapRecoveryRunnerTests && swift run --package-path packages/Harness jarvis-eval cap-recovery --help && swift run --package-path packages/Harness jarvis-eval audio-rebuild --help</automated>
  </verify>

  <done>AudioGraphRebuildRunner exercises 4 triggers with the 6-step canonical teardown; deviceChange degrades to MANUAL per D-14 if route-change injection unavailable. ToolCapRecoveryRunner enforces D-21 dual assertion (zero tool-use events + outbound body inspection). LiveOllamaRunner preflights per D-06; never auto-pulls. cap-recovery, audio-rebuild subcommands wired; corpus-ndjson-live extends Plan 08-02's offline corpus runner.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| MCPCrashRunner -> spawned helper -> SIGKILL | Existing MCP TCC boundary; runner injects crashes via env var, not new spawn paths. |
| AudioGraphRebuildRunner -> AVAudioEngine -> microphone | Real microphone access if probe-injection succeeds; existing TCC microphone permission already required by Voice module. |
| LiveOllamaRunner -> Ollama daemon (127.0.0.1:11434) | Localhost-only egress per AGENT-05; no new network surface. |
| ToolCapRecoveryRunner -> CapturingURLProtocol -> orchestrator's outbound HTTP | Test-time URLProtocol replaces real Anthropic/Ollama egress with canned responses; no real network. |
| Live mode opt-in (--live + env var) -> Anthropic API | Real egress with operator's API key from Keychain; cost risk if mis-invoked. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-08-11 | Denial of Service (financial) | `--live` mode accidentally invoked in CI / autonomous loop, burning Anthropic budget | mitigate | D-04 dual-gate: `--live` flag AND `JARVIS_LIVE_EVAL=1` env var both required. CI CONFIG must not set the env var; the orchestrator's CI invocation explicitly passes `--skip-live`. LiveOllamaRunner throws `Error.liveGateNotEnabled` if env var missing. Acceptance criterion in Task 3 asserts the env var check is present. |
| T-08-12 | Denial of Service | MCPCrashRunner's 100-cycle loop exhausts file descriptors on the test host, taking down the harness process | mitigate | D-19 cycle-time profiling caps at 50 if median > 200 ms; FD-leak detector runs after EACH 10 crashes (sample) to catch linear leaks early; `applyWhitelist` rejects unexpected FDs immediately rather than at end-of-loop. |
| T-08-13 | Tampering | An operator's local Ollama install proxies calls externally (e.g., re-routed via custom OLLAMA_HOST); LiveOllamaRunner sends prompts to attacker | accept | AGENT-05 already constrains `ollama.base_url` to `127.0.0.1`/`localhost` at config load; LiveOllamaRunner reuses that constraint. If the operator's daemon is compromised, that's outside P8 scope. |
| T-08-14 | Information Disclosure | CapturingURLProtocol logs captured request bodies that contain Anthropic API key headers when running against the real provider | mitigate | CapturingURLProtocol is registered ONLY during ToolCapRecoveryRunner.run(); the canned response replaces the real network call entirely (no real Anthropic egress). The captured body is the OUTBOUND request body which contains the message payload, not the auth header (URLSession adds auth as a header, not body). Test guard: `grep` captured bodies for `sk-ant-` patterns at the end of each run. |
| T-08-15 | Spoofing | AVAudioEngine route-change injection fires repeatedly within a test, accumulating undetected state in the AVAudioSession singleton | mitigate | Pitfall 7: each trigger gets fresh `AudioGraphOwner` + explicit `setUp`/`tearDown { engine.reset(); engine = nil }`. AVAudioSession is process-wide so it cannot be reset; but each trigger explicitly deactivates+reactivates it as part of the canonical 6-step sequence. |
| T-08-16 | Tampering | Xcode 26 launch fragility resolution introduces a build-setting change that weakens codesign | mitigate | Task 1 explicitly preserves Hardened Runtime + allow-jit + speech-recognition-assets entitlements. The fix MUST verify post-resolution: `codesign --display --entitlements - build/Debug/Jarvis.app` lists the same entitlements as Release. Task 1 acceptance criteria includes `codesign --verify` exit 0. If the fix turns out to require entitlement weakening, plan reverts to ACCEPTED AS MANUAL path (no entitlement change). |
</threat_model>

<verification>
After all tasks complete:

```bash
swift build --package-path packages/Harness
swift test --package-path packages/Harness

# Subcommands wired
for sub in cap-recovery audio-rebuild mcp-crash corpus-ndjson-live; do
  swift run --package-path packages/Harness jarvis-eval $sub --help || exit 1
done

# Launch fragility resolved or documented
test -s .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md
grep -qE "RESOLUTION:\s*(RESOLVED|ACCEPTED AS MANUAL)" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md

# AVAudioEngine probe outcome documented
grep -q "AVAudioEngine Route-Change Injection Probe" .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md

# D-21 dual assertion present
grep -q "toolChoiceSerializedAsNone" packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift
grep -q "toolsArrayPresent" packages/Harness/Sources/Harness/Runners/ToolCapRecoveryRunner.swift

# D-19 cycle-time profiling present
grep -qE "<= 200|medianCycleTimeMs" packages/Harness/Sources/Harness/Runners/MCPCrashRunner.swift

# D-14 graceful degradation present
grep -q "degradedToManual" packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift

# D-06 preflight + D-04 dual-gate present
grep -q "127.0.0.1:11434" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift
grep -q "JARVIS_LIVE_EVAL" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift

# Never auto-pulls models
! grep -E "exec.*ollama pull" packages/Harness/Sources/Harness/Runners/LiveOllamaRunner.swift
```
</verification>

<success_criteria>
- Xcode 26 launch fragility resolved with verified codesign success OR ACCEPTED AS MANUAL with operator instructions (D-12 / D-13).
- AVAudioEngine route-change injection probe outcome recorded; AudioGraphRebuildRunner uses the recipe OR degrades to MANUAL per D-14.
- FDLeakDetector + MCPCrashRunner ship with D-19 cycle-time profiling + 50/100 decision logic + steady-state whitelist.
- AudioGraphRebuildRunner exercises 4 canonical triggers with 6-step teardown ordering enforced.
- ToolCapRecoveryRunner enforces D-21 dual assertion; CapturingURLProtocol captures both httpBody and httpBodyStream.
- LiveOllamaRunner preflights per D-06; gates on D-04 dual env var + flag; never auto-pulls.
- 3 new jarvis-eval subcommands: cap-recovery, audio-rebuild, mcp-crash; corpus-ndjson-live added.
</success_criteria>

<output>
After completion, create `.planning/phases/08-hardening/08-03-live-and-integration-runners-SUMMARY.md` recording:
- Xcode 26 launch fragility outcome (RESOLVED with diff or ACCEPTED AS MANUAL with instructions)
- AVAudioEngine route-change injection probe outcome (available + recipe OR unavailable + MANUAL fallback)
- MCPCrashRunner profiled median cycle time on the host; resulting actualTarget (50 vs 100)
- Steady-state FD whitelist composition (final list)
- D-21 outbound-body inspection: sample captured request body bytes for both providers (Anthropic + Ollama recovery turn)
- LiveOllamaRunner preflight: actual Ollama daemon state at execution time + qwen2.5-coder:32b availability
- Cross-reference for plan 08-04: which P6 deferred items still need MANUAL: checklist entries (Orpheus TTFA, 6 UAT gates) — list IDs to fold during sweep
</output>
