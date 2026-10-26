// AnnotationDatabaseGFFExporterListAttributeTests.swift - The leaf writes a stored list attribute as a list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane GFF3 (GFF3-MULTIVALUE, BIO ruling). The import stores every comma of a value as `%2C`, because the
// reader has already merged the separators and the escaped commas of a value. The leaf exporter copies a stored pair as
// it is, so before this lane a `Parent` of two IDs and a `Dbxref` list left as one value with `%2C`. The leaf now writes
// the five list attributes (`GFF3Writer.listAttributeKeys`) through the writer's own encoder, and every other stored pair
// stays byte for byte.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AnnotationDatabaseGFFExporterListAttributeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseGFFExporterList-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Two mRNAs, one exon of both, and one CDS with an NCBI cross-reference list and a note that holds a comma.
    private static let gff3 = """
        ##gff-version 3
        chr1\ttest\tmRNA\t1\t1000\t.\t+\t.\tID=mRNA1
        chr1\ttest\tmRNA\t1\t1000\t.\t+\t.\tID=mRNA2
        chr1\ttest\texon\t1\t300\t.\t+\t.\tID=exon1;Parent=mRNA1,mRNA2
        chr1\ttest\tCDS\t50\t300\t.\t+\t0\tID=cds1;Parent=mRNA1;Dbxref=GenBank:YP_009724389.1,GeneID:43740578;Note=protein%2C partial

        """

    /// The database `createFromGFF3` builds from `text`.
    private func importedDatabase(_ text: String) async throws -> AnnotationDatabase {
        let gff = folder.appendingPathComponent("rows-\(UUID().uuidString).gff3")
        try text.write(to: gff, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("rows-\(UUID().uuidString).db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: gff, outputURL: url)
        return try AnnotationDatabase(url: url)
    }

    /// The leaf's export of `database`, as the file it wrote.
    private func export(_ database: AnnotationDatabase) throws -> URL {
        let url = folder.appendingPathComponent("export-\(UUID().uuidString).gff3")
        try AnnotationDatabaseGFFExporter.export(database: database, to: url)
        return url
    }

    /// The column 9 pairs of each feature line of the file at `url`, keyed by the line's feature type.
    private func pairsByType(of url: URL) throws -> [String: [String]] {
        var pairs: [String: [String]] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(columns.count, 9, "\(line)")
            pairs[columns[2], default: []] += columns[8].split(separator: ";").map(String.init)
        }
        return pairs
    }

    /// A GFF3 imported into a database and written by the leaf keeps the separators of its lists, and the escaped
    /// comma of its note.
    func testTheLeafKeepsAParentListAndADbxrefListOfAnImportedGFF3() async throws {
        let database = try await importedDatabase(Self.gff3)

        let pairs = try pairsByType(of: try export(database))

        XCTAssertTrue(pairs["exon"]?.contains("Parent=mRNA1,mRNA2") == true, "\(pairs["exon"] ?? [])")
        XCTAssertTrue(
            pairs["CDS"]?.contains("Dbxref=GenBank:YP_009724389.1,GeneID:43740578") == true, "\(pairs["CDS"] ?? [])"
        )
        XCTAssertTrue(pairs["CDS"]?.contains("Parent=mRNA1") == true, "\(pairs["CDS"] ?? [])")
        XCTAssertTrue(pairs["CDS"]?.contains("Note=protein%2C partial") == true, "\(pairs["CDS"] ?? [])")
    }

    /// Each stored pair of a list attribute is decoded and written through the writer's encoder, in its stored place.
    /// A pair stored with raw commas by an older import, and every pair of another key, stay as stored.
    func testColumnNineWritesEachStoredListPairAsAList() {
        func record(_ attributes: String) -> AnnotationDatabaseRecord {
            AnnotationDatabaseRecord(
                name: "cds-N", type: "CDS", chromosome: "chr1", start: 0, end: 30, strand: "+", attributes: attributes
            )
        }
        let cases: [(stored: String, column9: String)] = [
            ("ID=cds-N;Dbxref=GenBank:X.1%2CGeneID:7;Parent=m1%2Cm2", "ID=cds-N;Dbxref=GenBank:X.1,GeneID:7;Parent=m1,m2"),
            (
                "Alias=a%2Cb;Derives_from=t1%2Ct2;Note=n%2Cm;Ontology_term=GO:1%2CSO:2;product=p%2Cq",
                "Alias=a,b;Derives_from=t1,t2;Note=n%2Cm;Ontology_term=GO:1,SO:2;product=p%2Cq"
            ),
            ("ID=cds-N;Alias=x%3By%2Cz%3Dw%26v%25", "ID=cds-N;Alias=x%3By,z%3Dw%26v%25"),
            ("ID=cds-N;Dbxref=a,b", "ID=cds-N;Dbxref=a,b"),
            ("ID=cds-N;Dbxref=GeneID:7", "ID=cds-N;Dbxref=GeneID:7"),
            ("ID=cds-N;Parent_note=c%2Cd", "ID=cds-N;Parent_note=c%2Cd"),
            ("lungfish_gff_phase=1;ID=cds-N;Parent=m1%2Cm2", "ID=cds-N;Parent=m1,m2"),
        ]
        for (stored, column9) in cases {
            XCTAssertEqual(
                AnnotationDatabaseGFFExporter.columnNine(for: record(stored), fallbackID: "lungfish-row-9"), column9,
                "stored \(stored)"
            )
        }
    }

    /// Guard, which passes at the base. The reader decodes a value before it splits it, so the file the leaf writes
    /// imports back to the stored pairs it came from, and the fix changes nothing a re-import stores.
    func testExportedListsImportBackToTheSameStoredPairs() async throws {
        let first = try await importedDatabase(Self.gff3)
        let exported = try String(contentsOf: try export(first), encoding: .utf8)

        let second = try await importedDatabase(exported)

        func stored(_ database: AnnotationDatabase) -> [String: String?] {
            Dictionary(uniqueKeysWithValues: database.query(limit: Int.max).map { ($0.name, $0.attributes) })
        }
        XCTAssertEqual(stored(second), stored(first))
        XCTAssertEqual(stored(first).count, 4)
    }
}
