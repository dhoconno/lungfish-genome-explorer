// GFF3WriterPhaseTests.swift - Column 8 of a CDS that GFF3Writer writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 R5, F10). `GFF3Writer` serves `lungfish-cli bundle export gff3` and
// `lungfish-cli convert`, and the phase of a CDS's 5' segment is the one the file was read with.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GFF3WriterPhaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GFF3WriterPhase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The feature lines `GFF3Writer` writes for `annotations`, each split into its nine columns.
    private func writtenLines(_ annotations: [SequenceAnnotation]) async throws -> [[String]] {
        let url = folder.appendingPathComponent("written-\(UUID().uuidString).gff3")
        try await GFF3Writer.write(annotations, to: url)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Pin 7 (F10). A GenBank CDS `1..13` with `/codon_start=2` is read with phase 1 on its one interval, and a
    /// GFF3 line of it says phase 1, so a reader of the file finds its codons from base 2 as the record does.
    func testGFF3WriterKeepsTheFivePrimePhaseOfASingleBlockCDS() async throws {
        let genbank = folder.appendingPathComponent("phase.gb")
        try """
        LOCUS       PHASEONE                 20 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  codon_start phase fixture.
        ACCESSION   PHASEONE
        VERSION     PHASEONE.1
        FEATURES             Location/Qualifiers
             source          1..20
                             /organism="synthetic construct"
             CDS             1..13
                             /codon_start=2
                             /gene="f"
        ORIGIN
                1 aatgagctgg taaccaaaaa
        //
        """.write(to: genbank, atomically: true, encoding: .utf8)
        let records = try await GenBankReader(url: genbank).readAll()
        let cds = try XCTUnwrap(records.first?.annotations.first { $0.type == .cds })
        XCTAssertEqual(cds.intervals.map(\.phase), [1], "the reader carries codon_start=2 as phase 1")

        let lines = try await writtenLines([cds])

        XCTAssertEqual(lines.map { [$0[2], $0[3], $0[4], $0[7]] }, [["CDS", "1", "13", "1"]])
    }

    /// F-B65-DUP (MD66). A GFF3 that repeats a CDS line imports as a CDS with two equal segments, and the writer's
    /// map of phase by segment start trapped on the repeated start. Each line keeps the first phase computed for it.
    func testGFF3WriterWritesACDSWithARepeatedSegment() async throws {
        let cds = SequenceAnnotation(
            type: .cds, name: "dup", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 0, end: 9), AnnotationInterval(start: 0, end: 9)], strand: .forward
        )

        let lines = try await writtenLines([cds])

        XCTAssertEqual(lines.map { [$0[3], $0[4], $0[7]] }, [["1", "9", "0"], ["1", "9", "0"]])
    }
}
