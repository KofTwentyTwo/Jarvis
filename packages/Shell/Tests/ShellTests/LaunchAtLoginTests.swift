import XCTest
@testable import Shell

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func test_controllerInstantiates() {
        let controller = LaunchAtLoginController()
        // We can't safely register/unregister without polluting the real login
        // items list unless `JARVIS_ALLOW_SM_TESTS=1` is set. Just verify the
        // API surface is reachable.
        _ = controller.isEnabled
        _ = controller.requiresApproval
    }

    func test_registerUnregisterIdempotent() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_ALLOW_SM_TESTS"] == "1" else {
            throw XCTSkip(
                "Skipping SMAppService live test — set JARVIS_ALLOW_SM_TESTS=1 to opt in"
            )
        }
        let controller = LaunchAtLoginController()
        try? controller.disable()    // start from known state
        try controller.enable()
        try controller.disable()
        try controller.disable()     // idempotent — second disable must not throw
    }
}
