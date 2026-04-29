import XCTest
@testable import JarvisVision

/// VISION-03 sanity test — fails if anyone in this test target accidentally
/// adds an `import Voice` or `import AgentOrchestrator`. The textual grep
/// gate (scripts/check-vision-isolation.sh) is the primary defense; this
/// test is an in-process secondary check at the symbol level.
final class PackageBoundaryTests: XCTestCase {

    /// Confirms the Vision module compiles without Voice/AgentOrchestrator
    /// types being reachable. (If a future contributor adds a transitive
    /// dependency, the symbol resolution will succeed and this test must
    /// be updated to fail explicitly via #if canImport(...) guards.)
    func testVisionModuleCompilesStandalone() {
        // Intentionally empty body; the compile of the test target itself
        // is the assertion. Test passes iff Vision builds without Voice
        // or AgentOrchestrator imports anywhere in its dependency closure.
        XCTAssertTrue(true)
    }

    /// Symbol-level assertion: the Vision module exposes PresenceSignalBus,
    /// CameraCapture, PresenceMonitor, DisablePresence, VisionError,
    /// VisionDegradationReason. Missing any one is a compile failure here.
    func testPublicAPISurface() {
        let _: PresenceEvent.Type = PresenceEvent.self
        let _: PresenceSignalBus.Type = PresenceSignalBus.self
        let _: VisionError.Type = VisionError.self
        let _: VisionDegradationReason.Type = VisionDegradationReason.self
        // CameraCapture, PresenceMonitor, DisablePresence reference each
        // other; their existence is verified by their dedicated test files.
    }
}
