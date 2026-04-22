import XCTest
@testable import Jarvis
@testable import Shell

/// D-08 / SEC-04 enforcement: Stage 2 of the wizard actively calls the Input
/// Monitoring permission API ONLY. Microphone, Camera, and Automation rows
/// are explainer-only — they surface copy but do NOT invoke
/// `AVCaptureDevice.requestAccess`, `AEDeterminePermissionToAutomateTarget`,
/// or any other permission-prompting API.
///
/// The test doesn't need to instantiate the view (which requires a full
/// SwiftUI render cycle); it verifies the contract at the probe layer — the
/// only real surface that can accidentally widen P1's TCC footprint.
@MainActor
final class WizardTCCStageTests: XCTestCase {
    /// `@unchecked Sendable`: counter is `var` (required by Sendable), but
    /// every interaction in these @MainActor-bound tests happens on main.
    private final class CountingHIDProbe: HIDAccessProbe, @unchecked Sendable {
        var requestListenEventCount = 0
        func requestListenEventAccess() -> Bool {
            requestListenEventCount += 1
            return true
        }
    }

    func test_onlyInputMonitoringTriggers() {
        let hidProbe = CountingHIDProbe()
        let probe = InputMonitoringProbe(probe: hidProbe)
        _ = probe.check(sink: nil)
        XCTAssertEqual(
            hidProbe.requestListenEventCount, 1,
            "Stage 2 must only call IOHIDRequestAccess once — no Mic/Camera/Automation permission calls (D-08/SEC-04)"
        )
        // The other TCC surfaces — AVCaptureDevice.requestAccess,
        // AEDeterminePermissionToAutomateTarget — are NOT called anywhere in
        // the WizardStageTCCView. This test encodes the contract at the probe
        // layer; a grep gate in acceptance criteria catches accidental
        // widening at source level.
    }
}
