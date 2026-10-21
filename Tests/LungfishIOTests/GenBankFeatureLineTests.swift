// GenBankFeatureLineTests.swift - The feature key and location GenBankWriter prints for each annotation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.41 M3 (row M858 GENBANK-FEATURE-LINE, the BIO ruling on lane 12.13 section 3). The writer
// prints the key and the location the reader read while the reader's own type map gives the annotation's type
// back and the reader's own parse of the location gives the annotation's ranges, range strands and feature
// strand. Otherwise it prints the key in lower case and a location rebuilt from the ranges, as before. These
// tests reach the rule through files only, read with GenBankReader and written with GenBankWriter.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenBankFeatureLineTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-feature-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A key, a partial CDS, an unmapped key, an `order()`, a partial reverse range and a mixed strand `join()`
    /// print as the file had them.
    func testTheWriterKeepsTheKeyAndLocationItRead() throws {
        let lines = [
            Self.line("CDS", "join(<1..30,50..>80)"),
            Self.line("misc_RNA", "85..>100"),
            Self.line("gene", "order(105..110,115..120)"),
            Self.line("exon", "complement(<125..>135)"),
            Self.line("misc_feature", "join(complement(141..145),150..160)"),
        ]
        let records = try read(lines.flatMap { [$0, Self.qualifier("note=\"kept\"")] })
        XCTAssertEqual(records.first?.annotations.count, 5)
        XCTAssertEqual(try featureLines(of: records), lines)
    }

    /// `/codon_start=2` sets the phase of the CDS and leaves its location as read.
    func testACodonStartOfTwoSetsThePhaseAndKeepsTheLocation() throws {
        let records = try read([Self.line("CDS", "complement(<1..30)"), Self.qualifier("codon_start=2")])
        let annotation = try XCTUnwrap(records.first?.annotations.first)
        XCTAssertEqual(annotation.intervals.map(\.phase), [1])
        XCTAssertEqual(try featureLines(of: records), [Self.line("CDS", "complement(<1..30)")])
        let reread = try XCTUnwrap(GenBankReader(url: lastWritten).readAllSync().first?.annotations.first)
        XCTAssertEqual(reread.intervals.map(\.phase), [1])
    }

    /// A type changed after the read prints the type's key in lower case, and the location, which still holds,
    /// prints as read.
    func testAnEditedTypePrintsTheKeyOfTheType() throws {
        let records = try Self.edited(read([Self.line("CDS", "<1..30")])) { annotations in
            annotations[0].type = .gene
        }
        XCTAssertEqual(try featureLines(of: records), [Self.line("gene", "<1..30")])
    }

    /// Ranges shifted after the read, and a feature strand reversed after the read, print a location rebuilt from
    /// the ranges, while the key, which still maps to the type, prints as read.
    func testShiftedOrReversedRangesPrintARebuiltLocation() throws {
        let source = [Self.line("CDS", "join(<1..30,50..>80)"), Self.line("gene", "90..120")]
        let records = try Self.edited(read(source)) { annotations in
            annotations[0].intervals = annotations[0].intervals.map { interval in
                AnnotationInterval(
                    start: interval.start + 10, end: interval.end + 10, phase: interval.phase, strand: interval.strand
                )
            }
            annotations[1].strand = .reverse
        }
        XCTAssertEqual(try featureLines(of: records), [
            Self.line("CDS", "join(11..40,60..90)"),
            Self.line("gene", "complement(90..120)"),
        ])
    }

    /// An annotation without the reader's internal qualifiers prints today's text, a lower-case key and a location
    /// rebuilt from its ranges.
    func testAnAnnotationWithoutTheReadersMarksPrintsTodaysText() throws {
        let records = try Self.edited(read([Self.line("CDS", "order(<1..30,50..80)")])) { annotations in
            annotations[0].qualifiers[GenBankReader.rawFeatureTypeQualifierKey] = nil
            annotations[0].qualifiers[GenBankReader.rawLocationQualifierKey] = nil
        }
        XCTAssertEqual(try featureLines(of: records), [Self.line("cds", "join(1..30,50..80)")])
    }

    /// A source key longer than the 15 characters of the key column maps to `misc_feature` and the reader keeps it
    /// whole, but the key column would cut it to a key the source never had, so the writer prints the key of the
    /// type, as it did before the rule.
    func testAKeyLongerThanFifteenCharactersPrintsTheKeyOfTheType() throws {
        let records = try read(["     unknown_long_feature_key 1..10"])
        let type = try XCTUnwrap(records.first?.annotations.first).type
        XCTAssertEqual(try featureLines(of: records), [Self.line(type.rawValue.lowercased(), "1..10")])
    }

    /// A written file reads back to the same types, ranges, range strands and feature strands as the first read.
    func testAWrittenFileReadsBackToTheSameRangesAndStrands() throws {
        let records = try read([
            Self.line("CDS", "complement(join(<16..21,25..>36))"), Self.qualifier("codon_start=3"),
            Self.line("misc_feature", "order(40..45,50..55)"),
            Self.line("gene", "join(complement(60..65),70..75)"),
            Self.line("variation", "100"),
        ])
        _ = try featureLines(of: records)
        let reread = try XCTUnwrap(GenBankReader(url: lastWritten).readAllSync().first)
        let first = try XCTUnwrap(records.first)
        XCTAssertEqual(
            reread.annotations.map(GenBankFeatureLinePinTests.shape),
            first.annotations.map(GenBankFeatureLinePinTests.shape)
        )
        XCTAssertEqual(
            reread.annotations.map { $0.intervals.map(\.phase) },
            first.annotations.map { $0.intervals.map(\.phase) }
        )
    }

    // MARK: - Helpers

    private var lastWritten: URL { folder.appendingPathComponent("written.gb") }

    /// Reads a 160-base record whose feature table holds `features`.
    private func read(_ features: [String]) throws -> [GenBankRecord] {
        let url = folder.appendingPathComponent("source.gb")
        try Self.record(features).write(to: url, atomically: true, encoding: .utf8)
        return try GenBankReader(url: url).readAllSync()
    }

    /// Writes `records` to ``lastWritten`` and returns the lines of the file that open a feature.
    private func featureLines(of records: [GenBankRecord]) throws -> [String] {
        try GenBankWriter(url: lastWritten).write(records)
        let text = try String(contentsOf: lastWritten, encoding: .utf8)
        XCTAssertFalse(text.contains("/_lf_"), text)
        return GenBankFeatureLinePinTests.featureLines(text)
    }

    /// `records` with the annotations of each record changed by `change`, as an edit after the read.
    static func edited(
        _ records: [GenBankRecord],
        _ change: (inout [SequenceAnnotation]) -> Void
    ) -> [GenBankRecord] {
        records.map { record in
            var annotations = record.annotations
            change(&annotations)
            return GenBankRecord(
                sequence: record.sequence, annotations: annotations, locus: record.locus,
                definition: record.definition, accession: record.accession, version: record.version,
                recordFields: record.recordFields
            )
        }
    }

    /// A feature line as GenBank lays it out, the key from column 6 and the location from column 22.
    static func line(_ key: String, _ location: String) -> String {
        "     " + key.padding(toLength: 15, withPad: " ", startingAt: 0) + " " + location
    }

    /// A qualifier line.
    static func qualifier(_ text: String) -> String {
        String(repeating: " ", count: 21) + "/" + text
    }

    /// A 160-base record whose feature table holds `features`.
    static func record(_ features: [String]) -> String {
        ([
            "LOCUS       lineA                    160 bp    DNA     linear   SYN 01-JAN-2026",
            "DEFINITION  Synthetic record for the feature line rule.",
            "FEATURES             Location/Qualifiers",
        ] + features + [
            "ORIGIN",
            "        1 acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac acgtacgtac ggttaaccgg",
            "       61 ttaaccggtt acgtacgtac acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac",
            "      121 acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac",
            "//",
            "",
        ]).joined(separator: "\n")
    }
}
