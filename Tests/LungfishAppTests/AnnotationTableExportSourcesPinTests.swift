// AnnotationTableExportSourcesPinTests.swift - What side A's annotation table export names as its inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B2), ARCH ruling on 12.39 R1 ("What the record names") and section 7 step 6, settled
// answers G3 and M4. Side A's record names, beside its retained copy, what the leaf will read for the tab. The
// bundle's manifest, then the annotation databases of the tracks the rows name on the annotations tab, or every
// variant database on the samples tab. At c998d3ce1 the drawer named every database on every tab and the manifest
// only on the variants tab, so both pins fail there.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow

@MainActor
final class AnnotationTableExportSourcesPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Answers the drawer's export questions as `ViewerViewController` does, with the manifest and the genome.
    private final class BundleFilesDelegate: AnnotationTableDrawerDelegate {
        let files: [URL]
        init(files: [URL]) { self.files = files }

        func annotationDrawerAdditionalExportSources(_ drawer: AnnotationTableDrawerView) throws -> [URL] { files }
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotations annotations: [AnnotationSearchIndex.SearchResult]) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotationTrack trackID: String, trackName: String) {}
        func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {}
        func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}
        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
        ) -> (consequence: String?, aaChange: String?) { (nil, nil) }
    }

    /// A bundle folder with annotation track `a`, variant track `v`, its manifest and a genome file, and a drawer
    /// on its search index whose delegate gives the manifest and the genome.
    private func makeDrawer() throws -> (drawer: AnnotationTableDrawerView, delegate: BundleFilesDelegate) {
        let bed = root.appendingPathComponent("annotations.bed")
        try "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\t.\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: root.appendingPathComponent("annotations.db"))
        try FileManager.default.removeItem(at: bed)
        let vcf = root.appendingPathComponent("variants.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t200\trs1\tA\tG\t30\tPASS\t.\n"
            .write(to: vcf, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: root.appendingPathComponent("variants.db"))
        try FileManager.default.removeItem(at: vcf)
        try Data("genome".utf8).write(to: root.appendingPathComponent("s.fa.gz"))
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1000, chromosomes: []),
            annotations: [AnnotationTrackInfo(id: "a", name: "A", path: "a.bb", databasePath: "annotations.db")],
            variants: [VariantTrackInfo(id: "v", name: "V", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        try manifest.save(to: root)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: ReferenceBundle(url: root, manifest: manifest), trackId: "a", databasePath: "annotations.db")
        XCTAssertEqual(index.annotationDatabaseHandles.map(\.trackId), ["a"])
        XCTAssertEqual(index.variantDatabaseHandles.map(\.trackId), ["v"])

        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = index
        let delegate = BundleFilesDelegate(files: [
            root.appendingPathComponent(BundleManifest.filename), root.appendingPathComponent("s.fa.gz"),
        ])
        drawer.delegate = delegate
        return (drawer, delegate)
    }

    private func sourcePaths(_ drawer: AnnotationTableDrawerView) throws -> [String] {
        let pending = try drawer.captureScientificTableExport(scope: .allMatching)
        return try pending.collect { false }.sourceURLs.map(\.standardizedFileURL.path)
    }

    private func paths(_ names: String...) -> [String] {
        names.map { root.appendingPathComponent($0).standardizedFileURL.path }
    }

    func testAnnotationTabNamesTheManifestAndTheDatabasesOfTheRowsTracks() throws {
        let (drawer, delegate) = try makeDrawer()
        drawer.activeTab = .annotations
        let paths = try sourcePaths(drawer)
        withExtendedLifetime(delegate) {}
        XCTAssertEqual(paths, self.paths(BundleManifest.filename, "annotations.db"))
    }

    func testSampleTabNamesTheManifestAndEveryVariantDatabase() throws {
        let (drawer, delegate) = try makeDrawer()
        drawer.activeTab = .samples
        let paths = try sourcePaths(drawer)
        withExtendedLifetime(delegate) {}
        XCTAssertEqual(paths, self.paths(BundleManifest.filename, "variants.db"))
    }

    /// The rule of each tab over two tracks of each kind, an overlay VCF and the derived columns' tracks.
    func testEachTabNamesOnlyTheFilesItsRowsCameFrom() throws {
        for name in ["manifest.json", "a1.db", "a2.db", "v1.db", "v2.db", "v1.vcf", "s.fa.gz"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        func track(_ id: String) -> AnnotationTableExportSources.Track {
            .init(trackID: id, url: root.appendingPathComponent("\(id).db"))
        }
        var sources = AnnotationTableExportSources(
            manifestURL: root.appendingPathComponent("manifest.json"),
            genomeURL: root.appendingPathComponent("s.fa.gz"),
            annotationDatabases: [track("a1"), track("a2")],
            variantDatabases: [track("v1"), track("v2")],
            overlayURLsByTrack: ["v1": [root.appendingPathComponent("v1.vcf")]],
            codingFeatureTrackIDs: nil
        )
        func urls(_ tab: String, _ ids: Set<String>) throws -> [String] {
            try sources.urls(tab: tab, trackIDs: ids).map(\.standardizedFileURL.path)
        }
        XCTAssertEqual(try urls("annotations", ["a1"]), paths("manifest.json", "a1.db"))
        XCTAssertEqual(try urls("variants", ["v1"]), paths("manifest.json", "v1.db", "v1.vcf"))
        XCTAssertEqual(try urls("genotypes", ["v2"]), paths("manifest.json", "v2.db"))
        XCTAssertEqual(try urls("samples", []), paths("manifest.json", "v1.db", "v2.db"))
        sources.codingFeatureTrackIDs = ["a2"]
        XCTAssertEqual(try urls("variants", ["v1"]), paths("manifest.json", "a2.db", "v1.db", "v1.vcf", "s.fa.gz"))
        XCTAssertEqual(try urls("annotations", ["a1"]), paths("manifest.json", "a1.db"), "only the variants tab reads the CDS")
    }
}
