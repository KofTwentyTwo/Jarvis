import XCTest
import AgentCore
import AgentOrchestrator
@testable import DevOverlay

@MainActor
final class DevOverlayBridgeTests: XCTestCase {
    // BR1: Attach → channel sends reach the view-model.
    func test_BR1_attachPumpsSnapshots() async {
        let vm = DevOverlayViewModel()
        let bridge = DevOverlayBridge(viewModel: vm)
        let channel = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)

        bridge.attach(channel: channel)

        let target = DevSnapshot.initial.with(state: .thinking, outputTokens: 77)
        await channel.send(target)

        // Give the subscriber task a few hops to land the apply.
        try? await waitUntil(timeout: 1.0) {
            await MainActor.run { vm.snapshot.outputTokens == 77 }
        }

        XCTAssertEqual(vm.snapshot.outputTokens, 77)
        bridge.detach()
    }

    // BR2: After detach, subsequent sends do not reach the view-model.
    func test_BR2_detachStopsPumping() async {
        let vm = DevOverlayViewModel()
        let bridge = DevOverlayBridge(viewModel: vm)
        let channel = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)

        bridge.attach(channel: channel)
        await channel.send(DevSnapshot.initial.with(outputTokens: 11))
        try? await waitUntil(timeout: 1.0) {
            await MainActor.run { vm.snapshot.outputTokens == 11 }
        }
        XCTAssertEqual(vm.snapshot.outputTokens, 11)

        bridge.detach()

        // After detach, the subscriber task is cancelled. Mark the channel
        // finished so any pending receive (which there shouldn't be) wakes
        // cleanly; then send another snapshot into a fresh channel so we know
        // the detached bridge no longer forwards.
        let stale = DevSnapshot.initial.with(outputTokens: 999)
        await channel.send(stale)
        // Give time for any wayward task to fire.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertEqual(vm.snapshot.outputTokens, 11, "view-model must NOT have received the post-detach snapshot")
    }

    // BR3: Attach twice cancels the first subscriber.
    func test_BR3_reattachCancelsPrevious() async {
        let vm = DevOverlayViewModel()
        let bridge = DevOverlayBridge(viewModel: vm)
        let first = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)
        let second = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)

        bridge.attach(channel: first)
        bridge.attach(channel: second)

        // Sending into the old channel should not update the vm.
        await first.send(DevSnapshot.initial.with(outputTokens: 111))
        await second.send(DevSnapshot.initial.with(outputTokens: 222))

        try? await waitUntil(timeout: 1.0) {
            await MainActor.run { vm.snapshot.outputTokens == 222 }
        }

        XCTAssertEqual(vm.snapshot.outputTokens, 222)
        bridge.detach()
    }

    // Utility: poll a condition until it's true or timeout elapses.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @Sendable @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}
