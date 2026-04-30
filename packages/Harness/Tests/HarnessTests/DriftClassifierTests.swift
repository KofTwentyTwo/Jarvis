import Testing
import Foundation
@testable import Harness

/// Coverage for the six `DriftCategory` cases.
///
/// `orderingBug` is documented as a known limitation in v1: this classifier
/// pairs rows by ordinal position, so a same-set/different-order regression
/// surfaces as a series of `valueBug` items rather than a single
/// `orderingBug`. A future plan can add an event-index-set pre-pass to
/// detect ordering bugs as a row-level category. The disabled placeholder
/// test below documents the limitation.
@Suite("DriftClassifierTests")
struct DriftClassifierTests {

    // MARK: helpers

    private func row(_ pairs: (String, String)...) -> ReplayRow {
        var dict: [String: String] = [:]
        for (k, v) in pairs { dict[k] = v }
        return ReplayRow(fields: dict)
    }

    // MARK: tests

    @Test("Identical rows produce passed report with no drift items")
    func identicalRowsPass() {
        let rec = row(("kind", "text_delta"), ("payload", "hello"))
        let act = row(("kind", "text_delta"), ("payload", "hello"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(report.passed)
        #expect(report.expected.isEmpty)
        #expect(report.unexpected.isEmpty)
    }

    @Test("row_id divergence is idOrTimestamp (expected); report passes")
    func rowIdDriftIsExpected() {
        let rec = row(("row_id", "1"), ("kind", "text_delta"), ("payload", "hi"))
        let act = row(("row_id", "9"), ("kind", "text_delta"), ("payload", "hi"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(report.passed)
        #expect(report.expected.count == 1)
        #expect(report.expected.first?.category == .idOrTimestamp)
        #expect(report.expected.first?.field == "row_id")
        #expect(report.unexpected.isEmpty)
    }

    @Test("textDelta divergence under temp>0 with sampling-carveout is expected")
    func samplingNondeterminismIsExpected() {
        let exclusions = ExclusionList(
            alwaysExcluded: ExclusionList.obs02Default.alwaysExcluded,
            nondeterministicUnderSampling: ["textDelta"]
        )
        let rec = row(("kind", "text_delta"), ("textDelta", "Hello, world!"))
        let act = row(("kind", "text_delta"), ("textDelta", "Hi there!"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: exclusions,
            recordingTemperature: 0.7
        )
        #expect(report.passed)
        #expect(report.expected.count == 1)
        #expect(report.expected.first?.category == .samplingNondeterminism)
        #expect(report.unexpected.isEmpty)
    }

    @Test("textDelta divergence under temp==0 is a valueBug (regression)")
    func greedyDecodeDriftIsValueBug() {
        let exclusions = ExclusionList(
            alwaysExcluded: ExclusionList.obs02Default.alwaysExcluded,
            nondeterministicUnderSampling: ["textDelta"]
        )
        let rec = row(("kind", "text_delta"), ("textDelta", "Hello"))
        let act = row(("kind", "text_delta"), ("textDelta", "Hi"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: exclusions,
            recordingTemperature: 0.0
        )
        #expect(!report.passed)
        #expect(report.unexpected.count == 1)
        #expect(report.unexpected.first?.category == .valueBug)
        #expect(report.unexpected.first?.field == "textDelta")
    }

    @Test("Truncation: actual shorter than recorded is a truncationBug")
    func truncationIsBug() {
        let recRows = (0..<5).map { i in row(("kind", "text_delta"), ("ord", "\(i)")) }
        let actRows = (0..<3).map { i in row(("kind", "text_delta"), ("ord", "\(i)")) }
        let report = DriftClassifier.classify(
            recordedRows: recRows,
            actualRows: actRows,
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(!report.passed)
        let truncs = report.unexpected.filter { $0.category == .truncationBug }
        #expect(truncs.count == 1)
        #expect(truncs.first?.field == "row_count")
        #expect(truncs.first?.recorded == "5")
        #expect(truncs.first?.actual == "3")
    }

    @Test("Schema change: extra key in actual is a schemaChange")
    func extraKeyIsSchemaChange() {
        let rec = row(("kind", "text_delta"), ("payload", "hi"))
        let act = row(("kind", "text_delta"), ("payload", "hi"), ("new_field", "x"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(!report.passed)
        let schemas = report.unexpected.filter { $0.category == .schemaChange }
        #expect(schemas.count == 1)
        #expect(schemas.first?.field == "new_field")
        #expect(schemas.first?.recorded == "<missing>")
    }

    @Test("Schema change: missing key in actual is a schemaChange")
    func missingKeyIsSchemaChange() {
        let rec = row(("kind", "text_delta"), ("payload", "hi"), ("dropped", "x"))
        let act = row(("kind", "text_delta"), ("payload", "hi"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(!report.passed)
        let schemas = report.unexpected.filter { $0.category == .schemaChange }
        #expect(schemas.count == 1)
        #expect(schemas.first?.field == "dropped")
        #expect(schemas.first?.actual == "<missing>")
    }

    @Test("valueBug: deterministic field tool_call_args.command changed")
    func toolCallArgsChangeIsValueBug() {
        let rec = row(("kind", "tool_call_requested"), ("tool_call_args", "{\"command\":\"ls\"}"))
        let act = row(("kind", "tool_call_requested"), ("tool_call_args", "{\"command\":\"rm -rf /\"}"))
        let report = DriftClassifier.classify(
            recordedRows: [rec],
            actualRows: [act],
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        #expect(!report.passed)
        #expect(report.unexpected.count == 1)
        #expect(report.unexpected.first?.category == .valueBug)
        #expect(report.unexpected.first?.field == "tool_call_args")
    }

    @Test(
        "orderingBug detection deferred — same set / different order surfaces as multiple valueBugs in v1",
        .disabled("Row pairing by ordinal position cannot distinguish ordering from value bugs; future plan adds event-index-set pre-pass.")
    )
    func orderingBugDeferred() {
        // Same two tool-call rows in opposite order.
        let recRows = [
            row(("kind", "tool_call_requested"), ("tool_use_id", "tool_a")),
            row(("kind", "tool_call_requested"), ("tool_use_id", "tool_b")),
        ]
        let actRows = [
            row(("kind", "tool_call_requested"), ("tool_use_id", "tool_b")),
            row(("kind", "tool_call_requested"), ("tool_use_id", "tool_a")),
        ]
        let report = DriftClassifier.classify(
            recordedRows: recRows,
            actualRows: actRows,
            exclusions: .obs02Default,
            recordingTemperature: 0.0
        )
        // When implemented, this would assert exactly one orderingBug item.
        #expect(report.unexpected.contains { $0.category == .orderingBug })
    }
}
