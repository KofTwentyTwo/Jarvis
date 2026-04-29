import XCTest
@testable import JarvisVision

final class PresenceSignalBusTests: XCTestCase {

    func testPresenceEventEquality() {
        let t = Date(timeIntervalSince1970: 1_745_308_800)
        let a: PresenceEvent = .transition(to: .present, at: t, debounced: 2.0)
        let b: PresenceEvent = .transition(to: .present, at: t, debounced: 2.0)
        let c: PresenceEvent = .transition(to: .absent(since: t), at: t, debounced: 2.0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testBusDeliversInOrder() async {
        let (stream, cont) = AsyncStream<PresenceEvent>.makeStream()
        let bus = PresenceSignalBus(stream: stream)

        let t0 = Date()
        cont.yield(.transition(to: .present, at: t0, debounced: 2.0))
        cont.yield(.transition(to: .absent(since: t0), at: t0.addingTimeInterval(3), debounced: 2.0))
        cont.finish()

        var received: [PresenceEvent] = []
        for await ev in bus.stream { received.append(ev) }

        XCTAssertEqual(received.count, 2)
        if case .transition(to: .present, _, _) = received[0] {} else { XCTFail("expected .present first") }
        if case .transition(to: .absent, _, _) = received[1] {} else { XCTFail("expected .absent second") }
    }
}
