import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class GenBankAccessionImportViewTests: XCTestCase {
    func testImportControlIsAvailableOnlyForNucleotideAndDisabledWhileBusy() throws {
        let model = DatabaseBrowserViewModel(source: .ncbi)
        let view = GenBankGenomesSearchPane(viewModel: model)
        XCTAssertFalse(try view.inspect().find(button: "Import Accessions").isDisabled())
        model.searchPhase = .connecting
        XCTAssertTrue(try view.inspect().find(button: "Import Accessions").isDisabled())
        model.searchPhase = .idle
        model.isDownloading = true
        XCTAssertTrue(try view.inspect().find(button: "Import Accessions").isDisabled())
        model.isDownloading = false
        model.ncbiSearchType = .genome
        XCTAssertThrowsError(try view.inspect().find(button: "Import Accessions"))
        model.ncbiSearchType = .virus
        XCTAssertThrowsError(try view.inspect().find(button: "Import Accessions"))
    }

    func testGenBankSelectAllButtonSelectsOnlyFilteredLoadedRowsAndShowsCount() throws {
        let model = DatabaseBrowserViewModel(source: .ncbi)
        model.results = [
            SearchResultRecord(id: "1", accession: "NM_000546.6", title: "Visible TP53 transcript", source: .ncbi),
            SearchResultRecord(id: "2", accession: "NM_000059.4", title: "Hidden BRCA2 transcript", source: .ncbi),
        ]
        model.totalResultCount = 2000
        model.hasMoreResults = true
        model.localFilterText = "Visible"
        let view = GenBankGenomesSearchPane(viewModel: model)
        try view.inspect().find(button: "Select all").tap()
        XCTAssertEqual(model.selectedRecords.map(\.accession), ["NM_000546.6"])
        XCTAssertEqual(model.results.count, 2)
        XCTAssertTrue(model.hasMoreResults)
        XCTAssertNoThrow(try view.inspect().find(text: "1 selected"))
        try view.inspect().find(button: "Deselect all").tap()
        XCTAssertTrue(model.selectedRecords.isEmpty)
    }

    func testNucleotidePaneRendersAtDialogSize() throws {
        let model = DatabaseBrowserViewModel(source: .ncbi)
        model.searchText = "NM_000546.6, NM_000059.4"
        model.searchScope = .accession
        model.results = [
            SearchResultRecord(id: "NM_000546.6", accession: "NM_000546.6", title: "Human TP53 transcript", length: 1200, source: .ncbi),
            SearchResultRecord(id: "NM_000059.4", accession: "NM_000059.4", title: "Human BRCA2 transcript", length: 2400, source: .ncbi),
        ]
        let host = NSHostingView(rootView: GenBankGenomesSearchPane(viewModel: model))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 720)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        if let path = ProcessInfo.processInfo.environment["LUNGFISH_GENBANK_UI_SNAPSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testSRAStillExposesItsImportControl() throws {
        let model = DatabaseBrowserViewModel(source: .ena)
        XCTAssertNoThrow(try SRARunsSearchPane(viewModel: model).inspect().find(button: "Import Accessions"))
    }
}
