import Foundation
import AgentCore

/// Synthetic MCP-style tool schema offered to the extractor's LLM call.
///
/// The model is expected to call `apply_memory_ops` with a structured
/// argsJSON payload; the extractor parses it via
/// `MemoryOp.parseApplyMemoryOps`.
public enum MemoryTools {

    public static let toolName: String = "apply_memory_ops"

    /// RESEARCH §5 JSON Schema (encoded as `Data` for `ToolSchema.inputSchema`).
    public static let applyMemoryOps: ToolSchema = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "ops": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "op": ["type": "string", "enum": ["ADD", "UPDATE", "NOOP"]],
                            "subject": ["type": "string"],
                            "predicate": ["type": "string"],
                            "object": ["type": "string"],
                            "supersedes_fact_id": ["type": "integer"],
                        ],
                        "required": ["op"],
                    ],
                ],
            ],
            "required": ["ops"],
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return ToolSchema(
            name: toolName,
            description: "Apply mem0 ADD/UPDATE/NOOP operations distilled from a conversation turn.",
            inputSchema: bytes
        )
    }()
}
