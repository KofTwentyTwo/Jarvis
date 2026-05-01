import Foundation

/// One materialized replay-log row, as the harness reads it back from the
/// SQLite `events` table joined with the parent `turns` row's identity.
///
/// `fields` is the comparable JSON-shaped map the classifier diffs:
///
///   - All eight OBS-02 identity columns appear as keys (`row_id`,
///     `turn_id`, `session_id`, `tool_use_id`, `message_id`, `ts`,
///     `monotonic_ns`, `turn_nonce`) so `ExclusionList.alwaysExcluded` can
///     match by name.
///   - The event payload is decoded into the map under its semantic field
///     names (`kind`, `payload_text`, `tool_call_args`, etc.) — depth-1
///     JSON parsing is sufficient for v1; nested JSON is rendered as a
///     stable JSON string and compared as one field.
///
/// Plan 08-01 keeps this struct local to Harness because `packages/Replay`
/// exposes no public reader. Task 3 (`ReplayMCPAdapter` / `ReplayRunner`)
/// adds the SQLite-read shim that materializes `[ReplayRow]` from a session
/// DB. Task 2 (this file) only needs the type for the classifier signature
/// and unit tests.
public struct ReplayRow: Sendable, Equatable {
    public let fields: [String: String]
    public init(fields: [String: String]) {
        self.fields = fields
    }
}

/// Pure classifier over recorded-vs-actual replay rows. No I/O — caller
/// (`ReplayRunner` in Task 3) handles SQLite reads and feeds materialized
/// row arrays in.
///
/// Pattern follows `AnthropicProvider/SSEDecoder.swift` per PATTERNS.md §2.3:
/// static dispatch fn, mutable accumulators in the caller's frame, no actor
/// state. Closure-emit idiom isolates the per-row decision logic so it stays
/// testable without thread coordination.
///
/// Anti-pattern guard (RESEARCH §Anti-Patterns line 350): never compare two
/// replay logs with `diff` or string-equality. The `ExclusionList` plus the
/// six-category `DriftCategory` enum is the only correct shape.
public enum DriftClassifier {
    /// Schema version this classifier understands. `ReplayRunner` (Task 3)
    /// rejects logs whose `meta.schema_version` is below this constant
    /// with a "re-record after refactor X" error per D-11.
    public static let supportedSchemaVersion: Int = 1

    /// Classify a paired walk of recorded-vs-actual rows.
    ///
    /// - Parameter recordingTemperature: the recording-time `temperature`
    ///   from the recorded session's meta. Drives the
    ///   `nondeterministicUnderSampling` carve-out: a divergence in such a
    ///   field is `samplingNondeterminism` only when `temperature > 0`,
    ///   otherwise it's a `valueBug`.
    public static func classify(
        recordedRows: [ReplayRow],
        actualRows: [ReplayRow],
        exclusions: ExclusionList,
        recordingTemperature: Double
    ) -> DriftReport {
        var expected: [DriftItem] = []
        var unexpected: [DriftItem] = []

        // Truncation: row counts differ. Emit at the shorter side's tail and
        // continue with the paired prefix so we still surface per-field drift
        // up to the truncation point.
        if recordedRows.count != actualRows.count {
            unexpected.append(
                DriftItem(
                    rowOrdinal: min(recordedRows.count, actualRows.count),
                    field: "row_count",
                    category: .truncationBug,
                    recorded: String(recordedRows.count),
                    actual: String(actualRows.count),
                    reason: "row count mismatch (recorded=\(recordedRows.count) actual=\(actualRows.count))"
                )
            )
        }

        let pairCount = min(recordedRows.count, actualRows.count)
        for ordinal in 0..<pairCount {
            classifyRow(
                ordinal: ordinal,
                rec: recordedRows[ordinal],
                act: actualRows[ordinal],
                exclusions: exclusions,
                temperature: recordingTemperature,
                emitExpected: { expected.append($0) },
                emitUnexpected: { unexpected.append($0) }
            )
        }

        return DriftReport(expected: expected, unexpected: unexpected)
    }

    /// Per-row decision logic — the only place the four field-level
    /// categories (`idOrTimestamp` / `samplingNondeterminism` /
    /// `schemaChange` / `valueBug`) get assigned. `truncationBug` and
    /// `orderingBug` are row-level decisions made by the caller.
    private static func classifyRow(
        ordinal: Int,
        rec: ReplayRow,
        act: ReplayRow,
        exclusions: ExclusionList,
        temperature: Double,
        emitExpected: (DriftItem) -> Void,
        emitUnexpected: (DriftItem) -> Void
    ) {
        let recKeys = Set(rec.fields.keys)
        let actKeys = Set(act.fields.keys)

        // Schema change — keys differ across the two rows.
        let onlyInRec = recKeys.subtracting(actKeys)
        for key in onlyInRec.sorted() {
            emitUnexpected(
                DriftItem(
                    rowOrdinal: ordinal,
                    field: key,
                    category: .schemaChange,
                    recorded: rec.fields[key] ?? "",
                    actual: "<missing>",
                    reason: "field present on recorded side, absent on actual"
                )
            )
        }
        let onlyInAct = actKeys.subtracting(recKeys)
        for key in onlyInAct.sorted() {
            emitUnexpected(
                DriftItem(
                    rowOrdinal: ordinal,
                    field: key,
                    category: .schemaChange,
                    recorded: "<missing>",
                    actual: act.fields[key] ?? "",
                    reason: "field present on actual side, absent on recorded"
                )
            )
        }

        // Per-field value comparison for keys present in both sides.
        let common = recKeys.intersection(actKeys)
        for key in common.sorted() {
            let recValue = rec.fields[key] ?? ""
            let actValue = act.fields[key] ?? ""
            guard recValue != actValue else { continue }

            if exclusions.alwaysExcluded.contains(key) {
                emitExpected(
                    DriftItem(
                        rowOrdinal: ordinal,
                        field: key,
                        category: .idOrTimestamp,
                        recorded: recValue,
                        actual: actValue,
                        reason: "alwaysExcluded membership (id/timestamp/nonce)"
                    )
                )
            } else if exclusions.nondeterministicUnderSampling.contains(key)
                && temperature > 0 {
                emitExpected(
                    DriftItem(
                        rowOrdinal: ordinal,
                        field: key,
                        category: .samplingNondeterminism,
                        recorded: recValue,
                        actual: actValue,
                        reason: "nondeterministicUnderSampling@temperature=\(temperature)"
                    )
                )
            } else {
                // Deterministic field changed under temp 0 (or not on the
                // sampling carve-out list). Real regression.
                emitUnexpected(
                    DriftItem(
                        rowOrdinal: ordinal,
                        field: key,
                        category: .valueBug,
                        recorded: recValue,
                        actual: actValue,
                        reason: temperature > 0
                            ? "deterministic field diverged at temperature=\(temperature) (not on sampling carve-out)"
                            : "deterministic field diverged at temperature=0"
                    )
                )
            }
        }
    }
}
