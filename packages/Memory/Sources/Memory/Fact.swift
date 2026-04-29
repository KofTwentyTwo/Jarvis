import Foundation

/// One row of the facts table (RESEARCH section 1).
///
/// Temporal validity (MEM-05): validTo == nil means the fact is currently
/// active. validTo == someDate means the fact was superseded at that
/// instant — and is preserved as history. forgottenAt != nil means
/// forget_fact (D-02) closed it; downstream queries must filter both
/// validTo IS NULL AND forgottenAt IS NULL for "active" semantics.
public struct Fact: Sendable, Equatable {
    public let id: Int64
    public let subject: String
    public let predicate: String
    public let object: String
    public let sourceTurnId: Int64?
    public let validFrom: Int64           // unix-ms
    public let validTo: Int64?            // unix-ms; nil means active
    public let supersededBy: Int64?
    public let forgottenAt: Int64?        // D-02: forget_fact closes valid_to + sets this
    public let createdAt: Int64

    public init(
        id: Int64,
        subject: String,
        predicate: String,
        object: String,
        sourceTurnId: Int64? = nil,
        validFrom: Int64,
        validTo: Int64? = nil,
        supersededBy: Int64? = nil,
        forgottenAt: Int64? = nil,
        createdAt: Int64
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.sourceTurnId = sourceTurnId
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.forgottenAt = forgottenAt
        self.createdAt = createdAt
    }
}
