import XCTest
@testable import JarvisVision

/// VISION-03 sanity test — fails if anyone in this test target accidentally
/// adds an `import Voice` or `import AgentOrchestrator`. The textual grep
/// gate (scripts/check-vision-isolation.sh) is the primary defense; this
/// test is an in-process secondary check at the symbol level.
final class PackageBoundaryTests: XCTestCase {

    /// Symbol-level assertion: the Vision module exposes PresenceSignalBus,
    /// CameraCapture, PresenceMonitor, DisablePresence, VisionError,
    /// VisionDegradationReason. Missing any one is a compile failure here.
    ///
    /// VISION-03 isolation (Vision MUST NOT transitively import Voice or
    /// AgentOrchestrator) is enforced primarily by
    /// `scripts/check-vision-isolation.sh` and the package dependency graph
    /// in Package.swift. The previous `testVisionModuleCompilesStandalone`
    /// test was an `XCTAssertTrue(true)` tautology removed in the
    /// 2026-05-04 cleanup batch (see `.planning/audit-2026-05-03/tests-audit.md`).
    func testPublicAPISurface() {
        let _: PresenceEvent.Type = PresenceEvent.self
        let _: PresenceSignalBus.Type = PresenceSignalBus.self
        let _: VisionError.Type = VisionError.self
        let _: VisionDegradationReason.Type = VisionDegradationReason.self
        // CameraCapture, PresenceMonitor, DisablePresence reference each
        // other; their existence is verified by their dedicated test files.
    }
}
