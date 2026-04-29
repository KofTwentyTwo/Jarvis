import XCTest
import AppKit
@testable import JarvisVision

@MainActor
final class DisablePresenceTests: XCTestCase {

    private static let key = "features.vision.presenceDisabled"

    private func ephemeralDefaults() -> UserDefaults {
        // Use a per-test suite name so tests do not contaminate each other
        // or the user's actual defaults.
        let suite = "DisablePresenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testInitReadsPersistedDisabledState() async throws {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: Self.key)

        let (stream, _) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        let menu = NSMenu()
        let toggle = DisablePresence(presenceMonitor: monitor, menuBarMenu: menu, defaults: defaults)

        XCTAssertTrue(toggle.isDisabled)
        XCTAssertEqual(menu.items.first?.state, .on)
        // Pause is fire-and-forget Task; spin once to let it apply.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Internal-state observability is covered transitively by
        // testToggleFlipsStateAndPersists below.
    }

    func testInitReadsPersistedEnabledState() async throws {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: Self.key)

        let (stream, _) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        let menu = NSMenu()
        let toggle = DisablePresence(presenceMonitor: monitor, menuBarMenu: menu, defaults: defaults)

        XCTAssertFalse(toggle.isDisabled)
        XCTAssertEqual(menu.items.first?.state, .off)
    }

    func testToggleFlipsStateAndPersists() async throws {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: Self.key)

        let (stream, _) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        let menu = NSMenu()
        let toggle = DisablePresence(presenceMonitor: monitor, menuBarMenu: menu, defaults: defaults)

        XCTAssertFalse(toggle.isDisabled)

        toggle.toggleForTest()
        XCTAssertTrue(toggle.isDisabled)
        XCTAssertTrue(defaults.bool(forKey: Self.key))
        XCTAssertEqual(menu.items.first?.state, .on)

        toggle.toggleForTest()
        XCTAssertFalse(toggle.isDisabled)
        XCTAssertFalse(defaults.bool(forKey: Self.key))
        XCTAssertEqual(menu.items.first?.state, .off)
    }

    /// D-12 invariant: DisablePresence touches PresenceMonitor only.
    /// CameraCapture lifecycle is untouched (frame-attach remains usable).
    /// Verified by static grep in this test process.
    func testDisablePresenceDoesNotTouchCameraCapture() throws {
        // Locate the source file relative to this test file.
        // Walk up until we find packages/Vision/Sources/Vision/DisablePresence.swift.
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir
                .appendingPathComponent("Sources")
                .appendingPathComponent("Vision")
                .appendingPathComponent("DisablePresence.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let source = try String(contentsOf: candidate, encoding: .utf8)
                // Strip comment lines so doc comments mentioning the rule
                // do not trigger.
                let nonComment = source
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                XCTAssertFalse(nonComment.contains("CameraCapture"),
                               "D-12: DisablePresence must not reference CameraCapture (frame-attach remains live).")
                return
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("Could not locate DisablePresence.swift")
    }
}
