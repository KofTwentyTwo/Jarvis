import XCTest
import AgentCore
import AgentOrchestrator
@testable import DevOverlay

@MainActor
final class DevOverlayViewModelTests: XCTestCase {
    // VM1: ViewModel initializes with `.initial`.
    func test_VM1_initializesWithInitialSnapshot() {
        let vm = DevOverlayViewModel()
        XCTAssertEqual(vm.snapshot, DevSnapshot.initial)
    }

    // VM2: `.apply` overwrites the snapshot (emitter owns the windowing).
    func test_VM2_applyOverwrites() {
        let vm = DevOverlayViewModel()
        let rows1 = [
            ToolCallRow(id: "t1", name: "a", status: .completed, durationMs: 10, preview: nil),
            ToolCallRow(id: "t2", name: "b", status: .completed, durationMs: 20, preview: nil),
        ]
        vm.apply(DevSnapshot.initial.with(toolCalls: rows1))
        XCTAssertEqual(vm.snapshot.toolCalls.count, 2)

        let rows2 = [
            ToolCallRow(id: "t3", name: "c", status: .completed, durationMs: 30, preview: nil),
            ToolCallRow(id: "t4", name: "d", status: .completed, durationMs: 40, preview: nil),
            ToolCallRow(id: "t5", name: "e", status: .completed, durationMs: 50, preview: nil),
        ]
        vm.apply(DevSnapshot.initial.with(toolCalls: rows2))
        XCTAssertEqual(vm.snapshot.toolCalls.count, 3)
        XCTAssertEqual(vm.snapshot.toolCalls.map(\.id), ["t3", "t4", "t5"])
    }

    // VM3: reset returns to `.initial`.
    func test_VM3_resetReturnsToInitial() {
        let vm = DevOverlayViewModel()
        vm.apply(DevSnapshot.initial.with(state: .thinking, outputTokens: 42))
        XCTAssertEqual(vm.snapshot.outputTokens, 42)
        vm.reset()
        XCTAssertEqual(vm.snapshot, DevSnapshot.initial)
    }

    // VM4: Draining a channel via `for await` lands 5 consecutive snapshots;
    // the final `snapshot` matches the 5th.
    func test_VM4_channelDrainLandsAllSnapshots() async {
        let vm = DevOverlayViewModel()
        let channel = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)

        let snaps = (1...5).map { i in
            DevSnapshot.initial.with(state: .thinking, outputTokens: i * 10)
        }

        // Drain task mirrors DevOverlayBridge semantics.
        let drain = Task { @MainActor in
            var count = 0
            for await snap in channel {
                vm.apply(snap)
                count += 1
                if count == 5 { break }
            }
        }

        for snap in snaps {
            await channel.send(snap)
        }

        await drain.value
        XCTAssertEqual(vm.snapshot.outputTokens, 50)
    }
}
