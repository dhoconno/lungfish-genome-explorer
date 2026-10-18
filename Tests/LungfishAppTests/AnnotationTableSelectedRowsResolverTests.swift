// AnnotationTableSelectedRowsResolverTests.swift - Selected Rows writes the derived text the resolver gives
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B2), ARCH ruling on 12.39 R1 ("Selected Rows") and section 7 step 7. The All Matching
// export resolves the coding feature, consequence and amino-acid change through `VariantTableExportResolverSnapshot`,
// and the `bundle export-annotation-table` leaf will too. Selected Rows must write the same value for the same
// variant and cache, so one variant writes one value in either scope.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
import LungfishWorkflow

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

    /// A bundle whose one CDS (`test.1:0-9`, an alias of `test`) covers the variant at 3 and not the one at 20,
    /// a viewer that caches it with the sequence, and a variant drawer on the viewer with both rows selected.
    private func makeDrawer() throws -> (AnnotationTableDrawerView, ViewerViewController) {
        let manifest = BundleManifest(
            formatVersion: "1.0", name: "Synthetic", identifier: "synthetic",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(
                path: "sequence.fa", indexPath: "sequence.fa.fai", totalLength: 30,
                chromosomes: [ChromosomeInfo(
                    name: "test", length: 30, offset: 0, lineBases: 30, lineWidth: 31, aliases: ["test.1"]
                )]
            )
        )
        try manifest.save(to: root)
        try Data(">test\nATGAAATTTCCCGGGAAACCCTTTGGGAAA\n".utf8).write(to: root.appendingPathComponent("sequence.fa"))

        _ = NSApplication.shared
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.setReferenceBundle(ReferenceBundle(url: root, manifest: manifest))
        controller.viewerView.cachedBundleSequence = "ATGAAATTTCCCGGGAAACCCTTTGGGAAA"
        controller.viewerView.cachedSequenceRegion = GenomicRegion(chromosome: "test", start: 0, end: 30)
        var cds = SequenceAnnotation(
            type: .cds, name: "Synthetic CDS", chromosome: "test.1", start: 0, end: 9, strand: .forward
        )
        cds.qualifiers = ["gene": AnnotationQualifier("TEST"), "protein_id": AnnotationQualifier("protein-1")]
        controller.viewerView.cachedBundleAnnotations = [cds]

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

    private func resolverText(_ controller: ViewerViewController) throws -> [[String]] {
        let resolver = try controller.viewerView.variantTableExportResolverSnapshot().preparingForBackgroundExport()
        return [inside, outside].map { row in
            let fields = resolver.resolve(row)
            return [fields.codingFeature, fields.consequence, fields.aaChange]
        }
    }

    func testSelectedRowsDerivedTextEqualsTheResolver() throws {
        let (drawer, controller) = try makeDrawer()
        let expected = try resolverText(controller)
        XCTAssertEqual(expected[0], ["TEST • protein-1", "TEST • protein-1: missense_variant K2E", "K2E"],
                       "the CDS covers the first variant")
        XCTAssertEqual(expected[1], ["", "", ""], "and not the second")
        XCTAssertEqual(try selectedRowsText(drawer), expected)

        // Over the drawer's live computation limit the cells show a placeholder, which is rendered text, not a
        // value. The export writes what the resolver gives in either scope.
        drawer.lastVariantQueryMatchCount = AnnotationTableDrawerView.consequenceComputationRowLimit + 1
        XCTAssertEqual(try selectedRowsText(drawer), expected)
    }
}
