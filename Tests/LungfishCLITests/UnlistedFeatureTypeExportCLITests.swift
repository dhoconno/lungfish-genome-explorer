// UnlistedFeatureTypeExportCLITests.swift - a misc_RNA keeps its type on bundle export-gff3, on convert to GenBank and after reopen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// MISC-RNA-AS-GENE (S1, BIO-MISC-RNA-AS-GENE-17R, section 5 (c)). A stored type that `AnnotationType` does not list was
// written as `gene` by `bundle export-gff3` (the app's Export Annotations as GFF3) and by `convert --to-format
// genbank`, and a bundle made again from the GFF3 file counted it as a gene. The fixture is part 1's source track (a
// gene, a three-exon mRNA and a two-part misc_feature) with a misc_RNA of three blocks and a listed ncRNA beside it, so
// the ruling's NG-4tracks counts of one misc_RNA and no other gene apply in small. The built lungfish-cli runs each step.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport

final class UnlistedFeatureTypeExportCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unlisted-type-export-cli")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private typealias Fixture = GFF3ExportReopenMultiPartCLITests

    /// HBBP1's shape, a misc_RNA of three blocks, and a listed ncRNA of one.
    private static let extraRows = [
        Fixture.bedRow(
            name: "HBBP1", type: "misc_RNA", blocks: [(100, 160), (300, 380), (500, 560)],
            attributes: "ID=rna-HBBP1;Name=HBBP1"
        ),
        Fixture.bedRow(name: "ncA", type: "ncRNA", blocks: [(20, 40)], attributes: "ID=nc-A;Name=ncA"),
    ]

    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        try Fixture.runCLI(arguments, in: root, for: Self.self)
    }

    /// Exports the source bundle as GFF3 and returns the file.
    private func exportGFF3(of source: URL) throws -> URL {
        let exported = root.appendingPathComponent("exported.gff3")
        let export = try run(["bundle", "export-gff3", source.path, "-o", exported.path])
        XCTAssertEqual(export.status, 0, "the export writes. \(export.stdout) \(export.stderr)")
        return exported
    }

    /// How many features of each type a list of types holds.
    private static func counts(_ types: [String]) -> [String: Int] {
        Dictionary(types.map { ($0, 1) }, uniquingKeysWith: +)
    }

    // MARK: - The two export routes

    /// `bundle export-gff3` writes the misc_RNA as three `misc_RNA` lines and keeps the one stored gene as the only
    /// gene. `convert --to-format genbank` prints one `misc_RNA` feature and the one gene. Neither turns another
    /// row into a gene, and the listed ncRNA, mRNA and misc_feature keep their types.
    func testBundleExportGFF3AndConvertToGenBankKeepTheMiscRNAType() throws {
        let source = try Fixture.makeSourceBundle(in: root, extraRows: Self.extraRows)

        let exported = try exportGFF3(of: source)
        let gff3Types = try String(contentsOf: exported, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { String($0.split(separator: "\t", omittingEmptySubsequences: false)[2]) }
        XCTAssertEqual(
            Self.counts(gff3Types),
            ["gene": 1, "mRNA": 3, "misc_feature": 2, "misc_RNA": 3, "ncRNA": 1],
            "the type of each line of the GFF3 file. \(gff3Types)"
        )

        let genBank = root.appendingPathComponent("exported.gb")
        let convert = try run([
            "convert", source.path, "--to", genBank.path, "--to-format", "genbank", "--include-annotations",
        ])
        XCTAssertEqual(convert.status, 0, "the conversion writes. \(convert.stdout) \(convert.stderr)")
        let genBankKeys = try String(contentsOf: genBank, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("     "), !line.hasPrefix("      ") else { return nil }
            let key = line.dropFirst(5).split(separator: " ", maxSplits: 1).first.map(String.init)
            return key == "source" ? nil : key
        }
        XCTAssertEqual(
            Self.counts(genBankKeys),
            ["gene": 1, "mRNA": 1, "misc_feature": 1, "misc_RNA": 1, "ncRNA": 1],
            "the key of each feature of the GenBank file. \(genBankKeys)"
        )
    }

    // MARK: - After reopen

    /// A bundle made again from the export holds one misc_RNA row of three blocks, one gene row and no other gene.
    func testABundleMadeFromTheExportHoldsOneMiscRNARowAndNoOtherGene() throws {
        let source = try Fixture.makeSourceBundle(in: root, extraRows: Self.extraRows)
        let exported = try exportGFF3(of: source)

        let genome = root.appendingPathComponent("genome.fa")
        try ">chr1\n\(Fixture.sequence)\n".write(to: genome, atomically: true, encoding: .utf8)
        let outputDirectory = root.appendingPathComponent("created", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let create = try run([
            "bundle", "create", "--fasta", genome.path, "--annotation", exported.path, "--name", "Reopened",
            "--output-dir", outputDirectory.path,
        ])
        XCTAssertEqual(create.status, 0, "the new bundle is made. \(create.stdout) \(create.stderr)")
        let created = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "lungfishref" },
            "bundle create writes a .lungfishref. \(create.stdout) \(create.stderr)"
        )

        let rows = try Fixture.rows(ofTrack: nil, in: created)
        XCTAssertEqual(
            Self.counts(rows.map(\.type)),
            ["gene": 1, "mRNA": 1, "misc_feature": 1, "misc_RNA": 1, "ncRNA": 1],
            "one row of each type. \(rows.map { "\($0.type):\($0.start)-\($0.end)" })"
        )
        let miscRNA = rows.first { $0.type == "misc_RNA" }
        XCTAssertEqual(miscRNA?.blockCount, 3, "the misc_RNA keeps its three parts")
        XCTAssertEqual(miscRNA?.blockSizes, "60,80,60")
        XCTAssertEqual(miscRNA?.blockStarts, "0,200,400")
    }
}
