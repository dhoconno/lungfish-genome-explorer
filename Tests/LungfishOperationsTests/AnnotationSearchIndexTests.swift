// AnnotationSearchIndexTests.swift - When the annotation search index builds its alias groups
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations

@MainActor
final class AnnotationSearchIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestTempDirectory.make(prefix: "annotation-search-index")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
        root = nil
        super.tearDown()
    }

    /// RefSeq chromosomes with UCSC and Ensembl aliases, the naming mismatch the
    /// alias groups exist to bridge.
    private let chromosomes = [
        ChromosomeInfo(name: "NC_000001.11", length: 1_000, offset: 0, lineBases: 60, lineWidth: 61, aliases: ["chr1", "1"]),
        ChromosomeInfo(name: "NC_000002.12", length: 1_000, offset: 1_100, lineBases: 60, lineWidth: 61, aliases: ["chr2", "2"]),
    ]

    private func makeBundle(annotations: [AnnotationTrackInfo]) -> ReferenceBundle {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Alias groups",
            identifier: "test.alias-groups",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 2_000, chromosomes: chromosomes),
            annotations: annotations,
            variants: []
        )
        return ReferenceBundle(url: root, manifest: manifest)
    }

    /// A reference without annotation or variant tracks, like the 905,628-sequence
    /// bundle that spent 5.5 seconds and 1,264 MB on alias groups nothing read,
    /// builds none, even when the viewer runs the lookups that would read them.
    func testNoAliasMapsWithoutAnnotationOrVariantTracks() async {
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: makeBundle(annotations: []), chromosomes: chromosomes)

        XCTAssertTrue(index.queryAnnotationsInRegion(chromosome: "chr1", start: 0, end: 500).isEmpty)
        XCTAssertTrue(index.queryVariantsInRegion(chromosome: "chr1", start: 0, end: 500).isEmpty)
        XCTAssertEqual(index.queryVariantCountInRegion(chromosome: "chr1", start: 0, end: 500), 0)
        let offMain = await index.queryVariantsInRegionOffMain(chromosome: "chr1", start: 0, end: 500)
        XCTAssertTrue(offMain.isEmpty)
        let selected = AnnotationSearchIndex.SearchResult(name: "BRCA1", chromosome: "chr1", start: 100, end: 500, trackId: "a")
        XCTAssertNil(index.lookupSequenceAnnotation(for: selected))
        XCTAssertEqual(index.aliasMapBuildCount, 0)
    }

    /// With an annotation track the groups are built on the first lookup, once, and
    /// still find a feature the track files under an alias of the bundle's name.
    func testAliasMapsBuildOnFirstLookupWithAnnotationTrack() throws {
        let bedURL = root.appendingPathComponent("annotations.bed")
        try "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\t.".write(
            to: bedURL, atomically: true, encoding: .utf8
        )
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: root.appendingPathComponent("annotations.db"))
        let bundle = makeBundle(annotations: [
            AnnotationTrackInfo(id: "a", name: "Annotations", path: "a.bb", databasePath: "annotations.db"),
        ])
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: bundle, chromosomes: chromosomes)
        XCTAssertEqual(index.aliasMapBuildCount, 0, "Opening the bundle builds no alias groups")

        let found = index.queryAnnotationsInRegion(chromosome: "NC_000001.11", start: 0, end: 1_000)
        XCTAssertEqual(found.map(\.name), ["BRCA1"], "The bundle's NC_000001.11 is the track's chr1")
        XCTAssertEqual(index.aliasMapBuildCount, 1)

        XCTAssertTrue(index.queryAnnotationsInRegion(chromosome: "NC_000002.12", start: 0, end: 1_000).isEmpty)
        XCTAssertEqual(index.aliasMapBuildCount, 1, "Later lookups reuse the groups")
    }
}
