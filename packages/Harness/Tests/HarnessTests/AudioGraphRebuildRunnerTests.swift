import XCTest
@testable import Harness

final class AudioGraphRebuildRunnerTests: XCTestCase {

    func test_canonicalTeardownSteps_areSixInOrder() {
        XCTAssertEqual(AudioGraphRebuildRunner.canonicalTeardownSteps, [
            "cancelInFlight",
            "stop",
            "removeAllTaps",
            "releaseRings",
            "releaseORTSessions",
            "reconfiguring",
        ])
    }

    func test_observableTeardownSteps_isSubsetOfCanonical() {
        let canonical = Set(AudioGraphRebuildRunner.canonicalTeardownSteps)
        XCTAssertTrue(AudioGraphRebuildRunner.observableTeardownSteps.isSubset(of: canonical))
    }

    func test_deviceChangeInjectionAvailable_perD14ProbeOutcome() {
        // The 08-LAUNCH-FRAGILITY-NOTES.md probe records `available`. The
        // constant must mirror that outcome so the runner does not silently
        // degrade to MANUAL when the recipe IS available.
        XCTAssertTrue(AudioGraphRebuildRunner.deviceChangeInjectionAvailable)
    }

    func test_rebuildReport_passed_isTrueForManualDegradation() {
        let r = AudioGraphRebuildRunner.RebuildReport(
            trigger: .deviceChange,
            teardownStepsObserved: [],
            teardownStepsExpected: AudioGraphRebuildRunner.canonicalTeardownSteps,
            rebuildSucceeded: false,
            degradedToManual: true,
            manualOperatorInstructions: "plug in USB device"
        )
        XCTAssertTrue(r.passed)
    }

    func test_rebuildReport_passed_requiresAllObservableSteps() {
        let allSteps = Array(AudioGraphRebuildRunner.observableTeardownSteps)
        let r = AudioGraphRebuildRunner.RebuildReport(
            trigger: .aecFallback,
            teardownStepsObserved: allSteps,
            teardownStepsExpected: AudioGraphRebuildRunner.canonicalTeardownSteps,
            rebuildSucceeded: true,
            degradedToManual: false,
            manualOperatorInstructions: nil
        )
        XCTAssertTrue(r.passed)
    }

    func test_rebuildReport_passed_isFalseOnRebuildFailure() {
        let allSteps = Array(AudioGraphRebuildRunner.observableTeardownSteps)
        let r = AudioGraphRebuildRunner.RebuildReport(
            trigger: .aecFallback,
            teardownStepsObserved: allSteps,
            teardownStepsExpected: AudioGraphRebuildRunner.canonicalTeardownSteps,
            rebuildSucceeded: false,
            degradedToManual: false,
            manualOperatorInstructions: nil
        )
        XCTAssertFalse(r.passed)
    }

    func test_rebuildReport_passed_isFalseOnMissingObservedSteps() {
        // Missing `reconfiguring` => not a superset of observable steps.
        let r = AudioGraphRebuildRunner.RebuildReport(
            trigger: .aecFallback,
            teardownStepsObserved: ["cancelInFlight", "releaseORTSessions"],
            teardownStepsExpected: AudioGraphRebuildRunner.canonicalTeardownSteps,
            rebuildSucceeded: true,
            degradedToManual: false,
            manualOperatorInstructions: nil
        )
        XCTAssertFalse(r.passed)
    }

    func test_trigger_allCases_cover4canonicalCases() {
        let all = Set(AudioGraphRebuildRunner.Trigger.allCases.map(\.rawValue))
        XCTAssertEqual(all, ["deviceChange", "aecFallback", "micRegrant", "ringOverflow"])
    }

    /// Drives the runner against the in-process AudioGraphOwner. Pitfall 7:
    /// fresh state per trigger; the runner re-creates owner+streams per call.
    /// Skipped under env `HARNESS_SKIP_AUDIO_RUN=1` for sandboxes that
    /// cannot bring up an AudioGraphOwner with mock builders (CI host
    /// without AVAudioEngine permissions).
    func test_run_drivesAllFourTriggersToCompletion() async throws {
        if ProcessInfo.processInfo.environment["HARNESS_SKIP_AUDIO_RUN"] == "1" {
            throw XCTSkip("HARNESS_SKIP_AUDIO_RUN=1 — skipping live audio-graph rebuild")
        }
        let runner = AudioGraphRebuildRunner()
        let reports = try await runner.run()
        XCTAssertEqual(reports.count, 4)
        for r in reports {
            XCTAssertEqual(r.teardownStepsExpected, AudioGraphRebuildRunner.canonicalTeardownSteps)
            // Either a successful automated run OR a documented MANUAL.
            XCTAssertTrue(
                r.passed || r.degradedToManual,
                "trigger \(r.trigger.rawValue) failed: observed=\(r.teardownStepsObserved)"
            )
        }
    }
}
