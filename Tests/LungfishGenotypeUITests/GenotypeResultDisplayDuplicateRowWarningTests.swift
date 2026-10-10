import XCTest
import SwiftUI
import ViewInspector
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Decision D5b of the Phase 2.3 follow-up collapses duplicate rows (one
/// animal, locus and allele) to one occurrence with a warning. The Inspector's
/// Genotype Display section shows that warning for every bundle type, not
/// only inside the full-length candidate section, so a MiSeq or barcode
/// bundle that collapsed rows says so too. The line is the warning's plain
/// detail. Its code is the line's help text, never part of the sentence.
@MainActor
final class GenotypeResultDisplayDuplicateRowWarningTests: GenotypeResultViewportTestCase {
    private static let warningID = GenotypeResultIntegrityWarningList.accessibilityIdentifier

    private func duplicateRowResult(kind: String = "ont-barcode-genotype") -> ONTGenotypeResultBundleData {
        makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 40),
                makeCall(sample: "AnimalA", genotype: "MHC_001g1", reads: 12),
                makeCall(sample: "AnimalA", genotype: "MHC_002g2", reads: 30),
            ],
            kind: kind
        )
    }

    /// The warning labels the Genotype Display section renders, through the
    /// section's own gate, `isAvailable`.
    private func renderedWarnings(
        _ viewModel: GenotypeResultDisplaySectionViewModel
    ) throws -> [InspectableView<ViewType.Label>] {
        viewModel.update(isAvailable: true)
        return try GenotypeResultDisplaySection(viewModel: viewModel).inspect()
            .findAll(ViewType.Label.self, where: { try $0.accessibilityIdentifier() == Self.warningID })
    }

    func testEveryBundleKindShowsTheDuplicateRowWarningInTheGenotypeDisplaySection() throws {
        let kinds = [
            GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            "ont-barcode-genotype",
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
        ]
        for kind in kinds {
            let result = duplicateRowResult(kind: kind)
            let warning = try XCTUnwrap(result.integrityWarnings.first { $0.code == .duplicateCallRowsCollapsed }, kind)
            XCTAssertTrue(warning.detail.hasPrefix("1 duplicate genotype row was collapsed."), warning.detail)
            let viewModel = GenotypeResultDisplaySectionViewModel()

            viewModel.updateMHCCandidatePresentation(from: result)

            XCTAssertEqual(viewModel.resultIntegrityWarnings, [warning], kind)
            XCTAssertFalse(
                viewModel.mhcCandidateIntegrityWarnings.contains { $0.contains(warning.detail) },
                "the warning shows once, outside the candidate section, for \(kind)"
            )
            let labels = try renderedWarnings(viewModel)
            XCTAssertEqual(labels.count, 1, "the section renders the warning list for \(kind)")
            let label = try XCTUnwrap(labels.first)
            XCTAssertEqual(try label.title().text().string(), warning.detail, "the line is the plain detail")
            XCTAssertEqual(try label.help().string(), "duplicate-call-rows-collapsed", "the code is the help text")
            XCTAssertEqual(
                try label.accessibilityLabel().string(),
                "Genotype result warning. " + warning.detail
            )
        }
    }

    func testAWarningThatNamesAFileShowsThePathAfterTheDetail() {
        let warning = ONTGenotypeIntegrityWarning(
            code: .candidateArtifactMissing, detail: "The file is missing.", path: "artifacts/a.bam")
        XCTAssertEqual(GenotypeResultIntegrityWarningList.line(for: warning), "The file is missing. (artifacts/a.bam)")
        XCTAssertEqual(
            GenotypeCandidateEvidenceProjection.warningText([warning, warning]),
            "The file is missing. (artifacts/a.bam)\nThe file is missing. (artifacts/a.bam)",
            "the candidate detail view words a warning as the list does"
        )
    }

    func testABundleWithoutDuplicateRowsShowsNoResultWarning() throws {
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
        XCTAssertTrue(try renderedWarnings(viewModel).isEmpty)
    }

    func testClearRemovesTheResultWarning() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateMHCCandidatePresentation(from: duplicateRowResult())
        XCTAssertFalse(viewModel.resultIntegrityWarnings.isEmpty)

        viewModel.clear()

        XCTAssertTrue(viewModel.resultIntegrityWarnings.isEmpty)
    }

    /// N9 review finding 3. A call override saved at a full-length call's
    /// old pseudo-locus no longer applies, and the Genotype Display section
    /// says so once the sidecar is known, and again after a sidecar change.
    func testEditsSavedAtAnOldPseudoLocusShowAWarningInTheGenotypeDisplaySection() throws {
        let calls = [makeCall(sample: "S1", genotype: "NHP01222", reads: 15)]
        let result = makeResult(
            samples: GenotypeCharacterizationFixture.sampleResults(for: calls, order: ["S1"]),
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            referenceMetadata: makeGenBankReferenceMetadata()
        )
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-A"])
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-09T00:00:00Z")
        sidecar.callOverrides = [
            .init(sample: "S1", locus: "MHC-NHP01222", slot: .h1, originalCall: "M1", overrideCall: "M2",
                  reasonTag: .misCall, rationale: "", author: "QA", timestamp: "2026-10-09T00:00:00Z"),
        ]
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result, sidecar: sidecar)

        XCTAssertEqual(viewModel.resultIntegrityWarnings.map(\.code), [.legacyLocusEditsOrphaned])
        let label = try XCTUnwrap(try renderedWarnings(viewModel).first)
        XCTAssertEqual(
            try label.title().text().string(),
            "1 analyst edit was saved at an old per-reference locus and no longer applies. Review it again at the gene locus."
        )

        viewModel.updateAnnotationIntegrityWarnings(result: result, sidecar: .empty(generatedAt: "2026-10-09T00:00:00Z"))
        XCTAssertTrue(viewModel.resultIntegrityWarnings.isEmpty, "the warning follows the sidecar")
    }

    /// Rows and Hidden Cells follow Content Text Size, as every other line of
    /// the section does.
    func testTheRowSummaryFollowsContentTextSize() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        XCTAssertNoThrow(
            try GenotypeResultDisplaySection(viewModel: viewModel).inspect().find(GenotypeResultDisplaySummary.self),
            "the section shows the row summary"
        )
        let summary = try GenotypeResultDisplaySummary(viewModel: viewModel).inspect()
        XCTAssertEqual(
            try summary.vStack().font(),
            ContentTypographyModel.shared.font(for: .body)
        )
    }
}
