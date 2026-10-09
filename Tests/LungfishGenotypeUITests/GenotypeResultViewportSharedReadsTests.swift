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

    private func tiedCall(sample: String, genotype: String, reads: Int, ambiguousWith: [String]?) -> ONTGenotypeCall {
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
            ambiguousWith: ambiguousWith
        )
    }
}
