import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AnnotationTableExportSnapshotTests: XCTestCase {
    func testVariantCaptureUsesOneBasedNumericPositionFullPrecisionAndTrackQualifiedIdentity() throws {
        let variant = AnnotationSearchIndex.SearchResult(
            name: "NC_045512_29409",
            chromosome: "NC_045512.2",
            start: 29_408,
            end: 29_409,
            trackId: "ivar-track",
            trackName: "iVar",
            type: "SNP",
            ref: "C",
            alt: "T",
            quality: 99.123456,
            filter: "PASS",
            sampleCount: 1,
            variantRowId: 7,
            infoDict: ["AF": "0.999628", "ANN": "missense_variant"]
        )
        let columns = [
            ScientificTableColumn(id: "PositionColumn", title: "Position"),
            ScientificTableColumn(id: "info_AF", title: "AF"),
            ScientificTableColumn(id: "info_ANN", title: "ANN"),
        ]

        let snapshot = AnnotationTableExportSnapshot.captureVariants(
            [variant], columns: columns, scope: .selected,
            numericInfoColumnIDs: ["info_AF"], sourceURLs: [], queryDescription: [:]
        )

        XCTAssertEqual(snapshot.rowIdentities, ["ivar-track:7"])
        XCTAssertEqual(snapshot.table.columns[0].title, "Position (1-based)")
        XCTAssertEqual(snapshot.table.rows[0], [.integer(29_409), .number(0.999628), .text("missense_variant")])
        XCTAssertEqual(snapshot.coordinateConventions["PositionColumn"], "1-based genomic position")
    }

    func testAnnotationCaptureKeepsZeroBasedHalfOpenBoundariesAndFullIntegerLength() {
        let annotation = AnnotationSearchIndex.SearchResult(
            name: "N", chromosome: "NC_045512.2", start: 28_273, end: 29_533,
            trackId: "gff3", type: "gene", strand: "+", annotationRowId: 19
        )
        let columns = [
            ScientificTableColumn(id: "StartColumn", title: "Start"),
            ScientificTableColumn(id: "EndColumn", title: "End"),
            ScientificTableColumn(id: "SizeColumn", title: "Size"),
        ]

        let snapshot = AnnotationTableExportSnapshot.captureAnnotations(
            [annotation], columns: columns, scope: .allMatching,
            sourceURLs: [], queryDescription: [:]
        )

        XCTAssertEqual(snapshot.table.rows[0], [.integer(28_273), .integer(29_533), .integer(1_260)])
        XCTAssertEqual(snapshot.table.columns.map(\.title), ["Start (0-based)", "End (0-based, exclusive)", "Size (bp)"])
        XCTAssertEqual(snapshot.rowIdentities, ["gff3:19"])
    }

    func testSnapshotIsImmutableAfterSourceRowsAreReplaced() {
        var rows = [AnnotationSearchIndex.SearchResult(
            name: "before", chromosome: "chr1", start: 1, end: 2,
            trackId: "track", type: "gene", annotationRowId: 1
        )]
        let snapshot = AnnotationTableExportSnapshot.captureAnnotations(
            rows,
            columns: [.init(id: "NameColumn", title: "Name")],
            scope: .selected,
            sourceURLs: [],
            queryDescription: [:]
        )
        rows = [AnnotationSearchIndex.SearchResult(
            name: "after", chromosome: "chr1", start: 2, end: 3,
            trackId: "track", type: "gene", annotationRowId: 2
        )]

        XCTAssertEqual(snapshot.table.rows, [[.text("before")]])
        XCTAssertEqual(rows.first?.name, "after")
    }

    func testIntegerInfoDoesNotRoundThroughDouble() {
        let variant = AnnotationSearchIndex.SearchResult(
            name: "large", chromosome: "chr1", start: 1, end: 2,
            trackId: "track", type: "SNV", ref: "A", alt: "G",
            variantRowId: 1, infoDict: ["COUNT": "9007199254740993"]
        )
        let snapshot = AnnotationTableExportSnapshot.captureVariants(
            [variant], columns: [.init(id: "info_COUNT", title: "COUNT")],
            scope: .selected, numericInfoColumnIDs: [],
            integerInfoColumnIDs: ["info_COUNT"], sourceURLs: [], queryDescription: [:]
        )
        XCTAssertEqual(snapshot.table.rows, [[.integer(9_007_199_254_740_993)]])
    }
}
