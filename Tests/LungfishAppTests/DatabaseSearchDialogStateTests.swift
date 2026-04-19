import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class DatabaseSearchDialogStateTests: XCTestCase {
    func testDestinationTitlesAndSubtitlesMatchApprovedCopy() {
        XCTAssertEqual(DatabaseSearchDestination.genBankGenomes.title, "GenBank & Genomes")
        XCTAssertEqual(
            DatabaseSearchDestination.genBankGenomes.subtitle,
            "Nucleotide, assembly, and virus records from NCBI"
        )

        XCTAssertEqual(DatabaseSearchDestination.sraRuns.title, "SRA Runs")
        XCTAssertEqual(
            DatabaseSearchDestination.sraRuns.subtitle,
            "Sequencing runs and FASTQ availability"
        )

        XCTAssertEqual(DatabaseSearchDestination.pathoplexus.title, "Pathoplexus")
        XCTAssertEqual(
            DatabaseSearchDestination.pathoplexus.subtitle,
            "Open pathogen records and surveillance metadata"
        )
    }

    func testDestinationMappingFromDatabaseSource() {
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ncbi), .genBankGenomes)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ena), .sraRuns)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .pathoplexus), .pathoplexus)
    }

    func testSwitchingDestinationsPreservesSearchTextPerViewModel() {
        let state = DatabaseSearchDialogState()

        state.genBankGenomesViewModel.searchText = "SARS-CoV-2"
        state.selectDestination(.sraRuns)
        state.sraRunsViewModel.searchText = "SRR123456"
        state.selectDestination(.pathoplexus)
        state.pathoplexusViewModel.searchText = "mpox"

        state.selectDestination(.genBankGenomes)
        XCTAssertEqual(state.genBankGenomesViewModel.searchText, "SARS-CoV-2")

        state.selectDestination(.sraRuns)
        XCTAssertEqual(state.sraRunsViewModel.searchText, "SRR123456")

        state.selectDestination(.pathoplexus)
        XCTAssertEqual(state.pathoplexusViewModel.searchText, "mpox")
    }

    func testPrimaryActionTitleSwitchesToDownloadSelected() {
        let state = DatabaseSearchDialogState()
        XCTAssertEqual(state.primaryActionTitle, "Search")

        let selectedRecord = SearchResultRecord(
            id: "NC_000000",
            accession: "NC_000000",
            title: "Example record",
            source: .ncbi
        )
        state.genBankGenomesViewModel.selectedRecords.insert(selectedRecord)

        XCTAssertEqual(state.primaryActionTitle, "Download Selected")
    }

    func testCallbacksWireAcrossAllOwnedViewModels() {
        let state = DatabaseSearchDialogState()
        var cancelCount = 0
        var downloadCount = 0

        state.applyCallbacks(
            onCancel: { cancelCount += 1 },
            onDownloadStarted: { downloadCount += 1 }
        )

        state.genBankGenomesViewModel.onCancel?()
        state.sraRunsViewModel.onCancel?()
        state.pathoplexusViewModel.onCancel?()
        state.genBankGenomesViewModel.onDownloadStarted?()
        state.sraRunsViewModel.onDownloadStarted?()
        state.pathoplexusViewModel.onDownloadStarted?()

        XCTAssertEqual(cancelCount, 3)
        XCTAssertEqual(downloadCount, 3)
    }

    func testPathoplexusConsentBlocksPrimaryActionUntilAccepted() {
        let state = DatabaseSearchDialogState(initialDestination: .pathoplexus)
        state.pathoplexusViewModel.hasAcceptedPathoplexusConsent = false

        XCTAssertFalse(state.isPrimaryActionEnabled)

        state.performPrimaryAction()

        XCTAssertEqual(state.pathoplexusViewModel.searchPhase, .idle)
        XCTAssertEqual(state.statusText, "Review the Pathoplexus access notice to continue.")
    }
}
