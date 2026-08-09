// AnnotationSearchIndexOffMainTests.swift - Threading + parity tests for the off-main
// AnnotationSearchIndex query methods AIToolRegistry uses. See F12.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

/// Thread-safe capture box for the `threadingProbe` hook. The probe closure is `@Sendable`
/// and fires from whatever thread the query actually runs on; this box lets the (MainActor)
/// test method read the captured value afterward.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasMainThread: Bool?
    private var _fireCount = 0

    func record() {
        let isMain = Thread.isMainThread
        lock.lock()
        _wasMainThread = isMain
        _fireCount += 1
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fireCount > 0
    }

    var fireCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fireCount
    }

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

/// Drives the off-main query methods from a real `@MainActor` context, exactly as
/// `AIToolRegistry` (itself `@MainActor`) does. The off-main assertions below are only
/// meaningful against this call shape.
@MainActor
private enum MainActorQueryRunner {
    static func search(_ index: AnnotationSearchIndex, query: String, limit: Int) async -> [AnnotationSearchIndex.SearchResult] {
        MainActor.assertIsolated("Runner must actually start on the main actor")
        return await index.searchOffMain(query: query, limit: limit)
    }

    static func queryVariantsInRegion(
        _ index: AnnotationSearchIndex,
        chromosome: String,
        start: Int,
        end: Int,
        limit: Int = 5000
    ) async -> [AnnotationSearchIndex.SearchResult] {
        MainActor.assertIsolated("Runner must actually start on the main actor")
        return await index.queryVariantsInRegionOffMain(chromosome: chromosome, start: start, end: end, limit: limit)
    }

    static func queryVariantCountInRegion(
        _ index: AnnotationSearchIndex,
        chromosome: String,
        start: Int,
        end: Int
    ) async -> Int {
        MainActor.assertIsolated("Runner must actually start on the main actor")
        return await index.queryVariantCountInRegionOffMain(chromosome: chromosome, start: start, end: end)
    }
}

@MainActor
final class AnnotationSearchIndexOffMainTests: XCTestCase {

    private nonisolated(unsafe) var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationSearchIndexOffMainTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AnnotationSearchIndex.threadingProbe = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Fixture

    /// Builds an `AnnotationSearchIndex` backed by real SQLite annotation + variant
    /// databases, mirroring the fixture pattern used by
    /// `AnnotationTableDrawerVariantTests.testAnnotationSearchIndexQueryAnnotationsOnly`.
    private func makeIndex() throws -> AnnotationSearchIndex {
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\t.".write(
            to: bedURL, atomically: true, encoding: .utf8
        )
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs111\tA\tG\t50.0\tPASS\t.
        chr1\t250\trs222\tAT\tA\t35.0\tPASS\t.
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.offmain",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1000, chromosomes: []),
            annotations: [AnnotationTrackInfo(id: "a", name: "Annotations", path: "a.bb", databasePath: "annotations.db")],
            variants: [VariantTrackInfo(id: "v", name: "Variants", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: bundle, trackId: "a", databasePath: "annotations.db")
        return index
    }

    // MARK: - Threading regression (F12)
    //
    // These tests call the `*OffMain` methods from an actual `@MainActor` context (as
    // `AIToolRegistry` does in production) and assert, via a probe fired from inside the
    // `Task.detached` body, that the SQLite work is NOT running on the main thread.

    func testSearchOffMainRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let index = try makeIndex()
        let observation = ThreadObservationBox()
        AnnotationSearchIndex.threadingProbe = { observation.record() }

