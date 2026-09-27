import XCTest
import LungfishWorkflow
@testable import LungfishApp

/// Coverage presentation has to stop a reader taking a positional figure for a
/// measure of whether an assay works.
final class PrimerCoveragePresentationTests: XCTestCase {

    private func review(
        coveredBases: Int?, assayCountHeadline: Int? = nil, notes: [String] = [],
        advisories: [PrimerSchemeCoverageAdvisory] = []
    ) -> PrimerTargetDesignReview {
        .init(id: "target", label: "target", referenceLength: 1_000,
              coverageLabel: "spanned", coveredBases: coveredBases,
              assayCountHeadline: assayCountHeadline, intervals: [], primers: [],
              notes: notes, advisories: advisories)
    }

    // MARK: - qPCR shows a count, not a percentage

    /// A span union over independent alternatives is not a quality score, so qPCR
    /// must not present one.
    func testAssayCountHeadlineSuppressesTheCoveragePercentage() {
        let qpcr = review(coveredBases: 300, assayCountHeadline: 5)
        XCTAssertNil(qpcr.coveragePercent, "a count headline replaces the percentage")
        XCTAssertEqual(qpcr.assayCountHeadline, 5)
    }

    func testTiledSchemesKeepTheirCoveragePercentage() {
        let tiled = review(coveredBases: 300)
        XCTAssertEqual(tiled.coveragePercent, 30)
        XCTAssertNil(tiled.assayCountHeadline)
    }

    func testCoveragePercentStaysUnavailableWhenSpansAreUnknown() {
        XCTAssertNil(review(coveredBases: nil).coveragePercent)
    }

    // MARK: - Notes are data on the card, not hover-only text

    /// The notes explain that coverage is positional. They were previously reachable
    /// only by hovering, so a reader could miss them entirely.
    func testNotesArePresentOnTheReviewSoTheCardCanShowThem() {
        let notes = ["Coverage is positional.", "Overlapping spans count once."]
        XCTAssertEqual(review(coveredBases: 300, notes: notes).notes, notes)
    }

    func testAdvisoriesTravelWithTheReview() {
        let advisory = PrimerSchemeCoverageAdvisory(
            severity: .warning, message: "could produce off-targets")
        let target = review(coveredBases: 300, advisories: [advisory])
        XCTAssertEqual(target.advisories.count, 1)
        XCTAssertEqual(target.advisories[0].severity, .warning)
        XCTAssertEqual(target.advisories[0].message, "could produce off-targets")
    }

    // MARK: - Input naming parity

    /// The status line used to name an input with its bundle extension while the
    /// list showed it without, so the two disagreed about the same file.
    func testInputDisplayNameDropsTheBundleExtension() {
        let msa = URL(fileURLWithPath: "/p/Analyses/mamu-a1-panel.lungfishmsa")
        XCTAssertEqual(PrimerDesignDialogState.inputDisplayName(msa), "mamu-a1-panel")
        let reference = URL(fileURLWithPath: "/p/References/exclusion.lungfishref")
        XCTAssertEqual(PrimerDesignDialogState.inputDisplayName(reference), "exclusion")
        let fasta = URL(fileURLWithPath: "/p/inputs/panel.fasta")
        XCTAssertEqual(PrimerDesignDialogState.inputDisplayName(fasta), "panel")
    }

    @MainActor
    func testReadinessMessagesNameInputsWithoutTheBundleExtension() async {
        let state = PrimerDesignDialogState(projectURL: nil)
        let msa = URL(fileURLWithPath: "/p/Analyses/mamu-a1-panel.lungfishmsa")
        state.addInputs([msa])
        state.inputErrors[msa.standardizedFileURL] = "could not be read"
        let message = state.inputReadinessMessage
        XCTAssertEqual(message, "mamu-a1-panel: could not be read")
        XCTAssertFalse(message?.contains(".lungfishmsa") == true, message ?? "")
    }
}
