import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class MetagenomicsColumnResizeRegressionTests: XCTestCase {
    func testColumnManagerAllowsZeroWidthAndRestoresDefaultWidth() {
        let scrollView = NSScrollView()
        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        scrollView.documentView = tableView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.width = 140
        column.minWidth = 90
        column.maxWidth = 220
        tableView.addTableColumn(column)

        let controller = MetadataColumnController()
        controller.install(on: tableView)

        XCTAssertTrue(tableView.allowsColumnResizing)
        XCTAssertEqual(tableView.columnAutoresizingStyle, .noColumnAutoresizing)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertEqual(column.minWidth, 0)
        XCTAssertGreaterThan(column.maxWidth, 10_000)

        column.width = 0
        controller.testingSyncDisabledColumnsFromWidths()

        XCTAssertTrue(column.isHidden)

        controller.testingSetStandardColumnVisible(id: "name", visible: true)

        XCTAssertFalse(column.isHidden)
        XCTAssertEqual(column.width, 140)
    }

    func testEsVirituCoverageLookupIsSampleScoped() {
        let tableView = ViralDetectionTableView()
        let sampleOneWindows = [
            ViralCoverageWindow(accession: "NC_001", windowIndex: 0, windowStart: 0, windowEnd: 100, averageCoverage: 2.0),
            ViralCoverageWindow(accession: "NC_001", windowIndex: 1, windowStart: 100, windowEnd: 200, averageCoverage: 8.0),
        ]
        let sampleTwoWindows = [
            ViralCoverageWindow(accession: "NC_001", windowIndex: 0, windowStart: 0, windowEnd: 100, averageCoverage: 14.0),
            ViralCoverageWindow(accession: "NC_001", windowIndex: 1, windowStart: 100, windowEnd: 200, averageCoverage: 1.0),
        ]

        tableView.setCoverageWindows(sampleOneWindows, sampleId: "S1", accession: "NC_001")
        tableView.setCoverageWindows(sampleTwoWindows, sampleId: "S2", accession: "NC_001")

        XCTAssertEqual(
            tableView.testingCoverageWindows(sampleId: "S1", accession: "NC_001").map(\.averageCoverage),
            [2.0, 8.0]
        )
        XCTAssertEqual(
            tableView.testingCoverageWindows(sampleId: "S2", accession: "NC_001").map(\.averageCoverage),
            [14.0, 1.0]
        )
    }

    func testMiniBAMIncludesDuplicateFlaggedReadsButCountsUniqueFingerprints() {
        let reads = [
            makeRead(name: "dup-1", flag: 0x400, position: 10),
            makeRead(name: "dup-2", flag: 0x400, position: 10),
        ]

        let display = MiniBAMViewController.testingDisplayReadsAndUniqueCount(from: reads, readNameAllowlist: nil)

        XCTAssertEqual(display.reads.count, 2)
        XCTAssertEqual(display.uniqueReadCount, 1)
    }

    func testReportedEsVirituRowsNeverNormalizeUniqueReadsToZero() {
        XCTAssertEqual(BatchEsVirituRow.normalizedUniqueReads(stored: nil, readCount: 4), 1)
        XCTAssertEqual(BatchEsVirituRow.normalizedUniqueReads(stored: 0, readCount: 4), 1)
        XCTAssertEqual(BatchEsVirituRow.normalizedUniqueReads(stored: 7, readCount: 4), 7)
        XCTAssertEqual(BatchEsVirituRow.normalizedUniqueReads(stored: 0, readCount: 0), 0)
    }

    private func makeRead(name: String, flag: UInt16, position: Int) -> AlignedRead {
        AlignedRead(
            name: name,
            flag: flag,
            chromosome: "NC_001",
            position: position,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: UInt8(35), count: 100),
            mdTag: "100"
        )
    }
}
