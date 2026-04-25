// MCPLogChannel.swift
//
// Centralized logger factory for the JarvisMCP layer. Every log line written
// from this package routes through `MCPLogChannel.logger(label:)` so we can
// reason about provenance with a single grep.
//
// Plan: 05-01

import Logging

public enum MCPLogChannel {
    /// Returns a logger labeled `jarvis.mcp.<label>`. Examples:
    /// - `jarvis.mcp.spawngate`
    /// - `jarvis.mcp.client`
    /// - `jarvis.mcp.client.<server-name>`
    /// - `jarvis.mcp.stderr.<server-name>`
    public static func logger(label: String) -> Logger {
        Logger(label: "jarvis.mcp.\(label)")
    }
}
