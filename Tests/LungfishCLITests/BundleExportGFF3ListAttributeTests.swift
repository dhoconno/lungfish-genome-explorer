// BundleExportGFF3ListAttributeTests.swift - bundle export-gff3 keeps a Parent list and a Dbxref list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane GFF3 (GFF3-MULTIVALUE, BIO ruling). A GFF3 that holds a feature with two parents and an NCBI
// cross-reference list is imported into a bundle and exported through `lungfish bundle export-gff3`. The export writes
// the commas that separate the items, so a tool that follows the GFF3 specification finds two parents and two
// cross-references. A comma inside free text stays escaped.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class BundleExportGFF3ListAttributeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExportGFF3List-\(UUID().uuidString)", isDirectory: true)
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

    /// A reference bundle whose one annotation database `createFromGFF3` built from `Self.gff3`.
    private func makeBundle() async throws -> URL {
        let bundle = folder.appendingPathComponent("lists.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("annotations"), withIntermediateDirectories: true)
        let gff = folder.appendingPathComponent("lists.gff3")
        try Self.gff3.write(to: gff, atomically: true, encoding: .utf8)
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gff, outputURL: bundle.appendingPathComponent("annotations/genes.db")
        )
        try BundleManifest(
            name: "List Attribute Fixture",
            identifier: "org.lungfish.gff3-list-attribute-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: nil,
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    /// The column 9 pairs of each exported feature line, keyed by the line's feature type.
    private func exportedPairs(of bundle: URL) async throws -> [String: [String]] {
        let output = folder.appendingPathComponent("exported-\(UUID().uuidString).gff3")
        let parsed = try LungfishCLI.parseAsRoot(["bundle", "export-gff3", bundle.path, "-o", output.path])
        let command = try XCTUnwrap(parsed as? BundleExportGFF3Subcommand)
        _ = try await command.export()
        var pairsByType: [String: [String]] = [:]
        for line in try String(contentsOf: output, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(columns.count, 9, "\(line)")
            pairsByType[columns[2], default: []] += columns[8].split(separator: ";").map(String.init)
        }
        return pairsByType
    }

    /// The exon with `Parent=mRNA1,mRNA2` and the CDS with the Dbxref list export with their separators, the CDS keeps
    /// its single parent, and the note keeps its escaped comma.
    func testExportKeepsAParentListAndADbxrefList() async throws {
        let pairs = try await exportedPairs(of: try await makeBundle())

        XCTAssertTrue(pairs["exon"]?.contains("Parent=mRNA1,mRNA2") == true, "\(pairs["exon"] ?? [])")
        XCTAssertTrue(
            pairs["CDS"]?.contains("Dbxref=GenBank:YP_009724389.1,GeneID:43740578") == true, "\(pairs["CDS"] ?? [])"
        )
        XCTAssertTrue(pairs["CDS"]?.contains("Parent=mRNA1") == true, "\(pairs["CDS"] ?? [])")
        XCTAssertTrue(pairs["CDS"]?.contains("Note=protein%2C partial") == true, "\(pairs["CDS"] ?? [])")
    }
}
