// FASTQPairingModeResolverTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Paired imports are stored as one interleaved FASTQ whose bundle metadata
// says so, and their mates often carry identical names. The resolver is the
// single source of truth every fastq subcommand consults, so these tests pin
// its precedence: explicit flag, then bundle metadata, then read names.

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

    // MARK: - Name-based probe

    func testIdenticalNameMatesAreDetectedWhenAccepted() async throws {
        let url = root.appendingPathComponent("identical.fastq")
        try InterleavedFASTQFixture.write(pairCount: 20, naming: .identical, to: url)

        let strict = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(strict, "The strict mapping probe must keep ignoring identical names")

        let relaxed = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(
            at: url,
            acceptingIdenticalNames: true
        )
        XCTAssertTrue(relaxed, "Adjacent records with the same key and no mate number are a pair")
    }

    func testRelaxedProbeStillRejectsSingleEndReadsWithDistinctNames() async throws {
        let url = root.appendingPathComponent("single.fastq")
        let text = (0..<20).map { index -> String in
            "@read\(index)\n\(InterleavedFASTQFixture.deterministicSequence(seed: UInt64(index)))\n+\n\(String(repeating: "I", count: 60))"
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let relaxed = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(
            at: url,
            acceptingIdenticalNames: true
        )
        XCTAssertFalse(relaxed)
    }

    func testResolverFallsBackToNamesForAllMateNamingStyles() async throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let url = root.appendingPathComponent("\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.write(pairCount: 12, naming: naming, to: url)
            let isInterleaved = try await FASTQPairingModeResolver.isInterleaved(inputURL: url)
            XCTAssertTrue(isInterleaved, "\(naming) mates must be recognised without metadata")
        }
    }

    // MARK: - Bundle metadata

    func testBundleSidecarPairingModeWinsOverNames() async throws {
        // Metadata says interleaved even though every name is distinct, and
        // says single-end even though names look paired: metadata wins.
        let interleavedByMetadata = try InterleavedFASTQFixture.writeBundle(
            named: "meta-interleaved",
            in: root,
            pairCount: 1,
            naming: .identical,
            pairingMode: .interleaved
        )
        XCTAssertEqual(
            FASTQPairingModeResolver.bundlePairingMode(for: interleavedByMetadata.fastqURL),
            .interleaved
        )
        XCTAssertEqual(
            FASTQPairingModeResolver.bundlePairingMode(for: interleavedByMetadata.bundleURL),
            .interleaved
        )
        let resolvedFromFile = try await FASTQPairingModeResolver.isInterleaved(
            inputURL: interleavedByMetadata.fastqURL
        )
        XCTAssertTrue(resolvedFromFile)

        let singleByMetadata = try InterleavedFASTQFixture.writeBundle(
            named: "meta-single",
            in: root,
            pairCount: 12,
            naming: .slashSuffix,
            pairingMode: .singleEnd
        )
        let resolvedSingle = try await FASTQPairingModeResolver.isInterleaved(
            inputURL: singleByMetadata.fastqURL
        )
        XCTAssertFalse(resolvedSingle, "Recorded single-end pairing must override paired-looking names")
    }

    func testLooseFASTQWithoutMetadataReturnsNilBundlePairing() throws {
        let url = root.appendingPathComponent("loose.fastq")
        try InterleavedFASTQFixture.write(pairCount: 2, naming: .identical, to: url)
        XCTAssertNil(FASTQPairingModeResolver.bundlePairingMode(for: url))
    }

    // MARK: - Explicit answer

    func testExplicitAnswerOverridesMetadataAndNames() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "explicit",
            in: root,
            pairCount: 12,
            naming: .identical,
            pairingMode: .interleaved
        )
        let forcedSingle = try await FASTQPairingModeResolver.isInterleaved(
            inputURL: bundle.fastqURL,
            explicit: false
        )
        XCTAssertFalse(forcedSingle)

        let loose = root.appendingPathComponent("loose-single.fastq")
        try "@a\nACGT\n+\nIIII\n@b\nACGT\n+\nIIII\n".write(to: loose, atomically: true, encoding: .utf8)
        let forcedInterleaved = try await FASTQPairingModeResolver.isInterleaved(
            inputURL: loose,
            explicit: true
        )
        XCTAssertTrue(forcedInterleaved)
    }
}
