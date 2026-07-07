import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class CountedFASTQMaterializerTests: XCTestCase {
    func testMaterializesCountedExactSequenceExemplars() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountedFASTQMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.fastq")
        let output = root.appendingPathComponent("counted.fastq")

        try """
        @read1
        acgt
        +
        IIII
        @read2
        ACGT
        +
        IIII
        @read3;size=3
        TTTT
        +
        IIII
        """.write(to: input, atomically: true, encoding: .utf8)

        let result = try await CountedFASTQMaterializer().materialize(
            inputs: [input],
            outputURL: output
        )

        XCTAssertEqual(result.inputRecordCount, 3)
        XCTAssertEqual(result.totalReadCount, 5)
        XCTAssertEqual(result.uniqueSequenceCount, 2)
        XCTAssertEqual(result.uniqueBaseCount, 8)
        XCTAssertEqual(result.weightedBaseCount, 20)

        var records: [FASTQRecord] = []
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: output) {
            records.append(record)
        }
        XCTAssertEqual(records.map(\.identifier), ["u000001;size=3", "u000002;size=2"])
        XCTAssertEqual(records.map(\.sequence), ["TTTT", "ACGT"])
    }

    func testCompressedMaterializationReportsGzipProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountedFASTQMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.fastq")
        let output = root.appendingPathComponent("counted.fastq.gz")

        try """
        @read1
        acgt
        +
        IIII
        """.write(to: input, atomically: true, encoding: .utf8)

        let result = try await CountedFASTQMaterializer().materialize(
            inputs: [input],
            outputURL: output,
            compress: true
        )

        let compression = try XCTUnwrap(result.compression)
        XCTAssertEqual(result.outputURL, output.standardizedFileURL)
        XCTAssertEqual(result.materializedOutput.path, compression.input.path)
        XCTAssertEqual(compression.command, ["/usr/bin/gzip", "-1", "-c", result.materializedOutput.path])
        XCTAssertEqual(compression.output.path, output.path)
        XCTAssertEqual(compression.exitCode, 0)
        XCTAssertGreaterThanOrEqual(compression.wallTime, 0)
        XCTAssertNotNil(compression.input.sha256)
        XCTAssertNotNil(compression.input.sizeBytes)
        XCTAssertNotNil(compression.output.sha256)
        XCTAssertNotNil(compression.output.sizeBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.materializedOutput.path))
    }
}
