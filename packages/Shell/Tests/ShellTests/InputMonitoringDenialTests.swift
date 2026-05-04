import XCTest
@testable import Shell

@MainActor
final class InputMonitoringDenialTests: XCTestCase {
    private struct MockProbe: HIDAccessProbe {
        let granted: Bool
        func requestListenEventAccess() -> Bool { granted }
    }

    /// `@unchecked Sendable`: `enqueueCount` is `var` (required by the
    /// Sendable protocol), but every interaction in these @MainActor-bound
    /// tests happens on the main thread, so there's no actual data race.
    /// Test-fixture-only escape hatch, not production code.
    private final class MockSink: InputMonitoringProbe.BannerSink, @unchecked Sendable {
        var enqueueCount = 0
        func enqueueInputMonitoringDenied() { enqueueCount += 1 }
    }

    func test_bannerEnqueuedOnDenial() {
        let probe = InputMonitoringProbe(probe: MockProbe(granted: false))
        let sink = MockSink()
        let result = probe.check(sink: sink)
        XCTAssertFalse(result, "check() returns false on denial")
        XCTAssertEqual(
            sink.enqueueCount, 1,
            "SHELL-06: denial must enqueue exactly one banner — silent no-op is forbidden"
        )
    }

    func test_noBannerWhenGranted() {
        let probe = InputMonitoringProbe(probe: MockProbe(granted: true))
        let sink = MockSink()
        let result = probe.check(sink: sink)
        XCTAssertTrue(result)
        XCTAssertEqual(sink.enqueueCount, 0, "grant must not enqueue any banner")
    }

    // SHELL-06 local-monitor fallback is exercised via
    // `HotkeyBinder.bind(_, inputMonitoringGranted: false)` in
    // `HotkeyBindingTests`. The previous `test_localMonitorOnlyFallback`
    // was a pointer-to-design `XCTAssertTrue(true)` test removed in the
    // 2026-05-04 cleanup batch (`.planning/audit-2026-05-03/tests-audit.md`).
}
