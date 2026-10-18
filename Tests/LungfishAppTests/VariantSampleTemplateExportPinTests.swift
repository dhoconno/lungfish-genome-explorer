import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishWorkflow

/// Lane 12.39 M1 pins of B11, the sample metadata template, at the base with no Sources edit (QA 1). The base
/// writes the template inside the save panel's completion (`AnnotationTableDrawerView.swift:4453-4482`), which a
/// test cannot reach, so `frozenTemplate` is that closure copied verbatim with the view's reads made values
/// (`searchIndex.variantDatabaseHandles`, `sampleMetadataFields` and the panel's URL). It writes with
/// `String.write(atomically:)` and records nothing, and a failure only logs.
final class VariantSampleTemplateExportPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantSampleTemplatePin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The base closure, copied with its view reads as parameters.
    static func frozenTemplate(databases: [VariantDatabase], fields: [String], url: URL) throws {
        let isCSV = url.pathExtension.lowercased() == "csv"
        let delimiter = isCSV ? "," : "\t"

        var sampleRows: [(name: String, sourceFile: String)] = []
        var seenRows = Set<String>()
        for db in databases {
            let dbSourceFiles = db.allSourceFiles()
            for sampleName in db.sampleNames() {
                let sourceFile = dbSourceFiles[sampleName] ?? ""
                let normalizedKey = "\(sampleName.lowercased())|\(sourceFile.lowercased())"
                if seenRows.insert(normalizedKey).inserted {
                    sampleRows.append((name: sampleName, sourceFile: sourceFile))
                }
            }
        }
        guard !sampleRows.isEmpty else { return }

        var columns = ["sample_name", "source_file"]
        columns.append(contentsOf: fields)
        let header = columns.joined(separator: delimiter)
        let rows = sampleRows.map { row -> String in
            var values = [row.name, row.sourceFile]
            values.append(contentsOf: Array(repeating: "", count: fields.count))
            return values.joined(separator: delimiter)
        }
        let content = ([header] + rows).joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTemplateBytesForDatabasesWithSeveralSamples() throws {
        let first = try makeDatabase(named: "first", samples: ["SAMPLE_B", "SAMPLE_A"])
        let second = try makeDatabase(named: "second", samples: ["sample_a", "SAMPLE_C"])
        let databases = [try VariantDatabase(url: first), try VariantDatabase(url: second)]
        let fields = ["collection_date", "country"]

        let tsv = root.appendingPathComponent("template.tsv")
        try Self.frozenTemplate(databases: databases, fields: fields, url: tsv)
        XCTAssertEqual(try String(contentsOf: tsv, encoding: .utf8), """
        sample_name\tsource_file\tcollection_date\tcountry
        SAMPLE_A\tfirst.vcf\t\t
        SAMPLE_B\tfirst.vcf\t\t
        SAMPLE_C\tsecond.vcf\t\t
        sample_a\tsecond.vcf\t\t

        """, "each database's samples in `sampleNames()` order, by name, never the VCF's column order")
        let csv = root.appendingPathComponent("template.csv")
        try Self.frozenTemplate(databases: databases, fields: fields, url: csv)
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), """
        sample_name,source_file,collection_date,country
        SAMPLE_A,first.vcf,,
        SAMPLE_B,first.vcf,,
        SAMPLE_C,second.vcf,,
        sample_a,second.vcf,,

        """)
        // No record, at the base.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: tsv).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: csv).path))
    }

    private func makeDatabase(named name: String, samples: [String]) throws -> URL {
        let vcfURL = root.appendingPathComponent("\(name).vcf")
        let genotypes = samples.map { _ in "0/1" }.joined(separator: "\t")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t\(samples.joined(separator: "\t"))
        chr1\t100\t.\tA\tG\t50\tPASS\t.\tGT\t\(genotypes)
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(name).db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        return databaseURL
    }
}
