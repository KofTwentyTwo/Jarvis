import XCTest
import Logging
@testable import JarvisLogging

final class LoggingTests: XCTestCase {
    func test_fiveChannelsAreDefined() {
        // `bus` was added in Phase 2 for bus-specific logging (RESEARCH §OBS-06
        // open question #7). Keep this set in sync with `JarvisLogChannel`.
        let expected: Set<String> = ["agent", "tools", "ui", "system", "bus"]
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
