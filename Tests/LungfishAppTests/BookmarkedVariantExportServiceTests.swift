import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class BookmarkedVariantExportServiceTests: XCTestCase {
    func testCapturedBookmarksReplayAfterSourceAndLiveSelectionChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkExport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("variants.db")
        try Data("source revision".utf8).write(to: source)
        let output = root.appendingPathComponent("bookmarks.tsv")
        var liveRows = [BookmarkedVariantExportService.Row(trackID: "captured-track", rowID: 37,
            name: "captured-row", type: "SNP", chromosome: "synthetic", start: 4,
            ref: "A", alt: "C", quality: 20, filter: "PASS")]
        let request = BookmarkedVariantExportService.Request(sourceURLs: [source], rows: liveRows, outputURL: output)
        liveRows.removeAll()
        try BookmarkedVariantExportService.export(request)
        let expected = try Data(contentsOf: output)
        XCTAssertTrue(String(decoding: expected, as: UTF8.self).contains("captured-row\tSNP\tsynthetic\t5"))
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        let replay = try XCTUnwrap(receipt.durableReplayArgv)
        XCTAssertEqual(replay.first, "/bin/cp")
        let selection = try XCTUnwrap(receipt.files.first { $0.role == .input && $0.path.hasSuffix("selection.json") })
        let metadata = try String(contentsOfFile: selection.path, encoding: .utf8)
        XCTAssertTrue(metadata.contains("captured-track"))
        XCTAssertTrue(metadata.contains("37"))
        XCTAssertTrue(metadata.contains("captured-row"))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: output)
        guard replay.count == 3, replay.first == "/bin/cp" else { return XCTFail("Expected retained copy replay") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = Array(replay.dropFirst())
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: output), expected)
    }
}
