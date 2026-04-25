import XCTest
import Logging
@testable import JarvisLogging

final class LoggingTests: XCTestCase {
    func test_sevenChannelsAreDefined() {
        // `bus` was added in Phase 2 (RESEARCH §OBS-06 open question #7).
        // `replay` + `devoverlay` were added in Plan 04-03 for the on-disk
        // replay log + DevOverlay surfaces (Plan 04-05). `mcp` was added in
        // Plan 05-05 for the JarvisMCP confirmation broker WARNING log lines
        // (AGENT-11 timeout-as-deny). Keep this set in sync with
        // `JarvisLogChannel`.
        let expected: Set<String> = ["agent", "tools", "ui", "system", "bus", "replay", "devoverlay", "mcp"]
        let actual = Set(JarvisLogChannel.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }

    func test_factoryProducesMultiplexLogHandler() {
        let handler = JarvisLogHandlerFactory.make(label: "agent")
        // MultiplexLogHandler is a struct; cast-check via type dump.
        XCTAssertEqual(String(describing: type(of: handler)), "MultiplexLogHandler")
    }

    func test_bootstrapRunsWithoutThrowing() {
        // This test is intentionally NOT exercising LoggingSystem.bootstrap multiple times —
        // swift-log allows bootstrap exactly once per process. In test runs, calling
        // bootstrap is unsafe across tests. We instead verify the factory is callable.
        XCTAssertNoThrow(JarvisLogHandlerFactory.make(label: "system"))
    }

    func test_subsystemConstant() {
        XCTAssertEqual(JarvisLogHandlerFactory.subsystem, "com.koftwentytwo.jarvis")
    }
}
