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

    func testMappingRowsOnDifferentTracksHaveDistinctIdentitiesAndVisibleTrackValues() {
        let table = MappingContigTableView()
        let original = row(sampleID: "S1", alignmentTrackID: "original-track")
        let filtered = row(sampleID: "S1", alignmentTrackID: "filtered-track")
        table.configure(rows: [original, filtered])

        XCTAssertNotEqual(table.rowIdentity(for: original), table.rowIdentity(for: filtered))
        XCTAssertEqual(
            table.tableView.tableColumns.map(\.identifier.rawValue).filter { $0 == "track" },
            ["track"]
        )
        XCTAssertEqual(table.columnValue(for: "track", row: original), "original-track")
        XCTAssertEqual(table.columnValue(for: "track", row: filtered), "filtered-track")
    }

    /// The Track column showed internal ids (aln_9A4D82BC) instead of the
    /// names the user gave the tracks.
    func testTrackColumnShowsDisplayNamesWithTheIDAsTooltip() {
        let table = MappingContigTableView()
        let unmarked = row(sampleID: "S1", alignmentTrackID: "aln_9A4D82BC")
        let marked = row(sampleID: "S1", alignmentTrackID: "aln_77E1F0AA")
        let unnamed = row(sampleID: "S1", alignmentTrackID: "aln_00000001")
        table.trackDisplayNamesByID = [
            "aln_9A4D82BC": "GUIverify custom track [unmarked]",
            "aln_77E1F0AA": "GUIverify custom track [dup-marked]",
        ]
        table.configure(rows: [unmarked, marked, unnamed])

        let track = NSUserInterfaceItemIdentifier("track")
        XCTAssertEqual(table.cellContent(for: track, row: unmarked).text, "GUIverify custom track [unmarked]")
        XCTAssertEqual(table.columnValue(for: "track", row: marked), "GUIverify custom track [dup-marked]")
        XCTAssertEqual(table.cellContent(for: track, row: unnamed).text, "aln_00000001", "no name falls back to the id")
        XCTAssertEqual(
            table.cellToolTip(for: track, row: unmarked),
            "GUIverify custom track [unmarked]\nTrack ID: aln_9A4D82BC"
        )
        XCTAssertTrue(table.rowMatchesFilter(marked, filterText: "dup-marked"))
        XCTAssertTrue(table.rowMatchesFilter(marked, filterText: "aln_77E1"))
        XCTAssertNotEqual(table.rowIdentity(for: unmarked), table.rowIdentity(for: marked))
    }

    private func row(
        sampleID: String?,
        alignmentTrackID: String? = nil,
        readGroupIDs: Set<String> = []
    ) -> MappingContigSummary {
        MappingContigSummary(
            sampleID: sampleID, alignmentTrackID: alignmentTrackID, readGroupIDs: readGroupIDs,
            contigName: "chr1", contigLength: 100, mappedReads: 10,
            mappedReadPercent: 10, meanDepth: 1, coverageBreadth: 1,
            medianMAPQ: 60, meanIdentity: 99
        )
    }
}
