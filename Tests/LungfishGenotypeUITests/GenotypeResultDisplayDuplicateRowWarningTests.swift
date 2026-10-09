import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Decision D5b of the Phase 2.3 follow-up collapses duplicate rows (one
/// animal, locus and allele) to one occurrence with a warning. The Inspector's
/// Genotype Display section shows that warning for every bundle type, not
/// only inside the full-length candidate section, so a MiSeq or barcode
/// bundle that collapsed rows says so too. The wording is the coded line the
/// candidate section always used.
@MainActor
final class GenotypeResultDisplayDuplicateRowWarningTests: GenotypeResultViewportTestCase {
    func testEveryBundleKindShowsTheDuplicateRowWarningInTheGenotypeDisplaySection() throws {
        let kinds = [
            GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            "ont-barcode-genotype",
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
        ]
        for kind in kinds {
            let result = makeResult(
                samples: [],
                calls: [
                    makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 40),
                    makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 12),
                    makeCall(sample: "AnimalA", genotype: "MHC_002g2", reads: 30),
                ],
                kind: kind
            )
            let warning = try XCTUnwrap(result.integrityWarnings.first { $0.code == .duplicateCallRowsCollapsed }, kind)
            let expectedLine = "duplicate-call-rows-collapsed: " + warning.detail
            XCTAssertTrue(warning.detail.hasPrefix("1 duplicate genotype row was collapsed."), warning.detail)
            let viewModel = GenotypeResultDisplaySectionViewModel()

            viewModel.updateMHCCandidatePresentation(from: result)

            XCTAssertEqual(viewModel.resultIntegrityWarnings, [expectedLine], kind)
            XCTAssertFalse(
                viewModel.mhcCandidateIntegrityWarnings.contains(expectedLine),
                "the warning shows once, outside the candidate section, for \(kind)"
            )
        }
    }

    func testABundleWithoutDuplicateRowsShowsNoResultWarning() {
        let result = makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 40),
                makeCall(sample: "AnimalB", genotype: "MHC_001g1", reads: 12),
            ]
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result)

        XCTAssertTrue(viewModel.resultIntegrityWarnings.isEmpty)
    }

    func testClearRemovesTheResultWarning() {
        let result = makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 40),
                makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 12),
            ]
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateMHCCandidatePresentation(from: result)
        XCTAssertFalse(viewModel.resultIntegrityWarnings.isEmpty)

        viewModel.clear()

        XCTAssertTrue(viewModel.resultIntegrityWarnings.isEmpty)
    }
}
