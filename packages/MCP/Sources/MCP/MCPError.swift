// MCPError.swift
//
// Error surface for the JarvisMCP layer. Distinct from the SDK's `MCPError`
// type (which lives in the imported `MCP` module) — ours is named
// `JarvisMCPError` to make the boundary obvious at consumer sites.
//
// Plan: 05-01

import Foundation

/// Errors raised by the JarvisMCP wrapper around the MCP Swift SDK.
///
/// - `helperMissing`: a `callTool` was issued for a name that isn't in the registry.
/// - `helperMissingToolsCapability`: the helper completed initialize but did not
///   advertise the `tools` capability.
/// - `startupTimeout`: the helper subprocess did not complete the initialize
///   handshake within the configured deadline.
/// - `serverCrashed`: the helper subprocess exited or was killed while a
///   call was pending; in-flight callers receive this error.
/// - `spawnFailed`: `Process.run()` itself failed (e.g., binary missing on disk).
public enum JarvisMCPError: Error, Sendable, Equatable, LocalizedError {
    case helperMissing(name: String)
    case helperMissingToolsCapability(name: String)
    case startupTimeout(name: String, seconds: Int)
    case serverCrashed(name: String)
    case spawnFailed(name: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing(let name):
            return "MCP helper '\(name)' is not registered."
        case .helperMissingToolsCapability(let name):
            return "MCP helper '\(name)' does not advertise the tools capability."
        case .startupTimeout(let name, let seconds):
            return "MCP helper '\(name)' did not complete initialize within \(seconds)s."
        case .serverCrashed(let name):
            return "MCP helper '\(name)' crashed while a call was pending."
        case .spawnFailed(let name, let underlying):
            return "Failed to spawn MCP helper '\(name)': \(underlying)"
        }
    }
}
