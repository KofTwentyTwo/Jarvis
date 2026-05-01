import Foundation

/// Six categories the drift classifier emits for each recorded-vs-actual
/// divergence. The first two are "expected" (filed into
/// `DriftReport.expected`), the remaining four are "unexpected" (filed into
/// `DriftReport.unexpected`); `DriftReport.passed` is true iff the unexpected
/// bucket is empty.
public enum DriftCategory: String, Sendable, Codable, CaseIterable {
    /// Field is in `ExclusionList.alwaysExcluded` (OBS-02 IDs, timestamps,
    /// nonces). Expected divergence.
    case idOrTimestamp
    /// Field is in `ExclusionList.nondeterministicUnderSampling` AND the
    /// recording's `temperature > 0`. Expected divergence.
    case samplingNondeterminism
    /// JSON shape differs (key added/removed). Unexpected — schema regression.
    case schemaChange
    /// Same set of items, different order. Unexpected — ordering bug.
    case orderingBug
    /// One side ends earlier than the other. Unexpected — truncation bug.
    case truncationBug
    /// Deterministic field's value changed. Unexpected — value regression.
    case valueBug
}

/// One drift datum: a single field divergence at a specific row ordinal.
public struct DriftItem: Sendable, Codable, Equatable {
    /// Position of the row in the paired walk (recorded[i] vs actual[i]).
    public let rowOrdinal: Int
    /// Field name (column or JSON key).
    public let field: String
    /// Category assigned by `DriftClassifier`.
    public let category: DriftCategory
    /// Recorded value (string-rendered for diagnostics).
    public let recorded: String
    /// Actual value (string-rendered for diagnostics).
    public let actual: String
    /// Why this delta was filed under `category` — the operator-readable
    /// reason that produced the classification. Populated for every
    /// expected-bucket item so growth of the exclusion set is visible at
    /// every gate run (e.g. `"alwaysExcluded membership"`,
    /// `"nondeterministicUnderSampling@temperature=0.7"`). Unexpected items
    /// also carry a reason describing what triggered them
    /// (`"key only on recorded side"`, `"row count mismatch"`).
    public let reason: String

    public init(
        rowOrdinal: Int,
        field: String,
        category: DriftCategory,
        recorded: String,
        actual: String,
        reason: String
    ) {
        self.rowOrdinal = rowOrdinal
        self.field = field
        self.category = category
        self.recorded = recorded
        self.actual = actual
        self.reason = reason
    }
}

/// Classifier output. `passed` short-circuits the gate.
public struct DriftReport: Sendable, Codable, Equatable {
    /// `idOrTimestamp` + `samplingNondeterminism` items.
    public let expected: [DriftItem]
    /// `schemaChange` + `orderingBug` + `truncationBug` + `valueBug` items.
    public let unexpected: [DriftItem]
    /// PASS iff the unexpected bucket is empty.
    public var passed: Bool { unexpected.isEmpty }

    public init(expected: [DriftItem], unexpected: [DriftItem]) {
        self.expected = expected
        self.unexpected = unexpected
    }
}
