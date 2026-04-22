import XCTest
@testable import Jarvis
@testable import Keychain
@testable import Shell

@MainActor
final class WizardStateTests: XCTestCase {
    /// `@unchecked Sendable`: fields are `let`, but `KeychainStore` requires
    /// `Sendable` conformance on an otherwise-struct type that our fake
    /// implements as a class is unnecessary. Struct is fine.
    private struct FakeKeychain: KeychainStore {
        let apiKeyStored: Bool
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String {
            guard apiKeyStored else { throw KeychainError.itemNotFound }
            return "sk-ant-fake"
        }
        func delete(_ item: KeychainItem) throws {}
    }

    func test_firstUnresolvedStageIsAPIKeyWhenEmpty() {
        let state = WizardState(keychain: FakeKeychain(apiKeyStored: false))
        XCTAssertEqual(state.firstUnresolvedStage, .apiKey)
    }

    func test_firstUnresolvedStageIsTCCWhenAPIKeyStored() {
        let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
        state.inputMonitoringProbed = false
        XCTAssertEqual(state.firstUnresolvedStage, .tcc)
    }

    func test_firstUnresolvedStageIsHotkeyWhenTCCDone() {
        let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
        state.inputMonitoringProbed = true
        state.hotkey = nil
        XCTAssertEqual(state.firstUnresolvedStage, .hotkey)
    }

    func test_firstUnresolvedStageIsCompleteWhenAllDone() {
        let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
        state.inputMonitoringProbed = true
        state.hotkey = Shell.KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift])
        XCTAssertEqual(state.firstUnresolvedStage, .complete)
    }
}
