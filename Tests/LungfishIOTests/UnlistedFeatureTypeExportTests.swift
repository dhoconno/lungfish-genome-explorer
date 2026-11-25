// UnlistedFeatureTypeExportTests.swift - a stored type that AnnotationType does not list keeps its type on export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// MISC-RNA-AS-GENE (S1, BIO-MISC-RNA-AS-GENE-17R, section 5). `AnnotationDatabaseRecord.toAnnotation` mapped a stored
// type that `AnnotationType.from(rawString:)` does not list to `.gene`, so Export Annotations as GFF3 and the GenBank
// route wrote misc_RNA, lnc_RNA, snRNA and 22 more types as `gene`, with no word, and a bundle made again from the
// file counted them as genes. An unlisted type now falls back to `.misc_feature`, as `GenBankReader` does, and keeps
// its string in `GenBankReader.rawFeatureTypeQualifierKey`. The GFF3 writer writes that string as column 3, and the
// GenBank writer prints it as the key when it fits the 15 characters of the key column.

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishIO

final class UnlistedFeatureTypeExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unlisted-type-export")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The 25 types of section 1 of the ruling that `AnnotationType.from(rawString:)` does not list.
    static let unlistedTypes = [
        "misc_RNA", "lnc_RNA", "snRNA", "snoRNA", "miRNA", "tmRNA", "pseudogenic_transcript", "primary_transcript",
        "precursor_RNA", "rep_origin", "misc_recomb", "LTR", "D-loop", "V_segment", "C_region", "J_gene_segment",
        "propeptide", "misc_difference", "operon", "oriT", "telomere", "centromere", "biological_region", "match",
        "start_codon",
    ]

    /// The 7 listed types of the ruling, with the key GenBank prints for each.
    static let listedTypes: [(stored: String, genBankKey: String)] = [
        ("ncRNA", "ncRNA"), ("mobile_element", "mobile_element"), ("regulatory", "regulatory"),
        ("mat_peptide", "mat_peptide"), ("misc_feature", "misc_feature"), ("pseudogene", "pseudogene"),
        ("three_prime_UTR", "3'UTR"),
    ]

    private func record(_ index: Int, type: String) -> AnnotationDatabaseRecord {
        AnnotationDatabaseRecord(
            rowID: Int64(index + 1), name: "f\(index)", type: type, chromosome: "chrT",
            start: index * 5, end: index * 5 + 4, strand: "+", attributes: "ID=id\(index);Name=f\(index)"
        )
    }

    /// The columns of the non-comment lines `GFF3Writer` writes for `annotations`.
    private func gff3Columns(of annotations: [SequenceAnnotation]) async throws -> [[String]] {
        let url = root.appendingPathComponent("out-\(UUID().uuidString).gff3")
        try await GFF3Writer.write(annotations, to: url)
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The value of the attribute `key` in column 9 of a GFF3 line.
    private static func attribute(_ key: String, in columns: [String]) -> String? {
        columns.last?.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// The keys of the feature lines of a GenBank file written for `annotations`, `source` left out.
    private func genBankKeys(of annotations: [SequenceAnnotation]) throws -> [String] {
        let source = root.appendingPathComponent("source-\(UUID().uuidString).gb")
        try GenBankFeatureLineTests.record(["     gene            1..10"]).write(to: source, atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(GenBankReader(url: source).readAllSync().first)
        let replaced = GenBankRecord(
            sequence: read.sequence, annotations: annotations, locus: read.locus, definition: read.definition,
            accession: read.accession, version: read.version, recordFields: read.recordFields
        )
        let output = root.appendingPathComponent("out-\(UUID().uuidString).gb")
        try GenBankWriter(url: output).write([replaced])
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("     "), !line.hasPrefix("      ") else { return nil }
            let key = line.dropFirst(5).split(separator: " ", maxSplits: 1).first.map(String.init)
            return key == "source" ? nil : key
        }
    }

    // MARK: - (a) a misc_RNA of three blocks

    /// HBBP1 of NG_000007 is a misc_RNA of three blocks. It writes `misc_RNA` in column 3 of its three lines, with one ID,
    /// and not `gene`, and it leaves no `_lf_` attribute in the file.
    func testAMiscRNARowOfThreeBlocksWritesMiscRNAOnThreeLinesWithOneID() async throws {
        let row = AnnotationDatabaseRecord(
            rowID: 52, name: "HBBP1", type: "misc_RNA", chromosome: "chrT", start: 1000, end: 2000, strand: "+",
            attributes: "ID=rna-HBBP1;Name=HBBP1;transcript_id=NR_001589.1",
            blockCount: 3, blockSizes: "142,223,263", blockStarts: "0,300,737"
        )
        let annotation = row.toAnnotation(trackID: "genes")
        XCTAssertEqual(annotation.type, .misc_feature, "a type the enum does not list is misc_feature, never gene")
        XCTAssertEqual(annotation.intervals.count, 3)

        let columns = try await gff3Columns(of: [annotation])
        XCTAssertEqual(columns.count, 3, "one line for each block")
        XCTAssertEqual(columns.map { $0[2] }, ["misc_RNA", "misc_RNA", "misc_RNA"], "column 3 keeps the stored type")
        XCTAssertEqual(Set(columns.compactMap { Self.attribute("ID", in: $0) }).count, 1, "one ID on every line")
        XCTAssertTrue(columns.allSatisfy { !($0.last ?? "").contains("_lf_raw_feature_type") }, "the key is no attribute")
        XCTAssertTrue(columns.allSatisfy { ($0.last ?? "").contains("transcript_id=NR_001589.1") }, "the other attributes stay")
    }

    // MARK: - (b) the 25 types, GFF3 and GenBank

    /// None of the 25 types is written as `gene`, and GFF3 keeps each stored string in column 3.
    func testNoUnlistedTypeIsWrittenAsAGeneInGFF3() async throws {
        let annotations = Self.unlistedTypes.enumerated().map { record($0.offset, type: $0.element).toAnnotation() }
        let columns = try await gff3Columns(of: annotations)

        XCTAssertEqual(columns.count, Self.unlistedTypes.count)
        var typeByName: [String: String] = [:]
        for line in columns { typeByName[Self.attribute("Name", in: line) ?? ""] = line[2] }
        for (index, type) in Self.unlistedTypes.enumerated() {
            XCTAssertEqual(typeByName["f\(index)"], type, "\(type) keeps its type in column 3")
        }
        XCTAssertFalse(columns.contains { $0[2] == "gene" }, "no row is written as gene")
    }

    /// None of the 25 types is written as `gene` by `GenBankWriter`. A stored type of 15 characters or fewer is the key
    /// of its feature line, and a longer one is `misc_feature`.
    func testNoUnlistedTypeIsWrittenAsAGeneInGenBank() throws {
        let annotations = Self.unlistedTypes.enumerated().map { record($0.offset, type: $0.element).toAnnotation() }
        let keys = try genBankKeys(of: annotations)

        XCTAssertEqual(keys, Self.unlistedTypes.map { $0.count <= 15 ? $0 : "misc_feature" })
        XCTAssertFalse(keys.contains("gene"), "no row is written as gene")
    }

    // MARK: - After reopen

    /// A misc_RNA of three blocks goes out through `GFF3Writer` and back in through the build as one misc_RNA row of
    /// three blocks, and no gene row.
    func testAMiscRNAKeepsItsTypeAndBlocksThroughWriteAndImport() async throws {
        let row = AnnotationDatabaseRecord(
            rowID: 52, name: "HBBP1", type: "misc_RNA", chromosome: "chrT", start: 1000, end: 2000, strand: "+",
            attributes: "ID=rna-HBBP1;Name=HBBP1", blockCount: 3, blockSizes: "142,223,263", blockStarts: "0,300,737"
        )
        let written = root.appendingPathComponent("reopen.gff3")
        try await GFF3Writer.write([row.toAnnotation(trackID: "genes")], to: written)
        let databaseURL = root.appendingPathComponent("reopen.db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: written, outputURL: databaseURL)
        let rows = try AnnotationDatabase(url: databaseURL).queryByRegion(chromosome: "chrT", start: 0, end: 100_000, limit: 100)

        XCTAssertEqual(rows.map(\.type), ["misc_RNA"], "the row keeps its type and no gene row appears")
        XCTAssertEqual(rows.first?.blockCount, 3)
        XCTAssertEqual(rows.first?.blockSizes, "142,223,263")
    }

    // MARK: - (d) guards

    /// The 7 listed types keep their type: `toAnnotation` gives them their own case with no raw type qualifier, GFF3
    /// writes the stored string and GenBank prints its key.
    func testTheSevenListedTypesKeepTheirType() async throws {
        let annotations = Self.listedTypes.enumerated().map { record($0.offset, type: $0.element.stored).toAnnotation() }
        for (index, annotation) in annotations.enumerated() {
            let stored = Self.listedTypes[index].stored
            XCTAssertNotEqual(annotation.type, .gene, "\(stored) is not a gene")
            XCTAssertNil(annotation.qualifiers[GenBankReader.rawFeatureTypeQualifierKey], "\(stored) needs no raw type")
        }

        let columns = try await gff3Columns(of: annotations)
        var typeByName: [String: String] = [:]
        for line in columns { typeByName[Self.attribute("Name", in: line) ?? ""] = line[2] }
        for (index, listed) in Self.listedTypes.enumerated() {
            XCTAssertEqual(typeByName["f\(index)"], listed.stored, "\(listed.stored) in GFF3")
        }
        XCTAssertEqual(try genBankKeys(of: annotations), Self.listedTypes.map(\.genBankKey), "the keys in GenBank")
    }

    /// A stored attribute string that already holds a raw type keeps it. The fallback adds none beside it.
    func testAStoredRawTypeAttributeWinsOverTheStoredType() {
        let row = AnnotationDatabaseRecord(
            name: "kept", type: "lnc_RNA", chromosome: "chrT", start: 0, end: 50, strand: "+",
            attributes: "ID=k;\(GenBankReader.rawFeatureTypeQualifierKey)=misc_RNA"
        )
        let annotation = row.toAnnotation()
        XCTAssertEqual(annotation.type, .misc_feature)
        XCTAssertEqual(annotation.qualifiers[GenBankReader.rawFeatureTypeQualifierKey]?.values, ["misc_RNA"])
    }

    /// An annotation that `GenBankReader` made from the key misc_RNA is `.misc_feature` with the key in the raw type
    /// qualifier. GFF3 column 3 writes the key and no raw type attribute follows.
    func testAGenBankReadMiscRNAWritesItsKeyInGFF3Column3() async throws {
        let annotation = SequenceAnnotation(
            type: .misc_feature, name: "HBBP1", chromosome: "chrT",
            intervals: [AnnotationInterval(start: 0, end: 50)], strand: .forward,
            qualifiers: [GenBankReader.rawFeatureTypeQualifierKey: AnnotationQualifier("misc_RNA")]
        )
        let columns = try await gff3Columns(of: [annotation])
        XCTAssertEqual(columns.map { $0[2] }, ["misc_RNA"])
        XCTAssertFalse((columns.first?.last ?? "").contains(GenBankReader.rawFeatureTypeQualifierKey))
    }
}
