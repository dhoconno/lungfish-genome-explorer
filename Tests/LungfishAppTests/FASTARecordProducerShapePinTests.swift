// FASTARecordProducerShapePinTests.swift - The shape of each FASTA record a viewer hands to the records export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34, review fix 6 (the QA 1 debt of reviews/12.34.md ruling 1 item 1). The FASTA records export
// joins the records its callers build and refuses a text that does not start with a header, where the old writer wrote
// whatever it was given. A producer that stops starting its record with `>` would then fail an export and no test.
// Each test below pins one producer that a test can reach with a literal that starts with `>` and ends with a line
// feed. The NVD contig's producer is private to NvdResultViewController and stays out of reach.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class FASTARecordProducerShapePinTests: XCTestCase {
    /// The rule the export adds. A record is equal to its literal, starts with a header and ends with a line feed, so
    /// the joined text of any caller starts with a header.
    private func assertRecord(
        _ record: String, equals literal: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(record, literal, file: file, line: line)
        XCTAssertTrue(record.hasPrefix(">"), "a record starts with a header", file: file, line: line)
        XCTAssertTrue(record.hasSuffix("\n"), "a record ends with a line feed", file: file, line: line)
    }

    /// The alignment's rows, a whole row or a column range named `row:cols`, with one line of bases each.
    func testAnAlignmentRowRecordIsItsHeaderAndOneLineOfBases() {
        assertRecord(
            MultipleSequenceAlignmentViewController.fastaRecord(name: "row one:3-6", sequence: "GTAC"),
            equals: ">row one:3-6\nGTAC\n"
        )
    }

    /// The FASTA collection's record, with a description and without one, as the formatter writes it.
    func testACollectionRecordKeepsItsDescriptionOnTheHeaderLine() throws {
        let described = try LungfishCore.Sequence(
            name: "chr1", description: "visible track", alphabet: .dna, bases: "ACGTACGT"
        )
        assertRecord(FASTASelectionDetailFormatter.record(for: described), equals: ">chr1 visible track\nACGTACGT\n")
        let plain = try LungfishCore.Sequence(name: "plasmid", alphabet: .dna, bases: "GATTACA")
        assertRecord(FASTASelectionDetailFormatter.record(for: plain), equals: ">plasmid\nGATTACA\n")
    }

    /// An assembly's contigs at the width the assembly view asks for, 70. The header is the whole header line of the
    /// contigs file, and the bases wrap at the width with a line feed after the last line.
    func testAnAssemblyContigRecordIsItsWholeHeaderAndBasesWrappedAtTheWidth() async throws {
        let root = try TestTempDirectory.make(prefix: "FASTARecordProducerShape")
        defer { TestTempDirectory.cleanup(root) }
        let bases = String(repeating: "ACGT", count: 25)
        let contigsURL = root.appendingPathComponent("contigs.fasta")
        try ">contig_1 length=100\n\(bases)\n>contig_2 short\nGATTACA\n".write(
            to: contigsURL, atomically: true, encoding: .utf8
        )
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        let result = AssemblyResult(
            tool: .spades, readType: .illuminaShortReads, contigsPath: contigsURL, graphPath: nil, logPath: nil,
            assemblerVersion: "test", commandLine: "spades.py --isolate", outputDirectory: root,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL), wallTimeSeconds: 1.0
        )
        let catalog = try await AssemblyContigCatalog(result: result)

        let long = try await catalog.sequenceFASTA(for: "contig_1", lineWidth: 70)
        assertRecord(long, equals: ">contig_1 length=100\n\(bases.prefix(70))\n\(bases.dropFirst(70))\n")
        let short = try await catalog.sequenceFASTA(for: "contig_2", lineWidth: 70)
        assertRecord(short, equals: ">contig_2 short\nGATTACA\n")
    }
}
