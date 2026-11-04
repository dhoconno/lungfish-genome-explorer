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

    // MARK: - The record

    /// Item 12, TaxTriage. The record names the one scan the pipeline ran on a file sample, and the plan's scan on a
    /// planned one. A stated layout holds null.
    func testTaxTriageRecordCarriesTheScanFields() async throws {
        let mixed = TaxTriageSample(sampleId: "mixed", fastq1: try file([.pairs(60_000), .singles(20_000)]))
        let stated = TaxTriageSample(sampleId: "stated", fastq1: try file([.pairs(4)]), readLayout: .singleEnd)
        let config = TaxTriageConfig(samples: [mixed, stated], outputDirectory: root.appendingPathComponent("taxtriage-out"))
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: config,
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        XCTAssertEqual(Array(prepared.scans.keys), ["mixed"], "a stated layout runs no scan")
        let facts = TaxTriageRecordFacts(config: config, sampleLayoutScans: prepared.scans)
        let layouts = try XCTUnwrap(facts.resolvedDefaults["read_layouts"]?.dictionaryValue)
        let scanned = try XCTUnwrap(layouts["mixed"]?.dictionaryValue)
        XCTAssertEqual(scanned["readLayout"], .string("mixed_merged_and_pairs"))
        XCTAssertEqual(scanned["scannedRecords"], .integer(140_000))
        XCTAssertEqual(scanned["scannedWholeFile"], .boolean(true))
        XCTAssertEqual(scanned["pairs"], .integer(60_000))
        XCTAssertEqual(scanned["unpairedReads"], .integer(20_000))
        let named = try XCTUnwrap(layouts["stated"]?.dictionaryValue)
        XCTAssertEqual(named["readLayout"], .string("single_end"))
        XCTAssertEqual(named["scannedRecords"], .null)
        XCTAssertEqual(named["scannedWholeFile"], .null)
        XCTAssertEqual(named["pairs"], .null)
        XCTAssertEqual(named["unpairedReads"], .null)
        XCTAssertEqual(
            TaxTriageRecordFacts.recordOptions(fromRunParameters: facts.runParameters).resolvedDefaults["read_layouts"],
            facts.resolvedDefaults["read_layouts"],
            "the save keeps it among the resolved defaults"
        )
    }

    /// Item 12, a plan keeps its scan, so TaxTriage, Viral Recon and mapping record it with no second read.
    func testAPlanKeepsTheScanThatDecidedIt() async throws {
        let mixed = try bundle([.pairs(60_000), .singles(20_000)])
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: mixed.bundle,
            materializedInputs: [mixed.reads],
            materializationDirectory: root.appendingPathComponent("inputs", isDirectory: true)
        )
        let scan = try XCTUnwrap(plan.layoutClassification)
        XCTAssertEqual(scan.scannedRecords, 140_000)
        XCTAssertEqual(scan.matePairs, 60_000)
        XCTAssertEqual(scan.unpairedRecords, 20_000)
        XCTAssertTrue(scan.scannedWholeFile)
    }

    /// BIO's rule. The count of a materialization outranks the scan for `pairs` and `unpairedReads`.
    func testACountOfTheWholeFileOutranksTheScanInTheRecord() throws {
        let scan = try XCTUnwrap(FASTQInputLayoutResolver.resolve(inputURLs: [try file([.pairs(10), .singles(2)])]).classification)
        let fields = FASTQReadLayoutClassification.scanProvenanceParameters(of: scan.countedWhole(pairs: 5, unpaired: 3))
        XCTAssertEqual(fields["scannedRecords"], .integer(13))
        XCTAssertEqual(fields["scannedWholeFile"], .boolean(true))
        XCTAssertEqual(fields["pairs"], .integer(5))
        XCTAssertEqual(fields["unpairedReads"], .integer(3))
    }

    /// BIO's rule. A scan of a file that holds only part of its bundle says nothing about the bundle, so the record holds
    /// null, though `scannedWholeFile` is true of the file read.
    func testARecordNamesNoScanOfAFileThatHoldsPartOfItsBundle() throws {
        let whole = try bundle([.pairs(10)])
        XCTAssertNotNil(FASTQInputLayoutResolver.resolve(inputURLs: [whole.bundle]).recordedScan(of: whole.bundle))
        XCTAssertNotNil(FASTQInputLayoutResolver.resolve(inputURLs: [try file([.pairs(10)])]).classification)

        let part = try bundle([.pairs(10)])
        try FASTQLayoutRecordFixtures.write([.pairs(10)], to: part.bundle.appendingPathComponent("more.fastq"))
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [part.bundle])
        XCTAssertNil(resolution.recordedScan(of: part.bundle))
        XCTAssertEqual(
            FASTQReadLayoutClassification.scanProvenanceParameters(of: resolution.recordedScan(of: part.bundle))["scannedWholeFile"],
            .null
        )
    }

    /// BIO section "What the last continuation must add", item 7. Kraken 2 runs the whole-file scan, and its record holds
    /// what that scan read.
    func testKrakenRecordCarriesTheScanFields() throws {
        let mixed = try file([.pairs(60_000), .singles(20_000)])
        let requested = ClassificationConfig(
            inputFiles: [mixed],
            isPairedEnd: false,
            interleavedInput: true,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            outputDirectory: root.appendingPathComponent("kraken-out", isDirectory: true)
        )
        let reconciled = ClassificationPipeline.reconcileInterleavedRequest(requested)
        let parameters = try XCTUnwrap(reconciled.config.inputLayout?.provenanceParameters)
        XCTAssertFalse(reconciled.config.interleavedInput, "a mixed file does not split by position")
        XCTAssertEqual(parameters["scannedRecords"], .integer(140_000))
        XCTAssertEqual(parameters["scannedWholeFile"], .boolean(true))
        XCTAssertEqual(parameters["pairs"], .integer(60_000))
        XCTAssertEqual(parameters["unpairedReads"], .integer(20_000))
    }

    /// Item 12, Viral Recon. A row of one file records what its scan read. A row of two files read nothing, so it records
    /// null and not 0.
    func testViralReconRecordCarriesTheScanFields() throws {
        let mixed = try file([.pairs(60_000), .singles(20_000)])
        let scanned = ViralReconReadPairing.decision(for: ViralReconSample(
            sampleName: "mixed", sourceBundleURL: mixed, fastqURLs: [mixed], barcode: nil, sequencingSummaryURL: nil
        ))
        guard case .dictionary(let fields) = scanned.provenanceValue else { return XCTFail("expected a dictionary") }
        XCTAssertEqual(fields["readLayout"], .string("mixed_merged_and_pairs"))
        XCTAssertEqual(fields["scannedRecords"], .integer(140_000))
        XCTAssertEqual(fields["scannedWholeFile"], .boolean(true))
        XCTAssertEqual(fields["pairs"], .integer(60_000))
        XCTAssertEqual(fields["unpairedReads"], .integer(20_000))

        let r1 = try file([.singles(3)])
        let r2 = try file([.singles(3)])
        let pair = ViralReconReadPairing.decision(for: ViralReconSample(
            sampleName: "pair", sourceBundleURL: r1, fastqURLs: [r1, r2], barcode: nil, sequencingSummaryURL: nil
        ))
        guard case .dictionary(let pairFields) = pair.provenanceValue else { return XCTFail("expected a dictionary") }
        XCTAssertEqual(pairFields["scannedRecords"], .null)
        XCTAssertEqual(pairFields["scannedWholeFile"], .null)
        XCTAssertEqual(pairFields["pairs"], .null)
        XCTAssertEqual(pairFields["unpairedReads"], .null)
    }
}
