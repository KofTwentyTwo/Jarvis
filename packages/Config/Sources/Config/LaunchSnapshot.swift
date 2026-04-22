import Foundation

public struct LaunchSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let ollama: OllamaConfig
    public let applescript: AppleScriptPolicy
    public let toolBlocklist: [String]
    public let confirmationPolicy: ConfirmationPolicy
    public let logging: LoggingLaunchConfig
    // SEC-01: secrets live in Keychain only. OBS-05: per-turn fields live in PerTurnSnapshot.
    // See ConfigSplitTests.swift for the reflection-based enforcement.
}
