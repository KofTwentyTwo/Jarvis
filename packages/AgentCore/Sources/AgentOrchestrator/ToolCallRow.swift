import Foundation

/// One row in the DevOverlay's "last 5 tool calls" table (OBS-01).
///
/// `id` == the `toolUseId` from the provider; the emitter dedupes on this
/// so repeated `.toolCardUpdate` events for the same tool_use update the
/// existing row rather than pushing a new one. `preview` is capped at 200
/// characters upstream (`ToolCardUpdate.resultPreview`, Plan 04-04).
public struct ToolCallRow: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case pending
        case running
        case completed
        case failed
        case awaitingApproval
    }

    public let id: String
    public let name: String
    public let status: Status
    public let durationMs: Int
    public let preview: String?
    public let error: String?

    public init(
        id: String,
        name: String,
        status: Status,
        durationMs: Int,
        preview: String?,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.durationMs = durationMs
        self.preview = preview
        self.error = error
    }
}
