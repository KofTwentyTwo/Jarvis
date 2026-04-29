import Foundation

/// One mem0 operation produced by the extractor (RESEARCH §5).
///
/// The model is allowed to return ADD, UPDATE, or NOOP. Anything else fails
/// schema validation in `MemoryOp.parseApplyMemoryOps` and is dropped.
public enum MemoryOp: Sendable, Equatable {
    /// New durable fact — subject/predicate/object triple plus an optional
    /// pre-computed embedding (the extractor may compute embeddings inline,
    /// or applyOp may compute them lazily — the embedding parameter is
    /// reserved for plan 07-03's read-path wiring).
    case add(subject: String, predicate: String, object: String, embedding: [Float]?)

    /// Existing fact superseded — `supersedes` is the prior `fact_id`; the
    /// triple is the NEW values. `MemoryStore.applyOp`'s MEM-05 supersede
    /// transaction closes `valid_to` + `superseded_by` on the prior row and
    /// inserts a new row with the new values.
    case update(supersedes: Int64, subject: String, predicate: String, object: String, embedding: [Float]?)

    /// No durable fact change — debug-only logging.
    case noop

    /// Parse an `apply_memory_ops` tool-call argsJSON blob into a list of ops.
    ///
    /// Schema (RESEARCH §5):
    /// ```
    /// {"ops": [
    ///   {"op":"ADD|UPDATE|NOOP","subject":"...","predicate":"...","object":"...",
    ///    "supersedes_fact_id": 123}
    /// ]}
    /// ```
    ///
    /// `subject`/`predicate`/`object` required for ADD/UPDATE;
    /// `supersedes_fact_id` required (and > 0) for UPDATE. NOOP entries
    /// become `.noop` and carry no fields. Invalid entries are DROPPED
    /// (logged at debug, not thrown) — partial validity is preferred over
    /// failing the whole batch.
    ///
    /// Throws `MemoryError.extractorInvalidArgs` only when the top-level
    /// `ops` array is missing or the payload isn't a JSON object.
    public static func parseApplyMemoryOps(_ data: Data) throws -> [MemoryOp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ops = root["ops"] as? [[String: Any]]
        else {
            throw MemoryError.extractorInvalidArgs("missing top-level ops array")
        }
        var out: [MemoryOp] = []
        for entry in ops {
            guard let opStr = entry["op"] as? String else { continue }
            switch opStr.uppercased() {
            case "ADD":
                guard let s = entry["subject"] as? String,
                      let p = entry["predicate"] as? String,
                      let o = entry["object"] as? String,
                      !s.isEmpty, !p.isEmpty, !o.isEmpty
                else { continue }
                out.append(.add(subject: s, predicate: p, object: o, embedding: nil))
            case "UPDATE":
                guard let s = entry["subject"] as? String,
                      let p = entry["predicate"] as? String,
                      let o = entry["object"] as? String,
                      !s.isEmpty, !p.isEmpty, !o.isEmpty
                else { continue }
                let id: Int64?
                if let n = entry["supersedes_fact_id"] as? NSNumber {
                    id = n.int64Value
                } else if let i = entry["supersedes_fact_id"] as? Int {
                    id = Int64(i)
                } else {
                    id = nil
                }
                guard let priorId = id, priorId > 0 else { continue }
                out.append(.update(supersedes: priorId, subject: s, predicate: p, object: o, embedding: nil))
            case "NOOP":
                out.append(.noop)
            default:
                continue
            }
        }
        return out
    }
}

/// Compact reference to a fact for retrieval-side surfaces (DevOverlay rows
/// per D-05 / MEM-08).
///
/// `score` is the RRF-fused rank score from HybridSearch; nil for non-search
/// emit sites. `triggerTurnId` carries the turn that caused the retrieval, so
/// the DevOverlay can correlate retrievals with the user-facing turn that
/// asked the question. `timestamp` is unix-ms at emit time.
public struct FactRef: Sendable, Equatable, Codable {
    public let factId: Int64
    public let summary: String        // "subject predicate object" formatted
    public let score: Double?
    public let triggerTurnId: Int64
    public let timestamp: Int64

    public init(
        factId: Int64,
        summary: String,
        score: Double? = nil,
        triggerTurnId: Int64 = 0,
        timestamp: Int64 = 0
    ) {
        self.factId = factId
        self.summary = summary
        self.score = score
        self.triggerTurnId = triggerTurnId
        self.timestamp = timestamp
    }
}

/// One row of the turns table (TEXT-03 chat-panel hydration + replay).
/// Mirrors the schema from MemorySchema.swift (07-01) one-for-one.
public struct TurnRow: Sendable, Equatable, Codable {
    public let id: Int64
    public let sessionId: String
    public let role: String          // "user" | "assistant" | "tool"
    public let content: String
    public let source: String        // TurnSource rawValue (e.g. "userText", "wakeWord", "memoryExtraction")
    public let createdAt: Int64      // unix-ms

    public init(
        id: Int64,
        sessionId: String,
        role: String,
        content: String,
        source: String,
        createdAt: Int64
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.source = source
        self.createdAt = createdAt
    }
}
