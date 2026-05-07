// ScenarioRunner.swift
//
// UQ-5 LOCKED: every harness scenario runs in two transport modes (actor + json)
// by default. This runner wraps each scenario closure in a parametric driver,
// records both event sequences, and asserts equivalence per §9 of the test
// contract. Mode-restricted scenarios (`.actorOnly`, `.jsonOnly`) bypass one mode.
//
// See JARVIS-API-TEST-CONTRACT.md §9 "Transport equivalence".

import Foundation

/// Mode policy for a scenario. Default `.both`.
public enum ScenarioMode: Sendable {
    case both                    // run in .inProcessActor and .jsonRoundTripWebView
    case actorOnly(reason: String)
    case jsonOnly(reason: String)

    public var modes: [TransportMode] {
        switch self {
        case .both: return TransportMode.allCases
        case .actorOnly: return [.inProcessActor]
        case .jsonOnly: return [.jsonRoundTripWebView]
        }
    }
}

/// A scenario specification — id, mode policy, and the closure that drives it.
public struct Scenario: Sendable {
    public let id: String              // matches §4 ID, e.g. "T-001", "X-003", "B02-fix"
    public let title: String
    public let mode: ScenarioMode
    public let body: @Sendable (JarvisTestHarness) async throws -> Void

    public init(
        id: String,
        title: String,
        mode: ScenarioMode = .both,
        body: @escaping @Sendable (JarvisTestHarness) async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.body = body
    }
}

/// Parametric scenario runner. Drives every scenario in §4 of the test contract
/// across the modes its `ScenarioMode` allows; reports `TransportDivergenceError`
/// when an actor-mode and json-mode run produce different event sequences.
public actor ScenarioRunner {
    public init(
        clock: APIClock,
        providerOverrides: ProviderOverrides = .deterministicDefaults()
    ) {
        // IMPL: store collaborators; create one harness per mode lazily
        fatalError("not implemented — IMPL: ScenarioRunner.init (M-0)")
    }

    /// Run a single scenario across all modes its policy allows.
    /// Records each mode's event sequence; asserts equivalence per §7.1 / §9.
    public func run(_ scenario: Scenario) async throws {
        // IMPL: for mode in scenario.mode.modes:
        //   harness = JarvisTestHarness(transport: mode, clock, overrides)
        //   record events; invoke scenario.body(harness)
        //   harness.shutdown()
        // diff event sequences; throw TransportDivergenceError on divergence
        fatalError("not implemented — IMPL: ScenarioRunner.run (M-0)")
    }

    /// Run a batch — typically the full §4 catalog.
    public func runAll(_ scenarios: [Scenario]) async throws {
        // IMPL: for s in scenarios { try await run(s) } collecting failures
        fatalError("not implemented — IMPL: ScenarioRunner.runAll (M-0)")
    }
}
