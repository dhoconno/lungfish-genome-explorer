import Foundation
import XCTest
@testable import LungfishOperations
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Lane 12.39 M1 pins of B6, the bookmarked variants export, at the base with no Sources edit (QA 1). The rows
/// are built from each database's stored bookmarks exactly as `AnnotationTableDrawerView+Bookmarks.swift` builds
/// them, which is the trace that the 8 columns follow from the databases and the leaf needs no selection.
final class BookmarkedVariantExportPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkedVariantExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBytesAndRecordFollowFromTheStoredBookmarks() throws {
        let first = try makeDatabase(named: "first", body: """
        chr1\t100\trs100\tA\tG\t50\tPASS\t.\tGT\t0/1\t0/0
        chr1\t200\trs200\tC\tT\t.\tq10\t.\tGT\t1/1\t0/1
        chr2\t50\trs50\tG\tA\t12.5\tPASS\t.\tGT\t0/0\t0/1
        """, bookmarking: ["rs200", "rs50"])
        let second = try makeDatabase(named: "second", body: """
        chr3\t10\trs10\tT\tC\t60\tPASS\t.\tGT\t0/1\t0/1
        """, bookmarking: ["rs10"])
        let databases = [("first-track", first), ("second-track", second)]

        // The drawer's loop (`AnnotationTableDrawerView+Bookmarks.swift:120-156`), one database after another.
        var rows: [BookmarkedVariantExportService.Row] = []
        for (_, url) in databases {
            for record in try VariantDatabase(url: url).bookmarkedVariants() {
                rows.append(.init(
                    name: record.variantID, type: record.variantType,
                    chromosome: record.chromosome, start: record.position, ref: record.ref, alt: record.alt,
                    quality: record.quality, filter: record.filter
                ))
            }
        }
        let output = root.appendingPathComponent("bookmarked variants.tsv")
        try BookmarkedVariantExportService.export(.init(sourceURLs: [first, second], rows: rows, outputURL: output))

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), """
        ID\tType\tChrom\tPos\tRef\tAlt\tQuality\tFilter
        rs200\tSNP\tchr1\t200\tC\tT\t.\tq10
        rs50\tSNP\tchr2\t50\tG\tA\t12.5\tPASS
        rs10\tSNP\tchr3\t10\tT\tC\t60.0\tPASS

        """)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)
        ))
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, [
            "Lungfish Genome Explorer", "export-bookmarked-variants",
            "--variant-database", first.path, "--variant-database", second.path, "--output", output.path,
        ])
        XCTAssertEqual(envelope.workflowName, "lungfish app bookmarked variant export")
        // Lane 12.39 c2, the side A fix (settled answers of 12.31, G3 and M4). The record names the databases the
        // export read, each with its digest, and never a retained copy of its own payload, so its replay is its argv
        // and not `/bin/cp`. At the base it named `selected.tsv` and `selection.json` and replayed `/bin/cp`.
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map(\.path), [first.standardizedFileURL.path, second.standardizedFileURL.path])
        XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil }, "each database with its digest")
        XCTAssertEqual(Set(envelope.options.resolvedDefaults.keys), ["variantCount"])
        XCTAssertEqual(envelope.options.resolvedDefaults["variantCount"]?.integerValue, 3)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath", "sourceVariantDatabasePaths"])
        XCTAssertEqual(envelope.options.defaults.keys.sorted(), ["outputFormat"])
        XCTAssertEqual(envelope.options.defaults["outputFormat"]?.stringValue, "tsv")
    }

    /// The failure path reaches the drawer's alert, "Bookmark Export Failed" with the error's own words
    /// (`AnnotationTableDrawerView+Bookmarks.swift:166-170`). A refused publication throws before any byte lands.
    func testFailureKeepsTheExistingFile() throws {
        let output = root.appendingPathComponent("previous.tsv")
        try Data("previous".utf8).write(to: output)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BookmarkedVariantExportService.export(.init(sourceURLs: [], rows: [], outputURL: output))) {
            XCTAssertFalse($0.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("previous".utf8))
    }

    private func makeDatabase(named name: String, body: String, bookmarking ids: Set<String>) throws -> URL {
        let vcfURL = root.appendingPathComponent("\(name).vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A\tSAMPLE_B
        \(body)
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(name).db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL, readWrite: true)
        let records = try database.queryForTableExport(
            nameFilter: "", types: [], infoFilters: [], sampleNames: [], smartFilter: nil, activeTokens: [], limit: Int.max
        )
        for record in records where ids.contains(record.variantID) {
            XCTAssertTrue(database.toggleBookmark(variantId: try XCTUnwrap(record.id)))
        }
        return databaseURL
    }
}
