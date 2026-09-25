// FASTQInputLayoutResolverTests.swift - Shared read-layout resolution for FASTQ-consuming tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQInputLayoutResolverTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-input-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func fastq(_ headers: [String]) -> String {
        headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
    }

    /// A `.lungfishfastq` bundle holding `headers`, with an optional sidecar.
    private func makeBundle(
        headers: [String],
        pairingMode: IngestionMetadata.PairingMode? = nil,
        pairingSource: IngestionMetadata.PairingSource? = nil,
        recipe: RecipeAppliedInfo? = nil
    ) throws -> (bundle: URL, fastq: URL) {
        let dir = try makeTempDir()
        let bundle = dir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastqURL = bundle.appendingPathComponent("reads.fastq")
        try fastq(headers).write(to: fastqURL, atomically: true, encoding: .utf8)
        if pairingMode != nil || recipe != nil {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(ingestion: IngestionMetadata(
                    pairingMode: pairingMode ?? .singleEnd,
                    pairingSource: pairingSource,
                    recipeApplied: recipe
                )),
                for: fastqURL
            )
        }
        return (bundle, fastqURL)
    }

    // MARK: - Evidence order

    func testExplicitLayoutWinsWithoutReadingTheFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/reads.fastq")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [missing], explicit: .mixedMergedAndPairs)
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs)
        XCTAssertEqual(resolution.source, .explicit)
        XCTAssertNil(resolution.classification)
    }

    func testTwoFilesBoundAsPairAreAPairedFilesLayout() {
        let r1 = URL(fileURLWithPath: "/tmp/reads_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/tmp/reads_R2.fastq.gz")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [r1, r2], pairedFiles: true)
        XCTAssertEqual(resolution.layout, .pairedFiles)
        XCTAssertEqual(resolution.source, .pairedFiles)
    }

    func testTwoUnboundFilesArePooledSingleReads() {
        let a = URL(fileURLWithPath: "/tmp/a.fastq")
        let b = URL(fileURLWithPath: "/tmp/b.fastq")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [a, b], pairedFiles: false)
        XCTAssertEqual(resolution.layout, .singleEnd)
        XCTAssertEqual(resolution.source, .pooledFiles)
    }

    func testFASTAInputIsSingleEndWithoutScanning() throws {
        let dir = try makeTempDir()
        let fasta = dir.appendingPathComponent("contigs.fa")
        try ">c1\nACGT\n>c1\nACGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [fasta])
        XCTAssertEqual(resolution.layout, .singleEnd)
        XCTAssertEqual(resolution.source, .notFASTQ)
    }

    // MARK: - Bundle metadata first

    func testExplicitSingleEndMetadataSettlesTheLayoutWithoutAScan() throws {
        // Content alternates like pairs, but the user chose single-end.
        let (bundle, fastqURL) = try makeBundle(
            headers: ["a", "a", "b", "b"],
            pairingMode: .singleEnd,
            pairingSource: .explicit
        )
        for input in [bundle, fastqURL] {
            let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
            XCTAssertEqual(resolution.layout, .singleEnd)
            XCTAssertEqual(resolution.source, .bundleMetadata)
            XCTAssertNil(resolution.classification)
        }
        let scratch = try makeTempDir().appendingPathComponent("materialized.fastq")
        try FileManager.default.copyItem(at: fastqURL, to: scratch)
        let fromScratch = FASTQInputLayoutResolver.resolve(fastqURL: scratch, metadataFrom: bundle)
        XCTAssertEqual(fromScratch.layout, .singleEnd)
        XCTAssertEqual(fromScratch.source, .bundleMetadata)
    }

    func testDefaultedSingleEndMetadataOverInterleavedRecordsIsInterleaved() throws {
        // SIMULATED-MHC-*-pairs: imported with no pairing choice, recorded
        // single_end, records alternate /1 /2 mates. Metadata written before
        // pairingSource existed (nil), and a defaulted or detected single_end,
        // are hints; the records decide.
        for source: IngestionMetadata.PairingSource? in [nil, .defaulted, .detected] {
            let (bundle, fastqURL) = try makeBundle(
                headers: ["f0/1", "f0/2", "f1/1", "f1/2", "f2/1", "f2/2"],
                pairingMode: .singleEnd,
                pairingSource: source
            )
            for input in [bundle, fastqURL] {
                let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
                XCTAssertEqual(resolution.layout, .strictlyInterleaved, "source \(String(describing: source))")
                XCTAssertEqual(resolution.source, .contentScan)
            }
            let scratch = try makeTempDir().appendingPathComponent("materialized.fastq")
            try FileManager.default.copyItem(at: fastqURL, to: scratch)
            XCTAssertEqual(
                FASTQInputLayoutResolver.resolve(fastqURL: scratch, metadataFrom: bundle).layout,
                .strictlyInterleaved
            )
            // The bundle directory itself is scanned through its primary FASTQ.
            XCTAssertEqual(
                FASTQInputLayoutResolver.resolve(fastqURL: bundle, metadataFrom: bundle).layout,
                .strictlyInterleaved
            )
        }
    }

    func testDefaultedSingleEndMetadataOverSingleRecordsStaysSingle() throws {
        let (bundle, _) = try makeBundle(headers: ["r0", "r1", "r2"], pairingMode: .singleEnd)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .singleEnd)
        XCTAssertEqual(resolution.source, .contentScan)
    }

    func testBundleWithoutMetadataIsScanned() throws {
        let (bundle, _) = try makeBundle(headers: ["a", "a", "b", "b"])
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .strictlyInterleaved)
        XCTAssertEqual(resolution.source, .contentScan)
    }

    func testLegacyIngestionMetadataDecodesWithoutAPairingSource() throws {
        let json = #"{"isClumpified":false,"isCompressed":true,"pairingMode":"single_end","originalFilenames":[]}"#
        let decoded = try JSONDecoder().decode(IngestionMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pairingMode, .singleEnd)
        XCTAssertNil(decoded.pairingSource)
        var current = decoded
        current.pairingSource = .defaulted
        let reencoded = try JSONEncoder().encode(current)
        XCTAssertTrue(String(decoding: reencoded, as: UTF8.self).contains(#""pairingSource":"default""#))
    }

    func testInterleavedMetadataWithIdenticalNamesIsStrictlyInterleaved() throws {
        let (bundle, fastqURL) = try makeBundle(headers: ["frag0", "frag0", "frag1", "frag1"], pairingMode: .interleaved)
        for input in [bundle, fastqURL] {
            let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
            XCTAssertEqual(resolution.layout, .strictlyInterleaved, input.lastPathComponent)
            XCTAssertEqual(resolution.source, .contentScan)
            XCTAssertEqual(resolution.classification?.matePairs, 2)
        }
    }

    func testInterleavedMetadataWithMergeRecipeIsMixedEvenWhenHeadAlternates() throws {
        let recipe = RecipeAppliedInfo(
            recipeID: "illuminaVSP2TargetEnrichment",
            recipeName: "VSP2",
            stepResults: [RecipeStepResult(stepName: "PE merge (normal, min overlap: 12)", tool: "fastp", durationSeconds: 1)]
        )
        let (bundle, _) = try makeBundle(headers: ["a/1", "a/2", "b/1", "b/2"], pairingMode: .interleaved, recipe: recipe)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs)
        XCTAssertEqual(resolution.source, .contentScan)
        XCTAssertTrue(resolution.classification?.metadata.hasMergedOrUnpairedReads ?? false)
    }

    // MARK: - Content scan

    func testMergedReadsAmongPairsAreMixed() throws {
        let (bundle, _) = try makeBundle(headers: ["m0", "p0", "p0", "m1", "p1", "p1", "m2"], pairingMode: .interleaved)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs)
        XCTAssertEqual(resolution.classification?.matePairs, 2)
        XCTAssertEqual(resolution.classification?.unpairedRecords, 3)
    }

    func testLooseFileWithoutMetadataIsScanned() throws {
        let dir = try makeTempDir()
        let loose = dir.appendingPathComponent("reads.fastq")
        try fastq(["r0 1:N:0:ACGT", "r0 2:N:0:ACGT", "r1 1:N:0:ACGT", "r1 2:N:0:ACGT"])
            .write(to: loose, atomically: true, encoding: .utf8)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [loose])
        XCTAssertEqual(resolution.layout, .strictlyInterleaved)
        XCTAssertEqual(resolution.source, .contentScan)

        try fastq(["r0", "r1", "r2"]).write(to: loose, atomically: true, encoding: .utf8)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [loose]).layout, .singleEnd)
    }

    // MARK: - Contract types

    func testInputLayoutMirrorsReadLayout() {
        XCTAssertEqual(FASTQInputLayout(readLayout: .singleEnd), .singleEnd)
        XCTAssertEqual(FASTQInputLayout(readLayout: .strictlyInterleaved), .strictlyInterleaved)
        XCTAssertEqual(FASTQInputLayout(readLayout: .mixedInterleaved), .mixedMergedAndPairs)
        XCTAssertFalse(FASTQInputLayout.singleEnd.holdsPairs)
        XCTAssertTrue(FASTQInputLayout.mixedMergedAndPairs.holdsPairs)
    }

    func testDeclarationReportsUndeclaredLayoutsAndDefaultsToSingle() {
        let partial = FASTQConsumerDeclaration(
            consumerID: "test.partial",
            displayName: "Partial",
            handling: [.pairedFiles: .asPairs],
            mixedRationale: "test"
        )
        XCTAssertEqual(
            Set(partial.undeclaredLayouts),
            [.singleEnd, .strictlyInterleaved, .mixedMergedAndPairs]
        )
        XCTAssertEqual(partial.handling(for: .mixedMergedAndPairs), .asSingle)
        XCTAssertEqual(partial.handling(for: .pairedFiles), .asPairs)
        XCTAssertTrue(partial.mixedHandlingIsGraceful)
    }

    func testResolutionRoundTripsThroughJSON() throws {
        let resolution = FASTQInputLayoutResolution(
            layout: .strictlyInterleaved,
            source: .contentScan,
            classification: FASTQReadLayoutClassifier.classify(headers: ["a", "a"], scannedWholeFile: true),
            reason: "Every record is followed by its mate."
        )
        let data = try JSONEncoder().encode(resolution)
        XCTAssertEqual(try JSONDecoder().decode(FASTQInputLayoutResolution.self, from: data), resolution)
    }
}
