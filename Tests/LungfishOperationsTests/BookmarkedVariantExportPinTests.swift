import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Lane 12.39 M1 pins of B6, the bookmarked variants export, kept for its bytes after the app's writer went (c4).
/// The rows are built from each database's stored bookmarks as the drawer built them before the leaf, which is the
/// trace that the 8 columns follow from the databases and the leaf needs no selection. The record's facts, on the
/// app's side and the leaf's, are pinned in `VariantExportCLIGUIParityReplayTests`.
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

    func testBytesFollowFromTheStoredBookmarks() throws {
        let first = try makeDatabase(named: "first", body: """
        chr1\t100\trs100\tA\tG\t50\tPASS\t.\tGT\t0/1\t0/0
        chr1\t200\trs200\tC\tT\t.\tq10\t.\tGT\t1/1\t0/1
        chr2\t50\trs50\tG\tA\t12.5\tPASS\t.\tGT\t0/0\t0/1
        """, bookmarking: ["rs200", "rs50"])
        let second = try makeDatabase(named: "second", body: """
        chr3\t10\trs10\tT\tC\t60\tPASS\t.\tGT\t0/1\t0/1
        """, bookmarking: ["rs10"])

        // The drawer's loop before the leaf, one database after another, as the leaf reads them now.
        var rows: [BookmarkedVariantExport.Row] = []
        for url in [first, second] {
            for record in try VariantDatabase(url: url).bookmarkedVariants() {
                rows.append(.init(
                    name: record.variantID, type: record.variantType,
                    chromosome: record.chromosome, start: record.position, ref: record.ref, alt: record.alt,
                    quality: record.quality, filter: record.filter
                ))
            }
        }

        XCTAssertEqual(BookmarkedVariantExport.tsv(rows: rows), """
        ID\tType\tChrom\tPos\tRef\tAlt\tQuality\tFilter
        rs200\tSNP\tchr1\t200\tC\tT\t.\tq10
        rs50\tSNP\tchr2\t50\tG\tA\t12.5\tPASS
        rs10\tSNP\tchr3\t10\tT\tC\t60.0\tPASS

        """)
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
