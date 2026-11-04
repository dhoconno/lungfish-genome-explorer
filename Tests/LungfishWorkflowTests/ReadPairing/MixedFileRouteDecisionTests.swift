// MixedFileRouteDecisionTests.swift - What each tool route decides for a mixed file past the old scan window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Row READ-LAYOUT-PARTIAL-SCAN (BIO ruling S1, section 6). Each route took the classifier's bounded answer, so a file
/// of 60,000 pairs then merged reads split by position. A truly strict file still runs as pairs.
final class MixedFileRouteDecisionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mixed-route-decisions")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func file(_ runs: [FASTQLayoutRecordFixtures.Run]) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).fastq")
        try FASTQLayoutRecordFixtures.write(runs, to: url)
        return url
    }

    private func bundle(
        _ runs: [FASTQLayoutRecordFixtures.Run],
        ingestion: IngestionMetadata? = nil
    ) throws -> (bundle: URL, reads: URL) {
        let bundle = root.appendingPathComponent("\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write(runs, to: reads)
        if let ingestion {
            FASTQMetadataStore.save(PersistedFASTQMetadata(ingestion: ingestion), for: reads)
        }
        return (bundle, reads)
    }

    private func esViritu(_ url: URL, readFormat: EsVirituReadFormat) -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: [url],
            isPairedEnd: false,
            sampleName: "s",
            outputDirectory: root.appendingPathComponent("esviritu-out"),
            databasePath: root.appendingPathComponent("esviritu-db"),
            readFormat: readFormat
        )
    }

    // MARK: - TaxTriage

    func testShouldSplitInterleavedIsFalseForMixed() async throws {
        for merged in [20_000, 20_001] {
            let sample = TaxTriageSample(sampleId: "s", fastq1: try file([.pairs(60_000), .singles(merged)]))
            XCTAssertFalse(TaxTriagePipeline.shouldSplitInterleaved(sample), "\(merged) merged reads")
        }

        let strict = TaxTriageSample(sampleId: "s", fastq1: try file([.pairs(70_000)]))
        XCTAssertTrue(TaxTriagePipeline.shouldSplitInterleaved(strict))
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: TaxTriageConfig(samples: [strict], outputDirectory: root.appendingPathComponent("taxtriage-out")),
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        XCTAssertEqual(prepared.splits.first?.pairCount, 70_000)
    }

    // MARK: - EsViritu

    func testVerifyingInterleavedInputFallsBackOnMixed() throws {
        let mixed = esViritu(try file([.pairs(60_000), .singles(20_000)]), readFormat: .interleaved)
            .verifyingInterleavedInput()
        XCTAssertEqual(mixed.readFormat, .unpaired)
        XCTAssertEqual(mixed.inputLayout?.matePairs, 60_000)

        let strict = esViritu(try file([.pairs(70_000)]), readFormat: .interleaved).verifyingInterleavedInput()
        XCTAssertEqual(strict.readFormat, .interleaved)
        XCTAssertEqual(strict.inputLayout?.matePairs, 70_000)
    }

    func testEsVirituPlanOfAMixedFileRunsSingleReads() throws {
        let plan = EsVirituSampleReadPlan.plan(
            for: MetagenomicsSampleInput(sampleId: "s", fastq1: try file([.pairs(60_000), .singles(20_001)]), fastq2: nil)
        )
        XCTAssertEqual(plan.format, .unpaired)
        XCTAssertEqual(plan.layout?.layout, .mixedInterleaved)
    }

    /// `--pairing single` binds every route. EsViritu's plan read `classify(inputURL:)`, which ignored the choice, so
    /// a file of pairs ran interleaved (ruling section 6, item f).
    func testEsVirituPlanHonoursExplicitSingle() throws {
        let explicit = try bundle(
            [.pairs(70_000)],
            ingestion: IngestionMetadata(pairingMode: .singleEnd, pairingSource: .explicit)
        )
        let plan = EsVirituSampleReadPlan.plan(
            for: MetagenomicsSampleInput(sampleId: "s", fastq1: explicit.bundle, fastq2: nil)
        )
        XCTAssertEqual(plan.format, .unpaired)
    }

    // MARK: - Kraken 2

    func testKrakenPlanRunsPairsBesideSingles() async throws {
        let mixed = try bundle([.pairs(60_000), .singles(20_000)])
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: mixed.bundle,
            materializedInputs: [mixed.reads],
            materializationDirectory: root.appendingPathComponent("inputs", isDirectory: true)
        )
        XCTAssertEqual(plan.composition.pairedFragments, 60_000)
        XCTAssertEqual(plan.composition.fragmentCount, 80_000)
    }

    // MARK: - A stated layout

    /// BIO review B4. A stated `--read-layout interleaved` was final, so a mixed file was paired by position with no
    /// word. A scan of the whole file that finds pairs beside single reads outranks the statement, as it outranks a
    /// declared pairing on the FASTQ operations.
    func testAStatedInterleavedMixedFileIsNotPairedByPosition() throws {
        let mixed = try file([.pairs(60_000), .singles(20_000)])
        let stated = FASTQInputLayoutResolver.resolve(inputURLs: [mixed], explicit: .strictlyInterleaved)
        XCTAssertEqual(stated.layout, .mixedMergedAndPairs, stated.reason)
        XCTAssertEqual(stated.source, .contentScan)
        XCTAssertTrue(stated.reason.contains("The caller stated interleaved pairs"), stated.reason)

        // The controls. A true strict file, a path with no file and a stated single-end keep the statement.
        let strict = FASTQInputLayoutResolver.resolve(inputURLs: [try file([.pairs(70)])], explicit: .strictlyInterleaved)
        XCTAssertEqual(strict.layout, .strictlyInterleaved)
        XCTAssertEqual(strict.source, .explicit)
        let missing = FASTQInputLayoutResolver.resolve(
            inputURLs: [root.appendingPathComponent("gone.fastq")], explicit: .strictlyInterleaved)
        XCTAssertEqual(missing.layout, .strictlyInterleaved)
        XCTAssertEqual(missing.source, .explicit)
        let single = FASTQInputLayoutResolver.resolve(inputURLs: [try file([.pairs(70)])], explicit: .singleEnd)
        XCTAssertEqual(single.layout, .singleEnd)
        XCTAssertEqual(single.source, .explicit)
    }
}
