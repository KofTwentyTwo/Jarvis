import XCTest
import Config
@testable import Jarvis

/// Local-first LLM routing (Task 9 / spec §6) — asserts the
/// `ProviderMode.from(provider:, escalationEnabled:)` mapping that
/// backs the Settings provider picker:
///
///   .ollama    + true  → .localFirst
///   .anthropic + *     → .anthropicOnly (escalation moot, pinned)
///   .ollama    + false → .ollamaOnly
final class ProviderModeTests: XCTestCase {
    func test_provider_mode_mapping_canonical() {
        XCTAssertEqual(
            ProviderMode.from(provider: .ollama, escalationEnabled: true),
            .localFirst
        )
        XCTAssertEqual(
            ProviderMode.from(provider: .anthropic, escalationEnabled: false),
            .anthropicOnly
        )
        XCTAssertEqual(
            ProviderMode.from(provider: .ollama, escalationEnabled: false),
            .ollamaOnly
        )
    }

    /// `escalationEnabled` is moot when provider is `.anthropic` because
    /// escalation is an Ollama→Anthropic-only fallback. Both inputs
    /// collapse to `.anthropicOnly` so the picker shows a consistent
    /// mode regardless of historical/migrated state.
    func test_anthropic_with_escalation_true_normalizes_to_anthropic_only() {
        XCTAssertEqual(
            ProviderMode.from(provider: .anthropic, escalationEnabled: true),
            .anthropicOnly
        )
    }

    /// The `pair` accessor must round-trip back to the same mode via
    /// `from(...)`. Guards against an asymmetric edit in either direction.
    func test_pair_round_trips_through_from() {
        for mode in ProviderMode.allCases {
            let pair = mode.pair
            let roundTripped = ProviderMode.from(
                provider: pair.provider,
                escalationEnabled: pair.escalationEnabled
            )
            XCTAssertEqual(roundTripped, mode, "round-trip failed for \(mode)")
        }
    }
}
