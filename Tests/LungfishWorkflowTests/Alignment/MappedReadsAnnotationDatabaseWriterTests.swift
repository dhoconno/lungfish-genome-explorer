import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class MappedReadsAnnotationDatabaseWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedReadsAnnotationDatabaseWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteRowsCreatesQueryableAnnotationDatabaseWithAttributes() throws {
        let outputURL = tempDir.appendingPathComponent("mapped_reads.db")
        let rows = [
            MappedReadsAnnotationRow(
                name: "read-1",
                type: "mapped_read",
                chromosome: "chr1",
                start: 100,
                end: 125,
                strand: "+",
                attributes: [
                    "read_name": "read-1",
                    "mapq": "42",
                    "cigar": "25M",
                    "tag_NM": "0",
                    "tag_XX": "a=b;c",
                ]
            ),
            MappedReadsAnnotationRow(
                name: "read-2",
                type: "mapped_read",
                chromosome: "chr2",
                start: 50,
                end: 75,
                strand: "-",
                attributes: ["mapq": "60"]
            ),
        ]

        let count = try MappedReadsAnnotationDatabaseWriter.write(
            rows: rows,
            to: outputURL,
            metadata: ["source_alignment_track_id": "aln-source"]
        )

        XCTAssertEqual(count, 2)
        let database = try AnnotationDatabase(url: outputURL)
        let records = database.queryByRegion(chromosome: "chr1", start: 90, end: 130)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.name, "read-1")
        XCTAssertEqual(record.type, "mapped_read")
        XCTAssertEqual(record.strand, "+")

        let attributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(record.attributes))
        XCTAssertEqual(attributes["read_name"], "read-1")
        XCTAssertEqual(attributes["mapq"], "42")
        XCTAssertEqual(attributes["cigar"], "25M")
        XCTAssertEqual(attributes["tag_NM"], "0")
        XCTAssertEqual(attributes["tag_XX"], "a=b;c")
    }

    func testAttributeSerializationPercentEncodesGFF3Separators() {
        let serialized = MappedReadsAnnotationDatabaseWriter.serializeAttributes([
            "eq": "a=b",
            "semi": "a;b",
            "space": "a b",
        ])

        let parsed = AnnotationDatabase.parseAttributes(serialized)
        XCTAssertEqual(parsed["eq"], "a=b")
        XCTAssertEqual(parsed["semi"], "a;b")
        XCTAssertEqual(parsed["space"], "a b")
    }
}
