import XCTest
@testable import LungfishApp

@MainActor
final class TwelveSResultDisplaySectionTests: XCTestCase {
    func testViewModelPublishesFilterChangesAndClampsMinimumReads() {
        let viewModel = TwelveSResultDisplaySectionViewModel()
        var deliveredStates: [TwelveSResultDisplayState] = []
        viewModel.onDisplayStateChanged = { deliveredStates.append($0) }

        viewModel.setMinimumExactReads(12)
        viewModel.setFilterText("homo")
        viewModel.setIncludedTaxonGroups(["Mammal", "Fish"])
        viewModel.setExcludeHuman(true)
        viewModel.setRequireAlternateMatches(true)
        viewModel.setMinimumUnresolvedReads(5)
        viewModel.setChimeraFilter(.candidate)
        viewModel.setMinimumExactReads(-5)

        XCTAssertEqual(deliveredStates.last?.minimumExactReads, 0)
        XCTAssertEqual(deliveredStates.last?.filterText, "homo")
        XCTAssertEqual(deliveredStates.last?.includedTaxonGroups, ["Mammal", "Fish"])
        XCTAssertTrue(deliveredStates.last?.excludeHuman == true)
        XCTAssertTrue(deliveredStates.last?.requireAlternateMatches == true)
        XCTAssertEqual(deliveredStates.last?.minimumUnresolvedReads, 5)
        XCTAssertEqual(deliveredStates.last?.chimeraFilter, .candidate)
    }

    func testViewModelPublishesExportRequests() {
        let viewModel = TwelveSResultDisplaySectionViewModel()
        var requestedFormats: [TwelveSAmpliconResultExportFormat] = []
        viewModel.onExportRequested = { requestedFormats.append($0) }

        viewModel.export(format: .csv)
        viewModel.export(format: .tsv)
        viewModel.export(format: .excel)

        XCTAssertEqual(requestedFormats, [.csv, .tsv, .excel])
    }

    func testTaxonGroupOptionsAndIncludeExcludeControlsStayConsistent() {
        let viewModel = TwelveSResultDisplaySectionViewModel()

        viewModel.updateTaxonGroupOptions(["Mollusk", "Fish", ""])
        viewModel.setIncludedTaxonGroup("Fish", isIncluded: true)
        viewModel.setExcludedTaxonGroup("Fish", isExcluded: true)
        viewModel.setExcludedTaxonGroup("Mollusk", isExcluded: true)

        XCTAssertTrue(viewModel.taxonGroupOptions.contains("Mollusk"))
        XCTAssertFalse(viewModel.displayState.includedTaxonGroups.contains("Fish"))
        XCTAssertTrue(viewModel.displayState.excludedTaxonGroups.contains("Fish"))
        XCTAssertTrue(viewModel.displayState.excludedTaxonGroups.contains("Mollusk"))
    }
}
