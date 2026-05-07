// Placeholder.swift
//
// Phase 5 ships type-signatures only. Test scenarios are implemented during
// the migration (M-0 .. M-7) per JARVIS-API-MIGRATION-PLAN.md. This file
// exists solely so the JarvisDiagTests target has a source file to compile.
//
// Do NOT add scenario implementations here at Phase 5. Migration plan owns
// the lift sequence.

import XCTest
@testable import JarvisDiag

final class JarvisDiagSkeletonPresenceTest: XCTestCase {
    func testHarnessTypeExists() {
        // Compile-only smoke: prove top-level types are exported.
        let _: TransportMode = .inProcessActor
        let _: ScenarioMode = .both
        XCTAssertEqual(TransportMode.allCases.count, 2)
    }
}
