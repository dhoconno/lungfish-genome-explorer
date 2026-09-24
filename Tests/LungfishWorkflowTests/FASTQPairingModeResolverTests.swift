// FASTQPairingModeResolverTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Paired imports are stored as one interleaved FASTQ whose bundle metadata
// says so, and their mates often carry identical names. Some of those
// bundles are MIXED (merged reads plus pairs). The resolver is the single
// answer every fastq subcommand consults, so these tests pin the contract:
// an explicit `single` reads nothing, an explicit `interleaved` is verified
// against the records, and a mixed file is paired only by an operation that
// pairs by name.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class FASTQPairingModeResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Name-based probe (legacy helper kept for the genotyping tests)

    func testIdenticalNameMatesAreDetectedWhenAccepted() async throws {
        let url = root.appendingPathComponent("identical.fastq")
        try InterleavedFASTQFixture.write(pairCount: 20, naming: .identical, to: url)

        let strict = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(strict, "The strict probe must keep ignoring identical names")

        let relaxed = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(
            at: url,
            acceptingIdenticalNames: true
        )
        XCTAssertTrue(relaxed, "Adjacent records with the same key and no mate number are a pair")
    }

    // MARK: - Auto

    func testAutoPairsEveryMateNamingStyleOfAStrictFile() {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let url = root.appendingPathComponent("\(naming.rawValue).fastq")
            try? InterleavedFASTQFixture.write(pairCount: 12, naming: naming, to: url)
            let decision = FASTQPairingModeResolver.resolvePairing(inputURL: url)
            XCTAssertTrue(decision.pairAware, "\(naming) mates must be recognised without metadata")
            XCTAssertEqual(decision.layout, .strictlyInterleaved, "\(naming)")
            XCTAssertEqual(decision.resolution.source, .contentScan, "\(naming)")
            XCTAssertNil(decision.warning, "\(naming)")
        }
    }

    func testAutoRunsAMixedFileAsSingleReadsUnlessTheOperationPairsByName() throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let url = root.appendingPathComponent("mixed-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.writeMixed(pairCount: 12, mergedCount: 5, naming: naming, to: url)

            let positional = FASTQPairingModeResolver.resolvePairing(inputURL: url)
            XCTAssertFalse(positional.pairAware, "\(naming): a positional tool must not pair a mixed file")
            XCTAssertEqual(positional.layout, .mixedMergedAndPairs, "\(naming)")
            XCTAssertNotNil(positional.warning, "\(naming): the fallback must be explained")

            let byName = FASTQPairingModeResolver.resolvePairing(inputURL: url, pairsByName: true)
            XCTAssertTrue(byName.pairAware, "\(naming): a by-name operation may pair a mixed file")
            XCTAssertEqual(byName.layout, .mixedMergedAndPairs, "\(naming)")
            XCTAssertNil(byName.warning, "\(naming)")
        }
    }

    func testAutoRunsDistinctNameSingleEndReadsAsSingle() throws {
        let url = root.appendingPathComponent("single.fastq")
        let text = (0..<20).map { index -> String in
            "@read\(index)\n\(InterleavedFASTQFixture.deterministicSequence(seed: UInt64(index)))\n+\n\(String(repeating: "I", count: 60))"
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let decision = FASTQPairingModeResolver.resolvePairing(inputURL: url)
        XCTAssertFalse(decision.pairAware)
        XCTAssertEqual(decision.layout, .singleEnd)
        XCTAssertNil(decision.warning)
    }

    // MARK: - Bundle metadata

    func testRecordedSingleEndPairingWinsWithoutReadingTheRecords() throws {
        let singleByMetadata = try InterleavedFASTQFixture.writeBundle(
            named: "meta-single",
            in: root,
            pairCount: 12,
            naming: .slashSuffix,
            pairingMode: .singleEnd
        )
        let decision = FASTQPairingModeResolver.resolvePairing(inputURL: singleByMetadata.fastqURL)
        XCTAssertFalse(decision.pairAware, "Recorded single-end pairing must override paired-looking names")
        XCTAssertEqual(decision.resolution.source, .bundleMetadata)
    }

    func testRecordedInterleavedPairingIsVerifiedAgainstTheRecords() throws {
        // A VSP2 bundle records `interleaved` while holding merged reads.
        let mixedBundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "vsp2-like",
            in: root,
            pairCount: 20,
            mergedCount: 7,
            naming: .identical,
            pairingMode: .interleaved
        )
        XCTAssertEqual(FASTQPairingModeResolver.bundlePairingMode(for: mixedBundle.fastqURL), .interleaved)
        let decision = FASTQPairingModeResolver.resolvePairing(inputURL: mixedBundle.fastqURL)
        XCTAssertFalse(decision.pairAware, "The recorded pairing is a claim; the records decide")
        XCTAssertEqual(decision.layout, .mixedMergedAndPairs)

        let strictBundle = try InterleavedFASTQFixture.writeBundle(
            named: "meta-interleaved",
            in: root,
            pairCount: 1,
            naming: .identical,
            pairingMode: .interleaved
        )
        XCTAssertEqual(FASTQPairingModeResolver.bundlePairingMode(for: strictBundle.bundleURL), .interleaved)
        XCTAssertTrue(FASTQPairingModeResolver.resolvePairing(inputURL: strictBundle.fastqURL).pairAware)
    }

    func testMaterializedCopyUsesTheBundleMetadataAsHints() throws {
        // The GUI hands the CLI a scratch copy with no sidecar; the original
        // bundle's merge evidence must still demote a strict-looking scan.
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "merged-lineage",
            in: root,
            pairCount: 8,
            naming: .identical,
            pairingMode: .interleaved
        )
        var metadata = FASTQMetadataStore.load(for: bundle.fastqURL) ?? PersistedFASTQMetadata()
        metadata.readClassification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
        ])
        FASTQMetadataStore.save(metadata, for: bundle.fastqURL)

        let scratch = root.appendingPathComponent("scratch.fastq")
        try FileManager.default.copyItem(at: bundle.fastqURL, to: scratch)

        let withoutHints = FASTQPairingModeResolver.resolvePairing(inputURL: scratch)
        XCTAssertTrue(withoutHints.pairAware, "The scratch copy alone scans as strict pairs")

        let withHints = FASTQPairingModeResolver.resolvePairing(inputURL: scratch, metadataFrom: bundle.bundleURL)
        XCTAssertFalse(withHints.pairAware, "Merge evidence in the bundle metadata demotes the scan to mixed")
        XCTAssertEqual(withHints.layout, .mixedMergedAndPairs)
    }

    func testLooseFASTQWithoutMetadataReturnsNilBundlePairing() throws {
        let url = root.appendingPathComponent("loose.fastq")
        try InterleavedFASTQFixture.write(pairCount: 2, naming: .identical, to: url)
        XCTAssertNil(FASTQPairingModeResolver.bundlePairingMode(for: url))
    }

    // MARK: - Explicit answer

    func testExplicitSingleIsFinalAndReadsNothing() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "explicit",
            in: root,
            pairCount: 12,
            naming: .identical,
            pairingMode: .interleaved
        )
        let forcedSingle = FASTQPairingModeResolver.resolvePairing(inputURL: bundle.fastqURL, explicit: false)
        XCTAssertFalse(forcedSingle.pairAware)
        XCTAssertEqual(forcedSingle.resolution.source, .explicit)
        XCTAssertNil(forcedSingle.warning)

        let missing = FASTQPairingModeResolver.resolvePairing(
            inputURL: root.appendingPathComponent("does-not-exist.fastq"),
            explicit: false
        )
        XCTAssertFalse(missing.pairAware)
        XCTAssertEqual(missing.layout, .singleEnd)
    }

    func testExplicitInterleavedIsHonouredForStrictPairsAndRefusedOtherwise() throws {
        let strict = root.appendingPathComponent("strict.fastq")
        try InterleavedFASTQFixture.write(pairCount: 12, naming: .identical, to: strict)
        let honoured = FASTQPairingModeResolver.resolvePairing(inputURL: strict, explicit: true)
        XCTAssertTrue(honoured.pairAware)
        XCTAssertNil(honoured.warning)

        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 12, mergedCount: 4, naming: .slashSuffix, to: mixed)
        let refusedMixed = FASTQPairingModeResolver.resolvePairing(inputURL: mixed, explicit: true)
        XCTAssertFalse(refusedMixed.pairAware, "--pairing interleaved must not pair a mixed file by position")
        XCTAssertEqual(refusedMixed.layout, .mixedMergedAndPairs)
        XCTAssertNotNil(refusedMixed.warning)

        let loose = root.appendingPathComponent("loose-single.fastq")
        try "@a\nACGT\n+\nIIII\n@b\nACGT\n+\nIIII\n".write(to: loose, atomically: true, encoding: .utf8)
        let refusedSingle = FASTQPairingModeResolver.resolvePairing(inputURL: loose, explicit: true)
        XCTAssertFalse(refusedSingle.pairAware, "No adjacent mates means nothing can be paired")
        XCTAssertEqual(refusedSingle.layout, .singleEnd)
        XCTAssertNotNil(refusedSingle.warning)
    }
}
