// TransportMode.swift
//
// UQ-5 LOCKED: every harness scenario runs in two transport modes —
// direct Swift actor calls and JSON round-trip through a real WKWebView —
// so B-03-class bugs (webview emit lost en route to AppDelegate) become
// reproducible without a real user click.
//
// See JARVIS-API-TEST-CONTRACT.md §9 "Transport equivalence".

import Foundation

/// The transport surface a harness scenario exercises.
///
/// `ScenarioRunner.run(_:in:)` parametrizes most scenarios across both modes.
/// Mode-restricted scenarios declare exceptions explicitly (test contract §9).
public enum TransportMode: String, Sendable, CaseIterable {
    /// Direct Swift actor calls. Cheap, fast, no encoding overhead.
    /// Used by the eval harness CLI and unit-style scenarios that don't need
    /// transport equivalence.
    case inProcessActor

    /// Encodes Commands as JSON, drives a real WKWebView via the
    /// `RealWKWebViewIntegrationTests` substrate, reads Events back through
    /// `WKScriptMessageHandler`. Catches B-03-class regressions.
    case jsonRoundTripWebView
}

/// Indicates a scenario produced different event sequences under different transport modes.
/// Reported by `ScenarioRunner` after running both modes for a single scenario.
public struct TransportDivergenceError: Error, Sendable {
    public let scenarioId: String
    public let actorEventsCount: Int
    public let jsonEventsCount: Int
    public let firstDivergenceIndex: Int?
    public let summary: String

    public init(
        scenarioId: String,
        actorEventsCount: Int,
        jsonEventsCount: Int,
        firstDivergenceIndex: Int?,
        summary: String
    ) {
        self.scenarioId = scenarioId
        self.actorEventsCount = actorEventsCount
        self.jsonEventsCount = jsonEventsCount
        self.firstDivergenceIndex = firstDivergenceIndex
        self.summary = summary
    }
}
