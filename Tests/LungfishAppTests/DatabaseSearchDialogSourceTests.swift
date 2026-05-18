import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class DatabaseSearchDialogSourceTests: XCTestCase {
    func testDialogPresentationReusesSharedOperationsShellState() {
        let state = DatabaseSearchDialogState(initialDestination: .genBankGenomes)
        state.genBankGenomesViewModel.searchText = "SARS-CoV-2"

        let presentation = DatabaseSearchDialogPresentation(state: state)

        XCTAssertEqual(presentation.title, "GenBank & Genomes")
        XCTAssertEqual(presentation.subtitle, "Nucleotide, assembly, and virus records from NCBI")
        XCTAssertEqual(presentation.datasetLabel, "NCBI Search")
        XCTAssertEqual(presentation.selectedToolID, "genBankGenomes")
        XCTAssertEqual(presentation.primaryActionTitle, "Search")
        XCTAssertEqual(presentation.accessibilityNamespace, "database-search")
        XCTAssertTrue(presentation.isRunEnabled)
        XCTAssertEqual(presentation.statusText, "Ready")
    }

    func testDialogPresentationFollowsSelectedDestinationAndActiveViewModel() {
        let state = DatabaseSearchDialogState(initialDestination: .sraRuns)
        state.sraRunsViewModel.searchText = "SRR000001"
        state.sraRunsViewModel.selectedRecords.insert(SearchResultRecord(
            id: "SRR000001",
            accession: "SRR000001",
            title: "Example SRA run",
            source: .ena
        ))

        let presentation = DatabaseSearchDialogPresentation(state: state)

        XCTAssertEqual(presentation.title, "SRA Runs")
        XCTAssertEqual(presentation.datasetLabel, "SRA Search")
        XCTAssertEqual(presentation.selectedToolID, "sraRuns")
        XCTAssertEqual(presentation.primaryActionTitle, "Download Selected")
        XCTAssertEqual(presentation.statusText, "1 selected")
        XCTAssertTrue(presentation.isRunEnabled)
    }

    func testPathoplexusConsentGateIsRepresentedByDialogPresentation() {
        let state = DatabaseSearchDialogState(initialDestination: .pathoplexus)
        state.pathoplexusViewModel.hasAcceptedPathoplexusConsent = false

        let presentation = DatabaseSearchDialogPresentation(state: state)

        XCTAssertEqual(presentation.title, "Pathoplexus")
        XCTAssertEqual(presentation.datasetLabel, "Pathoplexus")
        XCTAssertEqual(presentation.primaryActionTitle, "Search")
        XCTAssertEqual(presentation.statusText, "Review the Pathoplexus access notice to continue.")
        XCTAssertFalse(presentation.isRunEnabled)
    }

    func testGenBankGenomesPanePresentationExposesNCBIModeAndGFF3Controls() {
        let presentation = GenBankGenomesPanePresentation()

        XCTAssertEqual(presentation.modePickerAccessibilityID, "database-search-ncbi-mode-picker")
        XCTAssertEqual(presentation.modeTitles, ["Nucleotide", "Genome", "Virus"])
        XCTAssertEqual(presentation.filterTitles, ["RefSeq Only", "Include GFF3 Annotations"])
        XCTAssertEqual(
            presentation.includeGFF3AnnotationsAccessibilityID,
            "database-search-include-gff3-annotations"
        )
    }
}
