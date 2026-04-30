import ArgumentParser
import Foundation
import Harness

/// `jarvis-eval` CLI entry — Phase 8 evaluation harness.
///
/// Plan 08-01 Task 1 ships the shell + `--help` text. Real subcommands land in
/// Task 3 of this plan (`replay`) and across plans 08-02 / 08-03 / 08-04.
@main
struct JarvisEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jarvis-eval",
        abstract: "Phase 8 evaluation harness",
        subcommands: []
    )
}
