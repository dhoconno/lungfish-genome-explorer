// AnnotationTableSelectedRowsResolverTests.swift - Selected Rows writes the derived text the resolver gives
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B2), ARCH ruling on 12.39 R1 ("Selected Rows") and section 7 step 7. The All Matching
// export resolves the coding feature, consequence and amino-acid change through `VariantTableExportResolverSnapshot`,
// and the `bundle export-annotation-table` leaf will too. Selected Rows must write the same value for the same
// variant and cache, so one variant writes one value in either scope.
//
// Phase 2.13 lane 13.38 (decision MD49, BIO Fix 2 and UX Fix 1 of the 13.38 reviews). Since dd1ee29a4 the drawer reads
// the CDS from the bundle's annotation databases over the exported rows, as the leaf does. The CDS of this test lives
// only in `annotations/cds.db` and the viewer caches none, so the cells pin the bundle read and not the cache.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
@testable import LungfishWorkflow

@MainActor
final class AnnotationTableSelectedRowsResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableSelectedRows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let inside = AnnotationSearchIndex.SearchResult(
        name: "in", chromosome: "test", start: 3, end: 4, trackId: "calls", type: "SNP",
        ref: "A", alt: "G", variantRowId: 1
    )
    private let outside = AnnotationSearchIndex.SearchResult(
        name: "out", chromosome: "test", start: 20, end: 21, trackId: "calls", type: "SNP",
        ref: "C", alt: "A", variantRowId: 2
    )

    /// A bundle whose one CDS (`test.1:0-9`, an alias of `test`) sits in its annotation database `annotations/cds.db`
    /// and covers the variant at 3 and not the one at 20, a viewer that caches the sequence and no annotation, and a
    /// variant drawer on the viewer with both rows selected. The sequence file has its header line `>test` before the
    /// bases, so the chromosome starts at byte 6 and the index file says so.
    private func makeDrawer() throws -> (AnnotationTableDrawerView, ViewerViewController) {
        let manifest = BundleManifest(
            formatVersion: "1.0", name: "Synthetic", identifier: "synthetic",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(
                path: "sequence.fa", indexPath: "sequence.fa.fai", totalLength: 30,
                chromosomes: [ChromosomeInfo(
                    name: "test", length: 30, offset: 6, lineBases: 30, lineWidth: 31, aliases: ["test.1"]
                )]
            ),
            annotations: [
                AnnotationTrackInfo(id: "cds", name: "CDS", path: "annotations/cds.bb", databasePath: "annotations/cds.db"),
            ]
        )
        try manifest.save(to: root)
        try Data(">test\nATGAAATTTCCCGGGAAACCCTTTGGGAAA\n".utf8).write(to: root.appendingPathComponent("sequence.fa"))
        try "test\t30\t6\t30\t31\n".write(
            to: root.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("annotations"), withIntermediateDirectories: true
        )
        let bed = root.appendingPathComponent("cds.bed")
        try "test.1\t0\t9\tprotein-1\t0\t+\t0\t9\t0,0,0\t1\t9\t0\tCDS\tgene=TEST\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: root.appendingPathComponent("annotations/cds.db"))
        try FileManager.default.removeItem(at: bed)

        _ = NSApplication.shared
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.setReferenceBundle(ReferenceBundle(url: root, manifest: manifest))
        controller.viewerView.cachedBundleSequence = "ATGAAATTTCCCGGGAAACCCTTTGGGAAA"
        controller.viewerView.cachedSequenceRegion = GenomicRegion(chromosome: "test", start: 0, end: 30)

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        drawer.delegate = controller
        drawer.searchIndex = AnnotationSearchIndex()
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.configureColumnsForTab(.variants)
        drawer.displayedAnnotations = [inside, outside]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        return (drawer, controller)
    }

    /// The derived cells the Selected Rows export writes, by row, as coding feature, consequence, amino-acid change.
    private func selectedRowsText(_ drawer: AnnotationTableDrawerView) throws -> [[String]] {
        let snapshot = try drawer.captureScientificTableExport(scope: .selected).collect { false }
        let ids = [
            AnnotationTableDrawerView.codingFeatureColumn, AnnotationTableDrawerView.consequenceColumn,
            AnnotationTableDrawerView.aaChangeColumn,
        ].map(\.rawValue)
        let indices = try ids.map { id in
            try XCTUnwrap(snapshot.table.columns.firstIndex { $0.id == id }, "the export writes \(id)")
        }
        return snapshot.table.rows.map { cells in
            indices.map { index -> String in
                if case .text(let value) = cells[index] { return value }
                return ""
            }
        }
    }

    func testSelectedRowsDerivedTextEqualsTheResolver() throws {
        let (drawer, controller) = try makeDrawer()
        defer { withExtendedLifetime(controller) {} }
        // The viewer caches no CDS, so a row can only get its cells from the bundle's annotation database. A drawer
        // that still read the viewer's cache would write blank cells for the first row.
        let expected = [
            ["TEST • protein-1", "TEST • protein-1: missense_variant K2E", "K2E"],  // the CDS covers the first variant
            ["", "", ""],  // and not the second
        ]
        XCTAssertEqual(try selectedRowsText(drawer), expected)

        // V1-1 item 2. A written derived column makes the selection name the bundle's CDS tracks and no region, and
        // the record says where the cells were read.
        let pending = try drawer.captureAnnotationTableExport(scope: .selected)
        XCTAssertEqual(pending.tableSelection.bundleCodingFeatureTrackIDs, ["cds"])
        XCTAssertNil(pending.tableSelection.codingFeatureRegion)
        let query = try pending.collect { false }.queryDescription
        XCTAssertEqual(
            query["derivedVariantResolutionScope"], AnnotationTableVariantQueryRequest.bundleCodingFeatureResolutionScope
        )
        XCTAssertNil(query["derivedVariantFeatureCount"])

        // Over the drawer's live computation limit the cells show a placeholder, which is rendered text, not a
        // value. The export writes what the resolver gives in either scope.
        drawer.lastVariantQueryMatchCount = AnnotationTableDrawerView.consequenceComputationRowLimit + 1
        XCTAssertEqual(try selectedRowsText(drawer), expected)
    }
}
