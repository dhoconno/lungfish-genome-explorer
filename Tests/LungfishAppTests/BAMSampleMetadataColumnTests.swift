import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

@MainActor
final class BAMSampleMetadataColumnTests: XCTestCase {
    func testMappingRowsResolveMetadataUsingTheirCanonicalSample() throws {
        let table = MappingContigTableView()
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nS1\tcase\nS2\tcontrol\n".utf8),
            knownSampleIds: ["S1", "S2"]
        )
        table.metadataColumns.visibleColumns = ["Cohort"]
        table.metadataColumns.update(store: store, sampleId: nil)
        table.configure(rows: [
            row(sampleID: "S1"),
            row(sampleID: "S2"),
            row(sampleID: nil),
        ])

        let column = try XCTUnwrap(table.tableView.tableColumns.first { $0.identifier.rawValue == "metadata_Cohort" })
        XCTAssertEqual(
            (table.metadataColumns.cellForColumn(column, sampleId: table.displayedRows[0].sampleID) as? NSTableCellView)?.textField?.stringValue,
            "case"
        )
        XCTAssertEqual(
            (table.metadataColumns.cellForColumn(column, sampleId: table.displayedRows[1].sampleID) as? NSTableCellView)?.textField?.stringValue,
            "control"
        )
        XCTAssertEqual(
            (table.metadataColumns.cellForColumn(column, sampleId: table.displayedRows[2].sampleID) as? NSTableCellView)?.textField?.stringValue,
            "—"
        )
    }

    func testMappingRowIdentityIncludesCanonicalSample() {
        let table = MappingContigTableView()
        let s1 = row(sampleID: "S1")
        let s2 = row(sampleID: "S2")
        XCTAssertNotEqual(table.rowIdentity(for: s1), table.rowIdentity(for: s2))
        XCTAssertEqual(table.sampleId(for: s1), "S1")
    }

    private func row(sampleID: String?) -> MappingContigSummary {
        MappingContigSummary(
            sampleID: sampleID, contigName: "chr1", contigLength: 100, mappedReads: 10,
            mappedReadPercent: 10, meanDepth: 1, coverageBreadth: 1,
            medianMAPQ: 60, meanIdentity: 99
        )
    }
}
