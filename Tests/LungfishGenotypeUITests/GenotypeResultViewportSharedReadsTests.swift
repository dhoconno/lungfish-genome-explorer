import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Decision D2 of the Phase 2.3 follow-up, the Inspector row. A full-length
/// result gives each equal-best reference of a cluster its own call with the
/// full cluster reads and the tie list in `ambiguousWith`, so two tied rows
/// read like a heterozygote. The Selected Item detail of a tied cell names
/// the partners it shares its reads with. Only partners that are calls of the
/// same animal count, so an amplicon group whose aliases are not calls never
/// gets the row.
@MainActor
final class GenotypeResultViewportSharedReadsTests: GenotypeResultViewportTestCase {
    private let sharedReadsLabel = "Shares reads with"
    private let reviewFlagLabel = "Review flag"

    func testSelectedTiedCellNamesThePartnersItSharesReadsWith() {
        let tie = ["01_M1_A1_001", "02_M1_A1_002"]
        let calls = [
            tiedCall(sample: "LF1", genotype: tie[0], reads: 1_000, ambiguousWith: tie),
            tiedCall(sample: "LF1", genotype: tie[1], reads: 1_000, ambiguousWith: tie),
            tiedCall(sample: "LF1", genotype: "03_M2_A1_003", reads: 15, ambiguousWith: nil),
            tiedCall(sample: "LF2", genotype: tie[0], reads: 400, ambiguousWith: nil),
        ]
        let locus = calls[0].locusGroup
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
        ))

        controller.testingSelectMatrixCell(genotype: tie[0], sample: "LF1")
        XCTAssertTrue(
            controller.testingCurrentSelectionDetailRows.contains { $0 == (sharedReadsLabel, tie[1]) },
            "the tied cell names its partner, rows were \(controller.testingCurrentSelectionDetailRows)"
        )
        controller.testingSelectMatrixCell(genotype: tie[1], sample: "LF1")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == (sharedReadsLabel, tie[0]) })

        controller.testingSelectMatrixCell(genotype: tie[0], sample: "LF2")
        XCTAssertFalse(
            controller.testingCurrentSelectionDetailRows.contains { $0.0 == sharedReadsLabel },
            "another animal's ordinary call of the same reference shares reads with nothing"
        )
        controller.testingSelectMatrixCell(genotype: "03_M2_A1_003", sample: "LF1")
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == sharedReadsLabel })

        controller.testingShowMatrixTargetSelection([.row(locus: locus, genotype: tie[0])])
        XCTAssertFalse(
            controller.testingCurrentSelectionDetailRows.contains { $0.0 == sharedReadsLabel },
            "a row selection names no animal, so it has no partners"
        )
        controller.testingShowMatrixTargetSelection([.cell(locus: locus, genotype: tie[0], sample: "LF1")])
        XCTAssertTrue(
            controller.testingCurrentSelectionDetailRows.contains { $0 == (sharedReadsLabel, tie[1]) },
            "a cell target names the partner too, rows were \(controller.testingCurrentSelectionDetailRows)"
        )
    }

    func testAnAmpliconGroupWhoseAliasesAreNotCallsGetsNoRow() {
        let calls = [
            tiedCall(
                sample: "LF1", genotype: "MHC_001g1", reads: 500,
                ambiguousWith: ["MHC_001g1", "MHC_002g2", "MHC_003g3"]
            ),
            tiedCall(sample: "LF1", genotype: "MHC_004g4", reads: 20, ambiguousWith: nil),
        ]
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSelectMatrixCell(genotype: "MHC_001g1", sample: "LF1")
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == sharedReadsLabel })
        controller.testingShowMatrixTargetSelection([.cell(locus: calls[0].locusGroup, genotype: "MHC_001g1", sample: "LF1")])
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == sharedReadsLabel })
    }

    /// The indel review flag sits beside the tie partners. A full-length call
    /// whose best hit carries indel bases has `review_flag` "indel" in the
    /// long summary, and the Selected Item detail of its cell says so in
    /// plain words. A call without indels, and a row selection, get no row.
    func testSelectedCellOfAnIndelCallShowsTheReviewFlagBesideItsPartners() {
        let tie = ["01_M1_A1_001", "02_M1_A1_002"]
        let calls = [
            tiedCall(sample: "LF1", genotype: tie[0], reads: 1_000, ambiguousWith: tie, indelBases: 3),
            tiedCall(sample: "LF1", genotype: tie[1], reads: 1_000, ambiguousWith: tie, indelBases: 0),
            tiedCall(sample: "LF1", genotype: "03_M2_A1_003", reads: 15, ambiguousWith: nil, indelBases: 1),
            tiedCall(sample: "LF2", genotype: tie[0], reads: 400, ambiguousWith: nil, indelBases: nil),
        ]
        let locus = calls[0].locusGroup
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
        ))

        let threeBases = (
            reviewFlagLabel,
            "Indel. The reads match this reference with 3 inserted or deleted bases, "
                + "so check the alignment before relying on this call."
        )
        controller.testingSelectMatrixCell(genotype: tie[0], sample: "LF1")
        var rows = controller.testingCurrentSelectionDetailRows
        let partnerIndex = rows.firstIndex { $0 == (sharedReadsLabel, tie[1]) }
        let flagIndex = rows.firstIndex { $0 == threeBases }
        XCTAssertNotNil(flagIndex, "the indel call shows its review flag, rows were \(rows)")
        XCTAssertEqual(flagIndex, partnerIndex.map { $0 + 1 }, "the flag follows the tie partners, rows were \(rows)")

        controller.testingSelectMatrixCell(genotype: "03_M2_A1_003", sample: "LF1")
        rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(
            rows.contains {
                $0 == (reviewFlagLabel, "Indel. The reads match this reference with 1 inserted or deleted base, "
                    + "so check the alignment before relying on this call.")
            },
            "one base reads in the singular, rows were \(rows)"
        )

        controller.testingSelectMatrixCell(genotype: tie[1], sample: "LF1")
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == reviewFlagLabel })
        controller.testingSelectMatrixCell(genotype: tie[0], sample: "LF2")
        XCTAssertFalse(
            controller.testingCurrentSelectionDetailRows.contains { $0.0 == reviewFlagLabel },
            "the flag belongs to one animal's call, not to the allele"
        )

        controller.testingShowMatrixTargetSelection([.row(locus: locus, genotype: tie[0])])
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == reviewFlagLabel })
        controller.testingShowMatrixTargetSelection([.cell(locus: locus, genotype: tie[0], sample: "LF1")])
        XCTAssertTrue(
            controller.testingCurrentSelectionDetailRows.contains { $0 == threeBases },
            "a cell target shows the flag too, rows were \(controller.testingCurrentSelectionDetailRows)"
        )
    }

    private func tiedCall(
        sample: String,
        genotype: String,
        reads: Int,
        ambiguousWith: [String]?,
        indelBases: Int? = nil
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil,
            ambiguousWith: ambiguousWith,
            indelBases: indelBases
        )
    }
}
