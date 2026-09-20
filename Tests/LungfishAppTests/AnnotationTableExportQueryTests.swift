import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO

final class AnnotationTableExportQueryTests: XCTestCase {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0

        func cancelAfterTwoChecks() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks > 2
        }
    }

    func testAnnotationAllMatchingIgnoresDisplayCapAndReturnsEveryMatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportQueryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("annotations.db")
        let bedURL = directory.appendingPathComponent("annotations.bed")
        try "chr1\t0\t5\tgene-0\t0\t+\t0\t5\t0,0,0\t1\t5\t0\tgene\ttag=value-0\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)
        do {
            let writable = try AnnotationDatabase(url: databaseURL, readWrite: true)
            for index in 1..<5 {
                _ = try writable.insertAnnotation(
                    name: "gene-\(index)", type: "gene", chromosome: "chr1",
                    start: index * 10, end: index * 10 + 5, strand: "+",
                    attributes: "tag=value-\(index)", geneName: "gene-\(index)"
                )
            }
        }
        let request = AnnotationTableAnnotationQueryRequest(
            databases: [("track", databaseURL, "Genes")],
            allowedChromosomes: ["chr1"], nameFilter: "gene-", types: ["gene"],
            query: .init(), databaseColumnFilters: [], allColumnFilters: [],
            numericSortKeys: ["start", "end", "size"],
            sortKey: "start", sortAscending: true
        )

        let rows = try request.run(shouldCancel: { false })

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.annotationRowId).compactMap { $0 }.count, 5)
        XCTAssertEqual(rows.map(\.start), [0, 10, 20, 30, 40])

        let latePostfilter = AnnotationTableAnnotationQueryRequest(
            databases: [("track", databaseURL, "Genes")],
            allowedChromosomes: ["chr1"], nameFilter: "gene-", types: ["gene"],
            query: .init(), databaseColumnFilters: [],
            allColumnFilters: [.init(key: "attr_tag", op: "=", value: "value-4")],
            numericSortKeys: ["start", "end", "size"],
            sortKey: "start", sortAscending: true
        )
        let lateRows = try latePostfilter.run(shouldCancel: { false })
        XCTAssertEqual(lateRows.map(\.name), ["gene-4"])
    }

    func testAnnotationAllMatchingHonorsEmptyAllowedChromosomeScope() throws {
        let request = AnnotationTableAnnotationQueryRequest(
            databases: [], allowedChromosomes: [], nameFilter: "", types: [],
            query: .init(), databaseColumnFilters: [], allColumnFilters: [],
            numericSortKeys: ["start", "end", "size"],
            sortKey: nil, sortAscending: true
        )
        XCTAssertEqual(try request.run(shouldCancel: { false }).count, 0)
    }

    func testQueryCancellationDuringSQLiteEnumerationIsAnErrorRatherThanSuccessfulEmptyExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("annotations.db")
        let bedURL = directory.appendingPathComponent("annotations.bed")
        try "chr1\t0\t5\tgene-0\t0\t+\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)
        do {
            let writable = try AnnotationDatabase(url: databaseURL, readWrite: true)
            for index in 1..<500 {
                _ = try writable.insertAnnotation(
                    name: "gene-\(index)", type: "gene", chromosome: "chr1",
                    start: index * 10, end: index * 10 + 5, strand: "+",
                    attributes: nil, geneName: nil
                )
            }
        }
        let request = AnnotationTableAnnotationQueryRequest(
            databases: [("track", databaseURL, "Genes")], allowedChromosomes: nil,
            nameFilter: "", types: [],
            query: .init(), databaseColumnFilters: [], allColumnFilters: [],
            numericSortKeys: ["start", "end", "size"],
            sortKey: nil, sortAscending: true
        )
        let probe = CancellationProbe()

        XCTAssertThrowsError(try request.run(shouldCancel: { probe.cancelAfterTwoChecks() })) { error in
            XCTAssertEqual(error.localizedDescription, "The table export query was cancelled.")
        }
    }

    func testStringInfoEqualityDoesNotUseNumericCoercion() {
        let row = AnnotationSearchIndex.SearchResult(
            name: "id", chromosome: "chr1", start: 0, end: 1,
            trackId: "track", type: "SNV", ref: "A", alt: "G",
            variantRowId: 1, infoDict: ["SAMPLE_ID": "00123"]
        )
        XCTAssertFalse(tableVariantColumnMatches(
            row: row,
            clause: .init(key: "info_SAMPLE_ID", op: "=", value: "123"),
            numericColumnKeys: [],
            callerSettingsByTrack: [:]
        ))
    }

    func testVariantAllMatchingExceedsDisplayCapAndAppliesLateStringInfoPostfilter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantTableExportQueryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vcfURL = directory.appendingPathComponent("variants.vcf")
        let databaseURL = directory.appendingPathComponent("variants.db")
        let records = (1...6).map { index in
            let sampleID = index == 6 ? "00123" : "sample-\(index)"
            return "chr1\t\(100 + index)\tivar-\(index)\tA\tG\t30\tPASS\tSAMPLE_ID=\(sampleID)"
        }.joined(separator: "\n")
        try """
        ##fileformat=VCFv4.2
        ##INFO=<ID=SAMPLE_ID,Number=1,Type=String,Description="Imported sample identifier">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        \(records)
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL)
        let context = AnnotationVariantQueryContext(
            databases: [("track", database)], trackNames: ["track": "iVar"],
            trackChromosomes: ["track": ["chr1"]], annotationDatabases: [],
            infoKeys: ["SAMPLE_ID"], variantAliasMap: [:]
        )
        func request(filters: [AnnotationTableDrawerView.VariantColumnFilterClause]) -> AnnotationTableVariantQueryRequest {
            AnnotationTableVariantQueryRequest(
                context: context, query: .init(), types: [], infoFilters: [],
                selectedSamples: [], activeTokens: [], region: nil, geneList: nil,
                filterBookmarkedOnly: false, filterModerateOrHigher: false,
                withinSampleAFRange: nil, bookmarkedKeys: [], hiddenTrackIDs: [],
                variantColumnFilters: filters, callerSettingsByTrack: ["track": "Caller: iVar"],
                resolverSnapshot: .empty, numericColumnKeys: [],
                sortKey: "position", sortAscending: true
            )
        }

        let allRows = try request(filters: []).run(shouldCancel: { false })
        let simulatedDisplayCap = 2
        XCTAssertEqual(allRows.count, 6)
        XCTAssertGreaterThan(allRows.count, simulatedDisplayCap)

        let lateRows = try request(filters: [
            .init(key: "info_SAMPLE_ID", op: "=", value: "00123")
        ]).run(shouldCancel: { false })
        XCTAssertEqual(lateRows.map(\.name), ["ivar-6"])
        XCTAssertEqual(lateRows.first?.infoDict?["SAMPLE_ID"], "00123")
    }
}
