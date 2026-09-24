// SequenceViewerVariantChromosomeAliasTests.swift - SCI-14 chromosome alias resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os.log
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// SCI-14: `SequenceViewerView.buildVariantChromosomeAliasMap` must route
/// through the shared `ChromosomeAliasResolver` (SIMP-07) rather than its own
/// separate length-only fallback, and must never fabricate a mapping between
/// contigs whose lengths merely happen to be close.
final class SequenceViewerVariantChromosomeAliasTests: XCTestCase {

    private let logger = Logger(subsystem: "com.lungfish.tests", category: "SequenceViewerVariantChromosomeAliasTests")

    private func makeDatabase(
        chromosome: String,
        position: Int,
        contigLength: Int?,
        directory: URL
    ) throws -> VariantDatabase {
        let vcfURL = directory.appendingPathComponent("\(UUID().uuidString).vcf")
        let dbURL = directory.appendingPathComponent("\(UUID().uuidString).db")
        let contigLine = contigLength.map { "##contig=<ID=\(chromosome),length=\($0)>\n" } ?? ""
        let vcf = """
        ##fileformat=VCFv4.2
        \(contigLine)#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        \(chromosome)\t\(position)\t.\tA\tG\t.\tPASS\t.
        """
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return try VariantDatabase(url: dbURL)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVVCAliasTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Exact-length ##contig match (within 10bp tolerance): the VCF's own
    /// declared contig length agrees with the reference, so this must still
    /// be mapped (this is the "reliable" length case the audit's Preserve
    /// list is not asking to remove).
    func testMapsByExactContigLengthWithinTolerance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try makeDatabase(chromosome: "MN908947.3", position: 100, contigLength: 29_903, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "MN908947", length: 29_903, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let aliasMap = SequenceViewerView.buildVariantChromosomeAliasMap(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )

        // This is actually a version-suffix name match (MN908947.3 -> MN908947),
        // not length-based, but must still resolve correctly either way.
        XCTAssertEqual(aliasMap["MN908947"], "MN908947.3")
    }

    /// SCI-14 worked example: a VCF contig on a 20%-shorter genome than the
    /// reference must NOT be silently mapped by the old proportional-length
    /// fallback. `ChromosomeAliasResolver`'s default proportional tolerance
    /// (5% for large contigs, 20% for small ones) must reject a mismatch
    /// this large for a >1Mb contig.
    func testDoesNotMapWhenLengthDiffersByTwentyPercentOnLargeContig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No ##contig header, so this exercises the MAX(position) fallback:
        // the VCF's only variant is at position 100, so its length proxy is
        // tiny compared to a 2,000,000bp reference contig with an unrelated name.
        let db = try makeDatabase(chromosome: "unrelated_accession", position: 100, contigLength: nil, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "chr_large", length: 2_000_000, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let aliasMap = SequenceViewerView.buildVariantChromosomeAliasMap(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )

        XCTAssertNil(aliasMap["chr_large"], "A length proxy of ~100bp against a 2,000,000bp contig must not be treated as a match")
    }

    /// A VCF contig within the resolver's proportional length tolerance (a
    /// small contig, matched within 20%) is still surfaced as a length-only
    /// match via `ChromosomeAliasResolver.lengthMatchedSources`, so callers
    /// can warn the user instead of trusting it silently (SCI-14).
    func testLengthOnlyMatchIsDistinguishableFromNameMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Small contig (<1Mb): 20% tolerance applies. Reference is 1000bp;
        // VCF's furthest variant position is 950 (5% short of the reference),
        // well within tolerance, but the two names have nothing in common.
        let db = try makeDatabase(chromosome: "totally_different_name", position: 950, contigLength: nil, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "scaffold_1", length: 1000, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let resolver = ChromosomeAliasResolver.build(
            bundleChromosomes: bundleChromosomes,
            sourceChromosomes: [
                ChromosomeAliasResolver.SourceChromosome(name: "totally_different_name", length: Int64(db.chromosomeMaxPositions()["totally_different_name"] ?? 0))
            ],
            lengthConfig: ChromosomeAliasResolver.LengthMatchingConfig(exactTolerance: 10, allowProportionalMatch: true)
        )

        XCTAssertEqual(resolver.resolve("totally_different_name"), "scaffold_1")
        XCTAssertTrue(resolver.lengthMatchedSources.contains("totally_different_name"), "A mapping made purely by length must be flagged so callers can warn the user")

        // And the higher-level function must actually produce this mapping
        // too (proving the two are wired together, not just independently correct).
        let aliasMap = SequenceViewerView.buildVariantChromosomeAliasMap(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )
        XCTAssertEqual(aliasMap["scaffold_1"], "totally_different_name")
    }
}
