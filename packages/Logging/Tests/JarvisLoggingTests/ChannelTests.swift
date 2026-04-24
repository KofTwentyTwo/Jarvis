import XCTest
@testable import JarvisLogging

/// Targeted assertions for the channel additions in Plan 04-03. The full
/// 7-channel set is also covered by `test_sevenChannelsAreDefined` in
/// `LoggingTests`, but the targeted tests below are here to make the new
/// cases discoverable from the file name alone.
final class ChannelTests: XCTestCase {
    func test_C1_sevenCases() {
        XCTAssertEqual(JarvisLogChannel.allCases.count, 7)
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
    }
}
