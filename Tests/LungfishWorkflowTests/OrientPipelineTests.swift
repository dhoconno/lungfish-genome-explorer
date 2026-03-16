import XCTest
@testable import LungfishWorkflow

final class OrientPipelineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrientPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTabbedOutput(at url: URL) throws -> String {
        let longReadID = String(repeating: "A", count: 70_000)
        let content = [
            "\(longReadID)\t+\tref1",
            "read-2\t-\tref1",
            "read-3\t?\t*",
            "read-4\t+\tref2",
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return longReadID
    }

    func testCreateOrientMapStreamsLargeTabbedOutput() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tabbedOutput = tempDir.appendingPathComponent("orient-results.tsv")
        let longReadID = try makeTabbedOutput(at: tabbedOutput)
        let outputURL = tempDir.appendingPathComponent("orient-map.tsv")

        let pipeline = OrientPipeline()
        let counts = try pipeline.createOrientMap(from: tabbedOutput, to: outputURL)

        XCTAssertEqual(counts.forwardCount, 2)
        XCTAssertEqual(counts.rcCount, 1)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("\(longReadID)\t+\n"))
        XCTAssertTrue(content.contains("read-2\t-\n"))
        XCTAssertFalse(content.contains("read-3\t"))
    }

    func testParseOrientResultsCountsChunkedAndTrailingRecords() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tabbedOutput = tempDir.appendingPathComponent("orient-results.tsv")
        _ = try makeTabbedOutput(at: tabbedOutput)

        let pipeline = OrientPipeline()
        let counts = try pipeline.parseOrientResults(tabbedOutput)

        XCTAssertEqual(counts.forward, 2)
        XCTAssertEqual(counts.rc, 1)
        XCTAssertEqual(counts.unmatched, 1)
    }
}
