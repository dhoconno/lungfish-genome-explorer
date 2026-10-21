// AnnotationTableDrawerBundleCDSTests.swift - The drawer's All Matching export reads the bundle's CDS, not the cache
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.38 (decision MD49, UX Fix 2 and BIO Fix 3 of the 13.38 reviews). The parity tests set the
// request's `readsBundleCodingFeatures` and the selection's track ids by hand. These tests go through the drawer's own
// export wiring (`AnnotationTableDrawerView+ExportCapture` and `+TableExportBegin`) with a viewer whose cache holds no
// CDS, so only the bundle read of V1-1 item 7 can give the cells and the sort their values.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
@testable import LungfishWorkflow

@MainActor
final class AnnotationTableDrawerBundleCDSTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableDrawerBundleCDS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A bundle of chr1 (30 bases, ATG AAA TTT CCC ...) whose one CDS `protein-1` of gene TEST covers bases 0 to 9 and
    /// sits in the annotation database `annotations/cds.db`, a variant database with two SNPs at bases 6 and 7 (1-based)
    /// of it, a viewer that caches no annotation, and a variant drawer on the viewer and on a search index of the
    /// bundle. The sequence file has its header line `>chr1` before the bases, so the chromosome starts at byte 6.
    private func makeDrawer() throws -> (AnnotationTableDrawerView, ViewerViewController) {
        let manifest = BundleManifest(
            formatVersion: "1.0", name: "Synthetic", identifier: "synthetic",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(
                path: "sequence.fa", indexPath: "sequence.fa.fai", totalLength: 30,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 30, offset: 6, lineBases: 30, lineWidth: 31)]
            ),
            annotations: [
                AnnotationTrackInfo(id: "cds", name: "CDS", path: "annotations/cds.bb", databasePath: "annotations/cds.db"),
            ],
            variants: [VariantTrackInfo(id: "v", name: "V", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        try manifest.save(to: root)
        try Data(">chr1\nATGAAATTTCCCGGGAAACCCTTTGGGAAA\n".utf8).write(to: root.appendingPathComponent("sequence.fa"))
        try "chr1\t30\t6\t30\t31\n".write(
            to: root.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("annotations"), withIntermediateDirectories: true
        )
        let bed = root.appendingPathComponent("cds.bed")
        try "chr1\t0\t9\tprotein-1\t0\t+\t0\t9\t0,0,0\t1\t9\t0\tCDS\tgene=TEST\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: root.appendingPathComponent("annotations/cds.db"))
        try FileManager.default.removeItem(at: bed)
        let vcf = root.appendingPathComponent("variants.vcf")
        try ("##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
            + "chr1\t6\t.\tA\tG\t30\tPASS\t.\nchr1\t7\t.\tT\tA\t30\tPASS\t.\n")
            .write(to: vcf, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: root.appendingPathComponent("variants.db"))
        try FileManager.default.removeItem(at: vcf)

        _ = NSApplication.shared
        let bundle = ReferenceBundle(url: root, manifest: manifest)
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.setReferenceBundle(bundle)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: bundle, trackId: "cds", databasePath: "annotations/cds.db")
        XCTAssertEqual(index.variantDatabaseHandles.map(\.trackId), ["v"])

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        drawer.delegate = controller
        drawer.searchIndex = index
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.configureColumnsForTab(.variants)
        return (drawer, controller)
    }

    /// The coding feature, consequence and amino-acid change cells of each exported row, in written order.
    private func derivedCells(_ snapshot: AnnotationTableExportSnapshot) throws -> [[String]] {
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

    /// F7 and V1-1 item 7. The two SNPs sit in codons 2 and 3 of the CDS ATG AAA TTT (M K F). The one at base 6 turns
    /// AAA into AAG, which still codes K (synonymous), and the one at base 7 turns TTT into ATT, which codes I for F
    /// (missense). Position order is the reverse of the order of the Consequence text, where `missense_variant`
    /// precedes `synonymous_variant`. The viewer caches no CDS, so a sort that read the cache would see two empty
    /// cells, tie, and leave position order. All Matching sorted by Consequence writes the rows in the order of their
    /// cells, and both cells come from the bundle.
    func testAllMatchingDerivedSortReadsTheBundleOutsideTheCache() throws {
        let (drawer, controller) = try makeDrawer()
        defer { withExtendedLifetime(controller) {} }
        // The sort key of the Consequence column (`+Columns.swift`), which the request's derived step matches by name.
        let sortKey = "consequence"
        drawer.tableView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: true)]
        let snapshot = try drawer.captureScientificTableExport(scope: .allMatching).collect { false }
        XCTAssertEqual(snapshot.queryDescription["sort"], "\(sortKey):ascending")
        XCTAssertEqual(try derivedCells(snapshot), [
            ["TEST • protein-1", "TEST • protein-1: missense_variant F3I", "F3I"],
            ["TEST • protein-1", "TEST • protein-1: synonymous_variant K2K", "K2K"],
        ])
    }

    /// V1-1 item 2. The All Matching selection names every annotation track of the bundle that has a database, and
    /// no region, and the record says where the cells were read.
    func testAllMatchingSelectionNamesTheBundleTracksAndNoRegion() throws {
        let (drawer, controller) = try makeDrawer()
        defer { withExtendedLifetime(controller) {} }
        let pending = try drawer.captureAnnotationTableExport(scope: .allMatching)
        XCTAssertEqual(pending.tableSelection.bundleCodingFeatureTrackIDs, ["cds"])
        XCTAssertNil(pending.tableSelection.codingFeatureRegion)
        let query = try pending.collect { false }.queryDescription
        XCTAssertEqual(
            query["derivedVariantResolutionScope"], AnnotationTableVariantQueryRequest.bundleCodingFeatureResolutionScope
        )
        XCTAssertNil(query["derivedVariantFeatureCount"])
    }
}
