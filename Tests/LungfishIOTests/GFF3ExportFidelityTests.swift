// GFF3ExportFidelityTests.swift - What a GFF3 export of imported features writes in columns 2 and 9
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane GFF3-FIDELITY (walk GFF3-a S3 and GFF3-b S4, UX ruling in UX-WALK.md). The annotation database holds
// the attributes of a feature and not its source, so an export has no source to give. It writes the undefined value
// `.` in column 2 and never claims that Lungfish made an imported feature, and it adds no `Name` that the file did not
// have. Storing the imported source is a 3.1 backlog row, so these tests pin the dot and not the file's own `walk`.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GFF3ExportFidelityTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GFF3ExportFidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `Tests/Fixtures/gff3/two-parent.gff3`, found from the checkout that holds this file. It is the walk's file, source
    /// `walk` on every line, a gene and two mRNAs that carry a Name, and an exon with two parents, a Note and no Name.
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gff3/two-parent.gff3")
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

    /// The fixture imported into an annotation database and exported again, by the feature's ID.
    private func exportedFeatures() async throws -> [String: [String]] {
        let database = folder.appendingPathComponent("two-parent.db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: fixtureURL, outputURL: database)
        let annotations = try AnnotationDatabase(url: database).query(limit: Int.max).map { $0.toAnnotation() }
        var byID: [String: [String]] = [:]
        for columns in try await writtenLines(annotations) {
            let id = try XCTUnwrap(columns[8].split(separator: ";").first { $0.hasPrefix("ID=") })
            byID[String(id.dropFirst(3))] = columns
        }
        return byID
    }

    private func pairs(_ columns: [String]?) throws -> Set<String> {
        Set(try XCTUnwrap(columns)[8].split(separator: ";").map(String.init))
    }

    /// GFF3-a. The database holds no source, so column 2 is the undefined value of GFF3 and not `Lungfish`.
    func testAnImportedFeatureWritesADotInColumnTwo() async throws {
        let features = try await exportedFeatures()
        XCTAssertEqual(features.keys.sorted(), ["exon1", "gene1", "mRNA1", "mRNA2"])
        for (id, columns) in features {
            XCTAssertEqual(columns[1], ".", "column 2 of \(id), a feature Lungfish did not make")
        }
    }

    /// GFF3-b. The exon had no Name, its display name is only its ID, and the export adds nothing to what it held.
    func testAFeatureThatHadNoNameGetsNoName() async throws {
        let features = try await exportedFeatures()
        XCTAssertEqual(
            try pairs(features["exon1"]),
            ["ID=exon1", "Parent=mRNA1,mRNA2", "Note=protein%2C partial"],
            "column 9 of the exon"
        )
    }

    /// The pin for what must not move. A Name the file had stays, and a two-valued Parent and an escaped comma in a
    /// Note come back as the lane GFF3 made them.
    func testFeaturesThatHadANameKeepItAndTheirParent() async throws {
        let features = try await exportedFeatures()
        XCTAssertEqual(try pairs(features["gene1"]), ["ID=gene1", "Name=WALKG1"])
        XCTAssertEqual(try pairs(features["mRNA1"]), ["ID=mRNA1", "Name=WALKT1", "Parent=gene1"])
        XCTAssertEqual(try pairs(features["mRNA2"]), ["ID=mRNA2", "Name=WALKT2", "Parent=gene1"])
    }

    /// The writer cannot tell a feature that Lungfish made from one that a file brought (an annotation carries no origin,
    /// and a primer or a manual annotation lives in the same kind of database row), so it writes the dot for both. A
    /// feature with no stored attributes has only its name, and the export keeps it.
    func testAnAnnotationWithNoStoredAttributesWritesADotAndKeepsItsName() async throws {
        let made = SequenceAnnotation(type: .gene, name: "my gene", chromosome: "chr1", start: 10, end: 50)
        let lines = try await writtenLines([made])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?[1], ".")
        XCTAssertTrue(lines.first?[8].split(separator: ";").contains("Name=my gene") == true, "column 9 \(lines)")
    }
}
