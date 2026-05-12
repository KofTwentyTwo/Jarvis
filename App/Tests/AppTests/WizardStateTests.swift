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

    // MARK: - #87 / VOICE-13 — PTT hotkey persistence

    /// PTT hotkey defaults to nil (ships unbound per CLAUDE.md hotkey
    /// hygiene — Cmd+Shift+J collides with Chrome/Slack/VSCode and
    /// Option+Space collides with Alfred/Raycast).
    func test_pttHotkeyDefaultsToNil() {
        let defaults = UserDefaults(suiteName: "PTTHotkeyTest-\(UUID().uuidString)")!
        defaults.removeObject(forKey: "Jarvis.pttHotkey")
        let state = WizardState(
            keychain: FakeKeychain(apiKeyStored: false),
            userDefaults: defaults
        )
        XCTAssertNil(state.pttHotkey, "#87: PTT hotkey ships unbound")
    }

    /// PTT hotkey persists to UserDefaults under its own key, independent
    /// of the summon-Jarvis hotkey.
    func test_pttHotkeyPersistsAndReloads() {
        let suite = "PTTHotkeyTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let shortcut = Shell.KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])

        let writer = WizardState(
            keychain: FakeKeychain(apiKeyStored: true),
            userDefaults: defaults
        )
        writer.pttHotkey = shortcut

        // Distinct WizardState instance reads the same UserDefaults suite
        // and must see the persisted PTT hotkey.
        let reader = WizardState(
            keychain: FakeKeychain(apiKeyStored: true),
            userDefaults: defaults
        )
        XCTAssertEqual(reader.pttHotkey, shortcut, "#87: PTT hotkey must round-trip through UserDefaults")
    }

    /// PTT and summon-Jarvis hotkeys are independent — clearing one does
    /// not affect the other.
    func test_pttHotkeyIsIndependentOfSummonHotkey() {
        let suite = "PTTHotkeyTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = WizardState(
            keychain: FakeKeychain(apiKeyStored: true),
            userDefaults: defaults
        )
        let summon = Shell.KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift])
        let ptt = Shell.KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])
        state.hotkey = summon
        state.pttHotkey = ptt
        state.hotkey = nil
        XCTAssertNil(state.hotkey)
        XCTAssertEqual(state.pttHotkey, ptt, "#87: clearing summon hotkey must not affect PTT hotkey")
    }
}
