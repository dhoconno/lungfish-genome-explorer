// AnnotationSearchIndexTests.swift - When the annotation search index builds its alias groups
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations

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
    @MainActor func testNoAliasMapsWithoutAnnotationOrVariantTracks() async {
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
    @MainActor func testAliasMapsBuildOnFirstLookupWithAnnotationTrack() throws {
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

    // MARK: - Variant tracks

    /// One chromosome under two names, the RefSeq accession the bundle calls it and the UCSC
    /// name its variant track files the rows under, beside a chromosome with no variants.
    private let variantBundleChromosomes = [
        ChromosomeInfo(name: "NC_000001.11", length: 1_000, offset: 0, lineBases: 60, lineWidth: 61, aliases: ["chr1"]),
        ChromosomeInfo(name: "NC_000002.12", length: 1_000, offset: 1_100, lineBases: 60, lineWidth: 61, aliases: ["chr2"]),
    ]

    /// A bundle with one variant track whose two rows sit on `chr1`, at 150 and 250.
    private func makeVariantBundle() throws -> ReferenceBundle {
        let vcfURL = root.appendingPathComponent("variants.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs111\tA\tG\t50.0\tPASS\t.
        chr1\t250\trs222\tAT\tA\t35.0\tPASS\t.
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: root.appendingPathComponent("variants.db"))
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Variant alias groups",
            identifier: "test.variant-alias-groups",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 2_000, chromosomes: variantBundleChromosomes),
            annotations: [],
            variants: [VariantTrackInfo(id: "v", name: "Variants", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        return ReferenceBundle(url: root, manifest: manifest)
    }

    /// Variants filed under `chr1` answer to the bundle's `NC_000001.11` through the alias
    /// groups, in the synchronous queries and in the off-main ones. Each kind of query is the
    /// first to ask on an index of its own, so neither can lean on groups the other built.
    @MainActor func testVariantQueriesFindVariantsFiledUnderAnAliasOfTheBundleName() async throws {
        let bundle = try makeVariantBundle()

        let syncIndex = AnnotationSearchIndex()
        syncIndex.buildIndex(bundle: bundle, chromosomes: variantBundleChromosomes)
        let syncResults = syncIndex.queryVariantsInRegion(chromosome: "NC_000001.11", start: 0, end: 1_000)
        XCTAssertEqual(syncResults.map(\.name).sorted(), ["rs111", "rs222"], "The rows filed under chr1 answer to NC_000001.11")
        XCTAssertEqual(syncIndex.queryVariantCountInRegion(chromosome: "NC_000001.11", start: 0, end: 1_000), 2)
        XCTAssertTrue(
            syncIndex.queryVariantsInRegion(chromosome: "NC_000002.12", start: 0, end: 1_000).isEmpty,
            "A chromosome with another alias group finds none of them"
        )

        let offMainIndex = AnnotationSearchIndex()
        offMainIndex.buildIndex(bundle: bundle, chromosomes: variantBundleChromosomes)
        let offMainResults = await offMainIndex.queryVariantsInRegionOffMain(chromosome: "NC_000001.11", start: 0, end: 1_000)
        let offMainCount = await offMainIndex.queryVariantCountInRegionOffMain(chromosome: "NC_000001.11", start: 0, end: 1_000)

        XCTAssertEqual(offMainResults.count, 2)
        XCTAssertEqual(offMainResults.map(\.name), syncResults.map(\.name))
        XCTAssertEqual(offMainResults.map(\.start), syncResults.map(\.start))
        XCTAssertEqual(offMainResults.map(\.end), syncResults.map(\.end))
        XCTAssertEqual(offMainResults.map(\.ref), syncResults.map(\.ref))
        XCTAssertEqual(offMainResults.map(\.alt), syncResults.map(\.alt))
        XCTAssertEqual(offMainCount, 2)
    }

    /// A variant track's alias groups are built by the first lookup, once, whether that
    /// lookup is the synchronous query or the off-main one.
    @MainActor func testVariantAliasLookupBuildsTheGroupsOnce() async throws {
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: try makeVariantBundle(), chromosomes: variantBundleChromosomes)
        XCTAssertEqual(index.aliasMapBuildCount, 0, "Opening the bundle builds no alias groups")

        XCTAssertEqual(index.queryVariantsInRegion(chromosome: "NC_000001.11", start: 0, end: 1_000).count, 2)
        XCTAssertEqual(index.aliasMapBuildCount, 1)

        let offMainResults = await index.queryVariantsInRegionOffMain(chromosome: "NC_000001.11", start: 0, end: 1_000)
        XCTAssertEqual(offMainResults.count, 2)
        XCTAssertEqual(index.aliasMapBuildCount, 1, "The off-main query reuses the groups")
    }
}
