import XCTest
@testable import JarvisVision

/// Plan 09-03 / D-13 + D-14 — proves PresenceStateSnapshot stores the latest
/// PresenceEvent + timestamp and renders a plain-sentence enrichment for
/// AgentOrchestrator.runTurn to append to the system prompt.
///
/// VISION-03 boundary: every assertion only inspects `String?` from
/// `currentEnrichment(now:)`. The actor never exposes PresenceEvent values
/// outward, never references TTSEngine or AgentOrchestrator.
final class PresenceStateSnapshotTests: XCTestCase {

    private func makeSnapshot() -> PresenceStateSnapshot {
        PresenceStateSnapshot()
    }

    /// Test 1 — fresh snapshot, no events recorded → nil.
    func testInitialEnrichmentIsNil() async {
        let snap = makeSnapshot()
        let result = await snap.currentEnrichment(now: Date())
        XCTAssertNil(result)
    }

    /// Test 2 — D-14 suppression rule: present + observation < 5s → nil.
    func testPresentLessThanFiveSecondsReturnsNil() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .present, at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(3))
        XCTAssertNil(result, "present + recent observation must suppress per-turn enrichment")
    }

    /// Test 3 — present + observation ≥ 5s → "User is at the desk."
    func testPresentReturnsDeskSentence() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .present, at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(10))
        XCTAssertEqual(result, "User is at the desk.")
    }

    /// Test 4 — D-11's secondary 5-minute threshold not crossed → nil.
    func testAbsentLessThanFiveMinutesReturnsNil() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .absent(since: now), at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(2 * 60))
        XCTAssertNil(result, "absent < 5 minutes should not produce enrichment")
    }

    /// Test 5 — absent for 7 minutes → "User has been away from the desk for 7 minutes."
    func testAbsentSevenMinutesReturnsAwaySentence() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .absent(since: now), at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(7 * 60))
        XCTAssertEqual(result, "User has been away from the desk for 7 minutes.")
    }

    /// Test 6 — absentLongTerm always renders the away sentence.
    func testAbsentLongTermReturnsAwaySentence() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .absentLongTerm(since: now), at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(30 * 60))
        XCTAssertEqual(result, "User has been away from the desk for 30 minutes.")
    }

    /// Test 7 — .unknown sentinel returns nil.
    func testUnknownReturnsNil() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .unknown, at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(60))
        XCTAssertNil(result)
    }

    /// Test 8 — record overwrites prior event (latest-wins snapshot semantics).
    func testRecordOverwritesPriorEvent() async {
        let snap = makeSnapshot()
        let earlier = Date().addingTimeInterval(-100)
        await snap.record(.transition(to: .present, at: earlier, debounced: 2.0))
        let now = Date()
        await snap.record(.transition(to: .absent(since: now), at: now, debounced: 2.0))
        let result = await snap.currentEnrichment(now: now.addingTimeInterval(7 * 60))
        XCTAssertEqual(result, "User has been away from the desk for 7 minutes.",
                       "snapshot must reflect the LATEST recorded event only")
    }

    /// Test 9 — return type is `String?` only. Compile-time check via assignment.
    func testReturnTypeIsStringOnly() async {
        let snap = makeSnapshot()
        let now = Date()
        await snap.record(.transition(to: .present, at: now, debounced: 2.0))
        let result: String? = await snap.currentEnrichment(now: now.addingTimeInterval(10))
        XCTAssertEqual(result, "User is at the desk.")
    }

    /// Round-trip through ContextBuilder.installPresence — proves the wiring
    /// from the AsyncStream<PresenceEvent> drains into the .shared singleton.
    /// (Acceptable shared-singleton use because `installPresence` is the sole
    /// writer in production and we BEFORE/AFTER assert on observable state.)
    func testContextBuilderInstallPresenceWritesToSnapshot() async throws {
        var continuation: AsyncStream<PresenceEvent>.Continuation!
        let stream = AsyncStream<PresenceEvent> { cont in continuation = cont }
        ContextBuilder.installPresence(stream)
        let now = Date()
        continuation.yield(.transition(to: .present, at: now, debounced: 2.0))
        continuation.finish()
        // Allow the detached drain task to process the yield.
        try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
        let enrichment = await PresenceStateSnapshot.shared.currentEnrichment(
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(enrichment, "User is at the desk.")
    }
}
