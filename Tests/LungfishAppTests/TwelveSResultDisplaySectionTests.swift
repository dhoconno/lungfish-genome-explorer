import LungfishTwelveSUI
import XCTest
@testable import LungfishApp

@MainActor
final class TwelveSResultDisplaySectionTests: XCTestCase {
    func testTwelveSBlastPreparationCleanupRemovesStagingDirectory() throws {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-12s-blast-\(UUID().uuidString)", isDirectory: true)
        let exportURL = stagingDirectory.appendingPathComponent("unresolved-min5.fasta")
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data(">seq\nACGT\n".utf8).write(to: exportURL)
        try Data("{}".utf8).write(to: exportURL.appendingPathExtension("lungfish-provenance.json"))

        try ViewerViewController.removeTwelveSBlastPreparationArtifacts(for: exportURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

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

    func testTaxonPillTriStateReflectsDisplayState() {
        let viewModel = TwelveSResultDisplaySectionViewModel()

        XCTAssertEqual(viewModel.pillState(for: "Mammal"), .neutral)

        viewModel.setIncludedTaxonGroup("Mammal", isIncluded: true)
        XCTAssertEqual(viewModel.pillState(for: "Mammal"), .included)

        viewModel.setExcludedTaxonGroup("Mammal", isExcluded: true)   // mutual exclusivity: include cleared
        XCTAssertEqual(viewModel.pillState(for: "Mammal"), .excluded)
        XCTAssertTrue(viewModel.displayState.includedTaxonGroups.isEmpty)
    }

    func testCycleTaxonGroupAdvancesThroughTriStateViaExistingSetters() {
        let viewModel = TwelveSResultDisplaySectionViewModel()
        var deliveredStates: [TwelveSResultDisplayState] = []
        viewModel.onDisplayStateChanged = { deliveredStates.append($0) }

        // neutral -> included
        viewModel.cycleTaxonGroup("Fish")
        XCTAssertEqual(viewModel.pillState(for: "Fish"), .included)
        XCTAssertEqual(viewModel.displayState.includedTaxonGroups, ["Fish"])
        XCTAssertTrue(viewModel.displayState.excludedTaxonGroups.isEmpty)

        // included -> excluded (mutual exclusivity: include cleared)
        viewModel.cycleTaxonGroup("Fish")
        XCTAssertEqual(viewModel.pillState(for: "Fish"), .excluded)
        XCTAssertTrue(viewModel.displayState.includedTaxonGroups.isEmpty)
        XCTAssertEqual(viewModel.displayState.excludedTaxonGroups, ["Fish"])

        // excluded -> neutral
        viewModel.cycleTaxonGroup("Fish")
        XCTAssertEqual(viewModel.pillState(for: "Fish"), .neutral)
        XCTAssertTrue(viewModel.displayState.includedTaxonGroups.isEmpty)
        XCTAssertTrue(viewModel.displayState.excludedTaxonGroups.isEmpty)

        // Every cycle routes through the setters, so the change callback fired each time.
        XCTAssertEqual(deliveredStates.count, 3)
    }
}