        _ = await MainActorQueryRunner.search(index, query: "BRCA1", limit: 5)

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "searchOffMain ran its SQLite query on the main thread")
    }

    func testQueryVariantsInRegionOffMainRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let index = try makeIndex()
        let observation = ThreadObservationBox()
        AnnotationSearchIndex.threadingProbe = { observation.record() }

        _ = await MainActorQueryRunner.queryVariantsInRegion(index, chromosome: "chr1", start: 0, end: 1000)

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "queryVariantsInRegionOffMain ran its SQLite query on the main thread")
    }

    func testQueryVariantCountInRegionOffMainRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let index = try makeIndex()
        let observation = ThreadObservationBox()
        AnnotationSearchIndex.threadingProbe = { observation.record() }

        _ = await MainActorQueryRunner.queryVariantCountInRegion(index, chromosome: "chr1", start: 0, end: 1000)

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "queryVariantCountInRegionOffMain ran its SQLite query on the main thread")
    }

    // MARK: - Result parity
    //
    // The off-main methods must produce results identical to their synchronous counterparts.

    func testSearchOffMainMatchesSyncSearch() async throws {
        let index = try makeIndex()

        let syncResults = index.search(query: "BRCA1", limit: 20)
        let offMainResults = await index.searchOffMain(query: "BRCA1", limit: 20)

        XCTAssertFalse(syncResults.isEmpty)
        XCTAssertEqual(syncResults.map(\.name), offMainResults.map(\.name))
        XCTAssertEqual(syncResults.map(\.chromosome), offMainResults.map(\.chromosome))
        XCTAssertEqual(syncResults.map(\.start), offMainResults.map(\.start))
        XCTAssertEqual(syncResults.map(\.end), offMainResults.map(\.end))
        XCTAssertEqual(syncResults.map(\.trackId), offMainResults.map(\.trackId))
        XCTAssertEqual(syncResults.map(\.trackName), offMainResults.map(\.trackName))
    }

    func testSearchOffMainMatchesSyncSearchForVariantIDLookup() async throws {
        let index = try makeIndex()

        let syncResults = index.search(query: "rs111", limit: 20)
        let offMainResults = await index.searchOffMain(query: "rs111", limit: 20)

        XCTAssertFalse(syncResults.isEmpty)
        XCTAssertEqual(syncResults.map(\.name), offMainResults.map(\.name))
        XCTAssertEqual(syncResults.map(\.ref), offMainResults.map(\.ref))
        XCTAssertEqual(syncResults.map(\.alt), offMainResults.map(\.alt))
        XCTAssertEqual(syncResults.map(\.isVariant), offMainResults.map(\.isVariant))
    }

    func testQueryVariantsInRegionOffMainMatchesSyncQuery() async throws {
        let index = try makeIndex()

        let syncResults = index.queryVariantsInRegion(chromosome: "chr1", start: 0, end: 1000)
        let offMainResults = await index.queryVariantsInRegionOffMain(chromosome: "chr1", start: 0, end: 1000)

        XCTAssertEqual(syncResults.count, 2)
        XCTAssertEqual(syncResults.map(\.name), offMainResults.map(\.name))
        XCTAssertEqual(syncResults.map(\.start), offMainResults.map(\.start))
        XCTAssertEqual(syncResults.map(\.end), offMainResults.map(\.end))
        XCTAssertEqual(syncResults.map(\.ref), offMainResults.map(\.ref))
        XCTAssertEqual(syncResults.map(\.alt), offMainResults.map(\.alt))
    }

    func testQueryVariantCountInRegionOffMainMatchesSyncQuery() async throws {
        let index = try makeIndex()

        let syncCount = index.queryVariantCountInRegion(chromosome: "chr1", start: 0, end: 1000)
        let offMainCount = await index.queryVariantCountInRegionOffMain(chromosome: "chr1", start: 0, end: 1000)

        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(syncCount, offMainCount)
    }

    func testQueryVariantsInRegionOffMainRespectsEmptyRegion() async throws {
        let index = try makeIndex()

        let offMainResults = await index.queryVariantsInRegionOffMain(chromosome: "chr1", start: 10_000, end: 20_000)
        XCTAssertTrue(offMainResults.isEmpty)
    }

    // MARK: - AIToolRegistry integration
    //
    // Exercises the fix through the real AIToolRegistry call path (the actual F12 call
    // sites) rather than only through AnnotationSearchIndex directly.

    func testAIToolRegistryGetGeneDetailsUsesOffMainQueriesAndFindsVariants() async throws {
        let index = try makeIndex()
        let registry = AIToolRegistry(searchIndex: index)

        let call = AIToolCall(id: "1", name: "get_gene_details", arguments: ["gene_name": .string("BRCA1")])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("BRCA1"), "Expected gene details, got: \(result.content)")
        XCTAssertTrue(result.content.contains("Variants in region: 2"), "Expected 2 variants in region, got: \(result.content)")
        XCTAssertTrue(result.content.contains("rs111"))
        XCTAssertTrue(result.content.contains("rs222"))
    }

    func testAIToolRegistrySearchVariantsUsesOffMainRegionQuery() async throws {
        let index = try makeIndex()
        let registry = AIToolRegistry(searchIndex: index)

        let call = AIToolCall(
            id: "1",
            name: "search_variants",
            arguments: ["chromosome": .string("chr1"), "start": .integer(0), "end": .integer(1000)]
        )
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Found 2 variant(s)"), "Expected 2 variants, got: \(result.content)")
        XCTAssertTrue(result.content.contains("rs111"))
        XCTAssertTrue(result.content.contains("rs222"))
    }

    func testAIToolRegistrySearchGenesUsesOffMainSearch() async throws {
        let index = try makeIndex()
        let registry = AIToolRegistry(searchIndex: index)

        let call = AIToolCall(id: "1", name: "search_genes", arguments: ["query": .string("BRCA1")])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("BRCA1"), "Expected gene match, got: \(result.content)")
    }

    // MARK: - Stale-snapshot regression (round-2 review)
    //
    // `executeGetGeneDetails` reads `hasVariantDatabase` synchronously, then `await`s two
    // off-main queries, each of which takes its OWN fresh snapshot at call time. Between
    // the check and either `await`, ordinary main-actor code (e.g. `ViewerViewController`
    // bundle-switch/viewport teardown) can call `clearVariantDatabases()` and empty
    // `variantDatabases`. This forces that exact interleaving deterministically via the
    // `threadingProbe` hook (fired from inside the off-main query's `Task.detached` body,
    // after its snapshot has already been captured on the main actor but before the query
    // result is produced) and asserts the AI tool reports the mid-flight change instead of
    // silently claiming "no variants" for a gene that, at the moment `hasVariantDatabase`
    // was checked, genuinely had some.

    func testGetGeneDetailsReportsStaleDataInsteadOfSilentlyOmittingVariantsWhenClearedMidQuery() async throws {
        let index = try makeIndex()
        let registry = AIToolRegistry(searchIndex: index)
        let generationAtStart = index.variantDatabaseGeneration

        // threadingProbe fires from EVERY off-main query (searchOffMain first, for the
        // gene-name lookup itself, then queryVariantCountInRegionOffMain). Only clear on
        // the SECOND firing -- i.e. inside queryVariantCountInRegionOffMain's
        // Task.detached body, after that call's own snapshot was already captured on the
        // main actor (so the count query still sees the variant data), but before
        // executeGetGeneDetails observes the count and moves on to
        // queryVariantsInRegionOffMain. Blocks the detached task until
        // clearVariantDatabases() has actually run and bumped the generation, so the
        // interleaving is deterministic rather than a hopeful race.
        let clearedGate = DispatchSemaphore(value: 0)
        let fireCount = ThreadObservationBox()
        AnnotationSearchIndex.threadingProbe = { [weak index] in
            fireCount.record()
            guard fireCount.fireCount == 2, let index else { return }
            Task { @MainActor in
                index.clearVariantDatabases()
                clearedGate.signal()
            }
            clearedGate.wait()
        }

        let call = AIToolCall(id: "1", name: "get_gene_details", arguments: ["gene_name": .string("BRCA1")])
        let result = await registry.execute(call)

        XCTAssertGreaterThan(
            index.variantDatabaseGeneration, generationAtStart,
            "test setup did not actually clear variant data mid-query -- assertions below are not meaningful"
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("BRCA1"), "Gene lookup itself must still succeed: \(result.content)")
        XCTAssertTrue(
            result.content.contains("Variant data changed while this lookup was running"),
            "Expected an explicit stale-data notice instead of silently omitting variants: \(result.content)"
        )
        XCTAssertFalse(
            result.content.contains("Variants in region: 0"),
            "Must not report a since-cleared snapshot's zero count as if it were ground truth: \(result.content)"
        )
        XCTAssertFalse(result.content.contains("rs111"), "Stale variant rows must not appear in the response")
        XCTAssertFalse(result.content.contains("rs222"), "Stale variant rows must not appear in the response")
    }

    // MARK: - Concurrency

    /// Multiple concurrent off-main queries against the same index must not corrupt each
    /// other's results -- each call captures its own immutable snapshot at the main-actor
    /// call site before detaching, so there is no shared mutable state to race on.
    func testConcurrentOffMainSearchesReturnIndependentCorrectResults() async throws {
        let index = try makeIndex()

        async let geneResult = index.searchOffMain(query: "BRCA1", limit: 5)
        async let variantResult = index.searchOffMain(query: "rs111", limit: 5)
        async let regionResult = index.queryVariantsInRegionOffMain(chromosome: "chr1", start: 0, end: 1000)

        let (genes, variants, region) = await (geneResult, variantResult, regionResult)

        XCTAssertEqual(genes.map(\.name), ["BRCA1"])
        XCTAssertEqual(variants.map(\.name), ["rs111"])
        XCTAssertEqual(region.count, 2)
    }
}
