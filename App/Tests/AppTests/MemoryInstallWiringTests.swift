// MemoryInstallWiringTests.swift
//
// Track-D D-1 regression: `installMemory` must NOT short-circuit
// extractor / orchestrator / coordinator construction when MemoryStore.init
// fails (today's reality on every cold launch — vec0.dylib is a 2-line
// placeholder, libsqlite3 is symbol-stripped, MemoryStore.init throws).
//
// Pre-D-1 behavior: a single `return` at the catch site after store init
// failure left `memoryExtractionOrchestrator == nil` AND
// `memoryExtractionCoordinator == nil` for the whole process — which made
// the .turnEnd subscriber a no-op AND meant nothing about memory extraction
// was observable in system log.
//
// Post-D-1: store nil, but orchestrator + coordinator are constructed. The
// applyOp closure routes to a debug log when there's no store.

import XCTest
@testable import Jarvis
@testable import Keychain
@testable import Config
@testable import Memory
@testable import JarvisMCP

@MainActor
final class MemoryInstallWiringTests: XCTestCase {

    private struct EntitlementYes: EntitlementGateProbe { func isVerified() -> Bool { true } }

    private struct FakeKeychain: KeychainStore {
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String { "sk-ant-fake" }
        func delete(_ item: KeychainItem) throws {}
    }

    private struct FakeHIDProbe: HIDAccessProbe {
        func requestListenEventAccess() -> Bool { true }
    }

    private func cleanUp(_ delegate: AppDelegate) {
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate.wizardController?.close()
    }

    /// D-1: when MemoryStore.init throws (vec0.dylib unavailable on this host
    /// — the production reality), the early-return cascade is gone:
    /// `memoryExtractionOrchestrator` AND `memoryExtractionCoordinator` MUST
    /// both be non-nil. `memoryStore` stays nil and `memorySearchAvailable`
    /// stays false.
    func test_D1_extractorAndCoordinatorConstructWhenVecFails() async {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.keychainStore = FakeKeychain()

        // Drive installMemory directly. Today, vec0.dylib is a placeholder
        // text file (Resources/PLACEHOLDER.txt) and macOS's libsqlite3 strips
        // sqlite3_enable_load_extension — so MemoryStore.init throws on every
        // host. That's exactly the failure path we need to exercise.
        await delegate.installMemory()

        // D-1 invariants:
        XCTAssertNil(delegate.memoryStore,
                     "Pre-D-5 reality: MemoryStore.init should fail (vec0 dylib placeholder)")
        XCTAssertFalse(delegate.memorySearchAvailable,
                       "memorySearchAvailable must be false when store is nil")
        XCTAssertNotNil(delegate.memoryExtractionOrchestrator,
                        "D-1 fix: orchestrator must construct even when vec fails")
        XCTAssertNotNil(delegate.memoryExtractionCoordinator,
                        "D-1 fix: coordinator must construct even when vec fails")

        cleanUp(delegate)
    }

    /// D-2: when MemoryStore.init fails (today's reality), neither
    /// SearchMemoryTool nor ForgetFactTool registers — they have no DB
    /// to dispatch against. The registry itself IS constructed (empty).
    func test_D2_noToolsRegisteredWhenStoreUnavailable() async {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.keychainStore = FakeKeychain()

        await delegate.installMemory()

        XCTAssertNil(delegate.memoryStore, "Production reality: store nil on every host")
        XCTAssertNotNil(delegate.inProcessToolRegistry,
                        "D-2: registry constructs unconditionally")
        let tools = await delegate.inProcessToolRegistry?.registered() ?? []
        let names = Set(tools.map { $0.name })
        XCTAssertFalse(names.contains("forget_fact"),
                       "D-2: forget_fact must not register when store is nil (writes need DB)")
        XCTAssertFalse(names.contains("search_memory"),
                       "D-2: search_memory must not register when search unavailable (reads need DB + vec)")

        cleanUp(delegate)
    }

    // MARK: - D-2 positive paths via test seam

    private struct StubForget: ForgetFactDispatching {
        func forgetFact(id: Int64, triggerTurnId: Int64) async throws -> Bool { false }
    }
    private struct StubHybrid: HybridSearchDispatching {
        func searchFacts(query: String, k: Int, triggerTurnId: Int64) async throws -> [SearchMemoryHit] { [] }
    }

    /// D-2: both dispatchers present → both tools register.
    func test_D2_bothToolsRegisterWhenBothDispatchersPresent() async {
        let registry = await AppDelegate.buildInProcessToolRegistry(
            forgetDispatcher: StubForget(),
            searchDispatcher: StubHybrid()
        )
        let names = Set(await registry.registered().map { $0.name })
        XCTAssertTrue(names.contains("forget_fact"))
        XCTAssertTrue(names.contains("search_memory"))
    }

    /// D-2: store ok but search unavailable → forget registers, search does not.
    func test_D2_onlyForgetRegistersWhenSearchUnavailable() async {
        let registry = await AppDelegate.buildInProcessToolRegistry(
            forgetDispatcher: StubForget(),
            searchDispatcher: nil
        )
        let names = Set(await registry.registered().map { $0.name })
        XCTAssertTrue(names.contains("forget_fact"),
                      "D-2: forget_fact registers when store exists")
        XCTAssertFalse(names.contains("search_memory"),
                       "D-2: search_memory gated on searchAvailable")
    }

    /// D-2: nothing wired (store nil) → empty registry.
    func test_D2_emptyRegistryWhenBothDispatchersNil() async {
        let registry = await AppDelegate.buildInProcessToolRegistry(
            forgetDispatcher: nil,
            searchDispatcher: nil
        )
        let names = Set(await registry.registered().map { $0.name })
        XCTAssertEqual(names, [], "D-2: empty registry when no dispatchers — neither tool registers")
    }
}
