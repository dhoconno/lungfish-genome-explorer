import XCTest
import AppKit
import LungfishIO
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSTableViewTests: XCTestCase {

    private func makeTargetRow(
        name: String,
        taxids: [String] = [],
        sampleCounts: [String: Int] = ["s1": 10],
        totals: [String: Int] = ["s1": 100],
        targetIDs: [String] = ["t1"]
    ) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(
            scientificName: name,
            commonNames: [],
            targetIDs: targetIDs,
            sampleCounts: sampleCounts,
            sampleExactReadTotals: totals,
            taxids: taxids
        )
    }

    func testTargetColumnsAndCellText() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Homo sapiens", taxids: ["9606"],
                                sampleCounts: ["s1": 42], totals: ["s1": 100])
        XCTAssertEqual(
            table.cellContent(for: .init("scientificName"), row: row).text,
            "Homo sapiens"
        )
        XCTAssertEqual(table.cellContent(for: .init("totalExactReads"), row: row).text, "42")
        XCTAssertEqual(table.cellContent(for: .init("referenceTargets"), row: row).text, "1")
        XCTAssertEqual(table.cellContent(for: .init("taxids"), row: row).text, "9606")
        // numeric columns declared numeric for the kernel filter menus
        XCTAssertEqual(table.columnTypeHints["totalExactReads"], true)
        XCTAssertEqual(table.columnTypeHints["scientificName"], nil)
    }

    func testTargetSortByExactReadsDescending() {
        let table = TwelveSTargetTableView()
        let low = makeTargetRow(name: "Low", sampleCounts: ["s1": 5])
        let high = makeTargetRow(name: "High", sampleCounts: ["s1": 50])
        // ascending == false means higher first
        XCTAssertTrue(table.compareRows(high, low, by: "totalExactReads", ascending: false))
        XCTAssertFalse(table.compareRows(low, high, by: "totalExactReads", ascending: false))
    }

    func testTargetFreeTextFilterMatchesName() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Gallus gallus")
        XCTAssertTrue(table.rowMatchesFilter(row, filterText: "gallus"))
        XCTAssertFalse(table.rowMatchesFilter(row, filterText: "salmon"))
    }

    // MARK: - Unresolved

    private func makeUnresolved(
        id: String, reads: Int, sequence: String = "ACGT",
        sampleCounts: [String: Int] = ["s1": 1],
        chimera: TwelveSChimeraStatus = .notReviewed
    ) -> TwelveSUnresolvedSequence {
        TwelveSUnresolvedSequence(sequenceID: id, sequence: sequence, readCount: reads,
                                  sampleCounts: sampleCounts, chimeraStatus: chimera)
    }

    func testUnresolvedColumnsAndCellText() {
        let table = TwelveSUnresolvedTableView()
        let row = makeUnresolved(id: "cluster-1", reads: 7, sequence: "ACGTAC",
                                 sampleCounts: ["s1": 4, "s2": 0])
        XCTAssertEqual(table.cellContent(for: .init("sequenceID"), row: row).text, "cluster-1")
        XCTAssertEqual(table.cellContent(for: .init("readCount"), row: row).text, "7")
        XCTAssertEqual(table.cellContent(for: .init("sampleCount"), row: row).text, "1") // s2 == 0 excluded
        XCTAssertEqual(table.cellContent(for: .init("sequence"), row: row).text, "ACGTAC")
        XCTAssertEqual(table.columnTypeHints["readCount"], true)
    }

    func testUnresolvedSortByReadsDescending() {
        let table = TwelveSUnresolvedTableView()
        let a = makeUnresolved(id: "a", reads: 3)
        let b = makeUnresolved(id: "b", reads: 30)
        XCTAssertTrue(table.compareRows(b, a, by: "readCount", ascending: false))
    }
}
