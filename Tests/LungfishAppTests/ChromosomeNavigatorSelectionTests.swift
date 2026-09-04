import XCTest
import AppKit
import LungfishCore
@testable import LungfishApp

@MainActor
final class ChromosomeNavigatorSelectionTests: XCTestCase {
    private func chromosome(_ name: String, _ length: Int64) -> ChromosomeInfo {
        ChromosomeInfo(name: name, length: length, offset: 0, lineBases: 60, lineWidth: 61)
    }

    private func makeNavigator() -> ChromosomeNavigatorView {
        let navigator = ChromosomeNavigatorView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        navigator.chromosomes = [
            chromosome("seg1", 1741),
            chromosome("seg2", 1497),
            chromosome("seg3", 982),
        ]
        return navigator
    }

    func testMultipleRowsCanBeSelected() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0, 2])
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg1", "seg3"])
    }

    func testExtractItemIsFirstAndSeparatedFromTheCopyItems() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        let titles = navigator.testingContextMenuTitles(clickedRow: 0)
        XCTAssertEqual(titles.first, "Extract to New Bundle…")
        XCTAssertEqual(titles.dropFirst().first, "")
        XCTAssertTrue(titles.contains("Copy Name"))
    }

    func testExtractItemIsAbsentWhenNoHandlerIsWired() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0])
        XCTAssertFalse(navigator.testingContextMenuTitles(clickedRow: 0).contains("Extract to New Bundle…"))
    }

    func testRightClickOutsideTheSelectionTargetsTheClickedRowAlone() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        _ = navigator.testingContextMenuTitles(clickedRow: 2)
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg3"])
    }

    func testHandlerReceivesEverySelectedChromosome() {
        let navigator = makeNavigator()
        var received: [String] = []
        navigator.onExtractSelectedSequencesRequested = { received = $0.map(\.name) }
        navigator.testingSelectRows([0, 2])
        navigator.testingInvokeContextMenuItem(titled: "Extract to New Bundle…", clickedRow: 0)
        XCTAssertEqual(received, ["seg1", "seg3"])
    }
}
