import Foundation

/// One tool definition advertised to the LLM in a request.
///
/// `inputSchema` is a JSON-schema blob passed through verbatim to the
/// provider. Each provider's `RequestBody` encoder decodes the bytes back to
/// a JSON object (so Anthropic doesn't double-encode the schema as a string)
/// and re-emits it inline as the `input_schema` field.
public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: Data

    public init(name: String, description: String, inputSchema: Data) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
