import XCTest
import Foundation
@testable import JarvisVision
import JarvisChildSpawn

/// Plan 07-05 / Task 4 — vllm-mlx sidecar lifecycle invariants.
///
/// Three behaviors verified:
/// 1. `VllmMlxSidecar.start()` invokes `ChildSpawnGate.shared.prepare()`
///    BEFORE the Process factory runs (FD_CLOEXEC sweep ordering).
/// 2. `proc.environment` equals `ChildSpawnGate.minimalEnvironment` byte-for-byte
///    (the dictionary `["PATH": "/usr/bin:/bin"]`).
/// 3. `VllmMlxAvailability.isAvailable()` returns `false` when the configured
///    binary path doesn't exist.
final class VllmMlxSidecarSpawnTests: XCTestCase {

    func testChildSpawnGatePrepareIsCalledBeforeProcessRun() async throws {
        let order = OrderRecorder()
        let factory: VllmMlxSidecar.ProcessFactory = { config in
            // Inside the factory invocation we record the order.
            await order.append("factory")
            return FakeProcessHandle(config: config, recorder: order)
        }
        let gateAdapter = FakeChildSpawnGateAdapter(recorder: order)
        let cfg = VllmMlxSidecar.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/fake-vllm-mlx"),
            modelID: "Qwen/Qwen3.5-35B-A3B-VL",
            port: 8001,
            healthTimeout: .seconds(0.05),  // tiny — we expect timeout
            healthProber: { _ in false }    // never healthy → timeout
        )
        let sidecar = VllmMlxSidecar(
            configuration: cfg,
            processFactory: factory,
            spawnGate: gateAdapter
        )
        do {
            try await sidecar.start()
            XCTFail("expected sidecarStartupTimeout")
        } catch VisionError.sidecarStartupTimeout {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let recorded = await order.events
        // Ordering invariant: prepare() recorded BEFORE factory.
        XCTAssertEqual(recorded.first, "prepare",
            "ChildSpawnGate.prepare must precede Process factory invocation")
        XCTAssertTrue(recorded.contains("factory"),
            "Process factory must be invoked")
        if let prepIdx = recorded.firstIndex(of: "prepare"),
           let factIdx = recorded.firstIndex(of: "factory") {
            XCTAssertLessThan(prepIdx, factIdx, "prepare before factory")
        }
    }

    func testProcessEnvironmentMatchesMinimalEnvironmentByteForByte() async throws {
        let order = OrderRecorder()
        var capturedEnv: [String: String]? = nil
        let envBox = EnvBox()
        let factory: VllmMlxSidecar.ProcessFactory = { config in
            await envBox.set(config.environment)
            return FakeProcessHandle(config: config, recorder: order)
        }
        let gateAdapter = FakeChildSpawnGateAdapter(recorder: order)
        let cfg = VllmMlxSidecar.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/fake-vllm-mlx"),
            modelID: "Qwen/Qwen3.5-35B-A3B-VL",
            port: 8001,
            healthTimeout: .seconds(0.05),
            healthProber: { _ in false }
        )
        let sidecar = VllmMlxSidecar(
            configuration: cfg,
            processFactory: factory,
            spawnGate: gateAdapter
        )
        do {
            try await sidecar.start()
        } catch {
            // expected timeout — env capture happens before
        }
        capturedEnv = await envBox.value
        XCTAssertEqual(capturedEnv, ChildSpawnGate.minimalEnvironment,
            "spawned process environment must equal ChildSpawnGate.minimalEnvironment exactly")
    }

    func testHealthProbeTimeoutSurfacesAsSidecarStartupTimeout() async throws {
        let order = OrderRecorder()
        let factory: VllmMlxSidecar.ProcessFactory = { config in
            FakeProcessHandle(config: config, recorder: order)
        }
        let gateAdapter = FakeChildSpawnGateAdapter(recorder: order)
        let cfg = VllmMlxSidecar.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/fake-vllm-mlx"),
            modelID: "Qwen/Qwen3.5-35B-A3B-VL",
            port: 8001,
            healthTimeout: .seconds(0.05),
            healthProber: { _ in false }
        )
        let sidecar = VllmMlxSidecar(
            configuration: cfg,
            processFactory: factory,
            spawnGate: gateAdapter
        )
        do {
            try await sidecar.start()
            XCTFail("expected sidecarStartupTimeout")
        } catch VisionError.sidecarStartupTimeout {
            // ok
        }
    }

    func testAvailabilityReturnsFalseWhenBinaryMissing() {
        let cfg = VllmMlxAvailability.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)"),
            featureFlagEnabled: true
        )
        XCTAssertFalse(VllmMlxAvailability.isAvailable(configuration: cfg))
    }

    func testAvailabilityReturnsFalseWhenFeatureFlagDisabled() throws {
        // Use any path that exists (e.g., /usr/bin/true) and disable the flag.
        let cfg = VllmMlxAvailability.Configuration(
            binaryURL: URL(fileURLWithPath: "/usr/bin/true"),
            featureFlagEnabled: false
        )
        XCTAssertFalse(VllmMlxAvailability.isAvailable(configuration: cfg))
    }
}

// MARK: - Test fakes

private actor OrderRecorder {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor EnvBox {
    var value: [String: String]? = nil
    func set(_ v: [String: String]?) { value = v }
}

private struct FakeChildSpawnGateAdapter: VllmMlxSidecar.SpawnGate {
    let recorder: OrderRecorder
    func prepare() async throws {
        await recorder.append("prepare")
    }
}

private final class FakeProcessHandle: VllmMlxSidecar.ProcessHandle, @unchecked Sendable {
    let config: VllmMlxSidecar.SpawnConfig
    let recorder: OrderRecorder

    init(config: VllmMlxSidecar.SpawnConfig, recorder: OrderRecorder) {
        self.config = config
        self.recorder = recorder
    }

    func run() throws {
        // Fakes don't actually run; the test asserts spawn config invariants
        // were captured before run() was even called.
    }

    func terminate() {}

    var isRunning: Bool { false }
}
