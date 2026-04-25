import XCTest
@testable import JarvisLogging

/// Targeted assertions for the channel additions in Plans 04-03 and 05-05.
/// The full 8-channel set is also covered by `test_sevenChannelsAreDefined`
/// in `LoggingTests`; the targeted tests below make the new cases
/// discoverable from the file name alone.
final class ChannelTests: XCTestCase {
    func test_C1_eightCases() {
        // Plan 05-05 added `.mcp` for the JarvisMCP confirmation-broker /
        // ConfirmingToolDispatcher WARNING log lines (AGENT-11 timeout-as-deny).
        XCTAssertEqual(JarvisLogChannel.allCases.count, 8)
    }

    func test_C2_existingCasesPreserved() {
        XCTAssertEqual(JarvisLogChannel.agent.rawValue, "agent")
        XCTAssertEqual(JarvisLogChannel.tools.rawValue, "tools")
        XCTAssertEqual(JarvisLogChannel.ui.rawValue, "ui")
        XCTAssertEqual(JarvisLogChannel.system.rawValue, "system")
        XCTAssertEqual(JarvisLogChannel.bus.rawValue, "bus")
    }

    func test_C3_newCasesAdded() {
        XCTAssertEqual(JarvisLogChannel.replay.rawValue, "replay")
        XCTAssertEqual(JarvisLogChannel.devoverlay.rawValue, "devoverlay")
        XCTAssertEqual(JarvisLogChannel.mcp.rawValue, "mcp")
    }
}
