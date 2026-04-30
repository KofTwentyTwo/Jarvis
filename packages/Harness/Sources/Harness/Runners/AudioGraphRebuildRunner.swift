import Foundation
import AVFoundation
import Voice

/// AudioGraphRebuildRunner — Plan 08-03 Task 3, OBS-04 pillar (g).
///
/// Exercises the production `AudioGraphOwner` against the four canonical
/// `RebuildTrigger` cases and asserts each one drives a complete rebuild
/// cycle ending in a `.reconfiguring(reason:)` event. The Voice package's
/// own `TeardownTests` already covers the strict ordering of the
/// canonical six teardown steps; this runner is the integration-level
/// gate that confirms each trigger reaches the event boundary in
/// the harness process.
///
/// Pitfall 7 (08-RESEARCH §Common Pitfalls): each trigger gets its OWN
/// fresh `AudioGraphOwner` + builder + stream pair. NEVER share state
/// across triggers — `AVAudioSession` is process-wide, but actor state
/// is fenced per instance.
///
/// D-14 graceful degradation: per the AVAudioEngine route-change probe
/// in `08-LAUNCH-FRAGILITY-NOTES.md`, all four triggers run automated
/// because the production `rebuild(trigger:)` seam is the synthetic
/// injection mechanism (same recipe TeardownTests uses). The MANUAL
/// fallback path is preserved in code for any future case where the
/// probe outcome flips to "unavailable".
public actor AudioGraphRebuildRunner {

    public enum Trigger: String, Sendable, CaseIterable, Codable {
        case deviceChange
        case aecFallback
        case micRegrant
        case ringOverflow
    }

    public struct RebuildReport: Sendable, Codable {
        public let trigger: Trigger
        public let teardownStepsObserved: [String]
        public let teardownStepsExpected: [String]
        public let rebuildSucceeded: Bool
        public let degradedToManual: Bool
        public let manualOperatorInstructions: String?

        public var passed: Bool {
            // MANUAL trigger trivially passes the runner-level check
            // (operator runs the steps; harness records intent).
            // Otherwise: rebuild must have succeeded AND every required
            // observed step must be present (subsequence containment).
            if degradedToManual { return true }
            guard rebuildSucceeded else { return false }
            // We observe a strict subset (cancelInFlight + releaseORTSessions
            // + .reconfiguring event); the strict 6-step ordering is the
            // contract of TeardownTests in the Voice test target. Runner
            // asserts presence of each observed step.
            return Set(teardownStepsObserved).isSuperset(of: AudioGraphRebuildRunner.observableTeardownSteps)
        }
    }

    /// The canonical six-step teardown sequence (VOICE-10 contract). The
    /// Voice test target's `TeardownTests` asserts strict ordering; this
    /// runner records the spec for `RebuildReport.teardownStepsExpected`.
    public static let canonicalTeardownSteps: [String] = [
        "cancelInFlight",
        "stop",
        "removeAllTaps",
        "releaseRings",
        "releaseORTSessions",
        "reconfiguring",
    ]

    /// Steps the runner can directly observe at the public boundary of
    /// `AudioGraphOwner`: the two pre/post slots plus the rebuild event.
    /// Steps 2-4 (stop / removeAllTaps / releaseRings) hook into AudioGraph
    /// internals which are not part of Voice's public API; their assertion
    /// lives in `TeardownTests`.
    public static let observableTeardownSteps: Set<String> = [
        "cancelInFlight",
        "releaseORTSessions",
        "reconfiguring",
    ]

    /// Probe outcome from `08-LAUNCH-FRAGILITY-NOTES.md`. `true` means
    /// `rebuild(trigger:)` direct-call recipe is sufficient as the
    /// synthetic injection mechanism — no MANUAL operator needed.
    public static let deviceChangeInjectionAvailable: Bool = true

    public init() {}

    public func run() async throws -> [RebuildReport] {
        var reports: [RebuildReport] = []
        for trigger in Trigger.allCases {
            let report = try await runSingleTrigger(trigger)
            reports.append(report)
        }
        return reports
    }

    private func runSingleTrigger(_ trigger: Trigger) async throws -> RebuildReport {
        if trigger == .deviceChange && !Self.deviceChangeInjectionAvailable {
            return RebuildReport(
                trigger: .deviceChange,
                teardownStepsObserved: [],
                teardownStepsExpected: Self.canonicalTeardownSteps,
                rebuildSucceeded: false,
                degradedToManual: true,
                manualOperatorInstructions:
                    "Plug in / unplug a USB-C audio interface during a `.speaking` turn; verify HUD enters reconfiguring state and the graph rebuilds within ~500ms."
            )
        }

        // Pitfall 7: fresh state PER trigger. Build a brand-new owner +
        // stream + builder; never reuse across triggers.
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()
        let recorder = StepRecorder()

        let fmt16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: HarnessSucceedingBuilder(fmt: fmt16k)
        )

        // Install the public observer slots. cancelInFlight + releaseORTSessions
        // are public on AudioGraphOwner; record fires when each is invoked
        // during the canonical teardown.
        await owner.setCancelInFlight {
            await recorder.append("cancelInFlight")
        }
        await owner.setReleaseORTSessions {
            await recorder.append("releaseORTSessions")
        }

        try await owner.open()

        // Drain rebuild events into the recorder. Reconfiguring marks step 6.
        let collectTask = Task<Void, Never> {
            for await event in rebuildStream {
                if case .reconfiguring = event {
                    await recorder.append("reconfiguring")
                }
            }
        }

        // Map our Trigger enum to Voice's RebuildTrigger.
        let voiceTrigger: RebuildTrigger
        switch trigger {
        case .deviceChange: voiceTrigger = .deviceChange
        case .aecFallback: voiceTrigger = .aecFallback
        case .micRegrant: voiceTrigger = .micRegrant
        case .ringOverflow: voiceTrigger = .ringOverflow
        }

        await owner.rebuild(trigger: voiceTrigger)

        // Give the rebuild event a moment to drain through the stream.
        try? await Task.sleep(nanoseconds: 50_000_000)

        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let observed = await recorder.snapshot
        let succeeded = await owner.currentVariant != nil

        await owner.shutdown()
        // Suppress unused-variable warning for the live degradation stream.
        _ = degradationStream

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

// MARK: - Helpers

/// Thread-safe step recorder for the runner. An actor (vs an `NSLock`-wrapped
/// reference type) keeps Sendable conformance automatic.
private actor StepRecorder {
    private var steps: [String] = []
    func append(_ step: String) { steps.append(step) }
    var snapshot: [String] { steps }
}

/// Inline succeeding builder. Lifted from the equivalent shape in
/// `packages/Voice/Tests/VoiceTests/AECFallbackTests.swift` (`SucceedingBuilder`).
/// Inline avoids widening Voice's public surface for a runner-only need.
private struct HarnessSucceedingBuilder: GraphBuilder {
    let fmt: AVAudioFormat
    func flipVPIO(_ inputNode: AVAudioInputNode) throws {}
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(
        _ engine: AVAudioEngine,
        _ src: AVAudioNode,
        to dst: AVAudioNode,
        format: AVAudioFormat?
    ) {}
    func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {}
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat { fmt }
}

// MARK: - AudioGraphOwner setter shims
//
// AudioGraphOwner exposes `cancelInFlight` and `releaseORTSessions` as
// `public var` — but writing to a `var` on an actor from outside the
// actor isolation requires a setter. These extensions hop onto the actor
// and assign.

private extension AudioGraphOwner {
    func setCancelInFlight(_ closure: @escaping @Sendable () async -> Void) {
        self.cancelInFlight = closure
    }
    func setReleaseORTSessions(_ closure: @escaping @Sendable () async -> Void) {
        self.releaseORTSessions = closure
    }
}
