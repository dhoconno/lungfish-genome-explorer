import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// Call overrides, cell highlights, cell comments and call status flags are
/// keyed by haplotype locus. One saved before N9 against a full-length
/// call's per-reference pseudo-locus (MHC-NHP01270) no longer meets any call
/// once the call sits at its gene locus. These edits are not moved, because
/// a haplotype locus edit cannot be mapped to one gene-locus slot, so the
/// result warns how many no longer apply (N9 review finding 3).
final class GenotypeLegacyLocusEditWarningTests: XCTestCase {
    private let timestamp = "2026-10-09T00:00:00Z"

    private func result(kind: String = GenotypeReferenceRecordLocusTests.fullLength) -> ONTGenotypeResultBundleData {
        GenotypeReferenceRecordLocusTests.result(calls: [
            GenotypeReferenceRecordLocusTests.call("CR1178", "NHP01270", 674),
            GenotypeReferenceRecordLocusTests.call("CR1178", "NHP01718", 712),
        ], kind: kind)
    }

    private func sidecar(legacyLocus: String = "MHC-NHP01270") -> GenotypeAnnotationSidecar {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.callOverrides = [
            .init(sample: "CR1178", locus: legacyLocus, slot: .h1, originalCall: "M1", overrideCall: "M2",
                  reasonTag: .misCall, rationale: "", author: "QA", timestamp: timestamp),
            .init(sample: "CR1178", locus: "MHC-A", slot: .h1, originalCall: "M1", overrideCall: "M2",
                  reasonTag: .misCall, rationale: "", author: "QA", timestamp: timestamp),
        ]
        sidecar.cellHighlights = [
            .init(sample: "CR1178", locus: "MHC-NHP01718", slot: .h2, fillColor: "#FF0000", borderColor: nil,
                  author: "QA", timestamp: timestamp),
        ]
        sidecar.cellComments = [
            .init(sample: "CR1178", locus: legacyLocus, slot: .h1, body: "old", author: "QA", timestamp: timestamp),
        ]
        sidecar.callStatusFlags = [
            .init(sample: "CR1178", locus: legacyLocus, slot: .h2, value: .needsReview, author: "QA", timestamp: timestamp),
            .init(sample: "CR1178", locus: "MHC-B", slot: .h2, value: .needsReview, author: "QA", timestamp: timestamp),
        ]
        return sidecar
    }

    func testEditsSavedAtAnOldPseudoLocusAreCountedInPlainWords() throws {
        let warnings = ONTGenotypeIntegrityWarning.legacyLocusEdits(in: sidecar(), calls: result().calls)

        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warning.code, .legacyLocusEditsOrphaned)
        XCTAssertEqual(warning.code.rawValue, "legacy-locus-edits-orphaned")
        XCTAssertEqual(
            warning.detail,
            "4 analyst edits were saved at an old per-reference locus and no longer apply. "
                + "Review them again at the gene locus."
        )
    }

    func testOneEditIsSingular() throws {
        var one = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        one.cellComments = [
            .init(sample: "CR1178", locus: "MHC-NHP01270", slot: .h1, body: "old", author: "QA", timestamp: timestamp),
        ]
        let warning = try XCTUnwrap(ONTGenotypeIntegrityWarning.legacyLocusEdits(in: one, calls: result().calls).first)
        XCTAssertEqual(
            warning.detail,
            "1 analyst edit was saved at an old per-reference locus and no longer applies. "
                + "Review it again at the gene locus."
        )
    }

    func testNoWarningWithoutLegacyEditsOrForAnUnstampedResult() {
        var current = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        current.callOverrides = sidecar().callOverrides.filter { $0.locus == "MHC-A" }
        XCTAssertEqual(ONTGenotypeIntegrityWarning.legacyLocusEdits(in: current, calls: result().calls), [])
        XCTAssertEqual(
            ONTGenotypeIntegrityWarning.legacyLocusEdits(
                in: sidecar(), calls: result(kind: GenotypeReferenceRecordLocusTests.amplicon).calls),
            [],
            "an amplicon result has no stamped calls, so no locus is old"
        )
    }
}
