import Foundation
import XCTest
@testable import LungfishIO

final class PlainTextFileHandleTests: XCTestCase {
    private func makeFile(_ data: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-text-handle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.txt")
        try data.write(to: url)
        return url
    }

    func testLinesMatchURLReaderAcrossChunkBoundaryAndLeaveHandleOpen() throws {
        // Place a multibyte character across the one-megabyte read boundary.
        let longLine = String(repeating: "a", count: 1_048_575) + "é"
        let expected = [longLine, "", "last"]
        let data = Data((longLine + "\r\n\nlast\r").utf8)
        let url = try makeFile(data)
        var urlLines: [String] = []
        try url.forEachLineAutoDecompressing { urlLines.append($0) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var handleLines: [String] = []
        try handle.forEachPlainTextLine { handleLines.append($0) }
        XCTAssertEqual(urlLines, expected)
        XCTAssertEqual(handleLines, expected)
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.readToEnd(), data)
    }

    func testReadsAlreadyOpenUnlinkedFileFromCurrentOffset() throws {
        let url = try makeFile(Data("skip\nretained\n".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 5)
        try FileManager.default.removeItem(at: url)
        var lines: [String] = []
        try handle.forEachPlainTextLine { lines.append($0) }
        XCTAssertEqual(lines, ["retained"])
        XCTAssertEqual(try handle.offset(), 14)
    }

    func testCallbackErrorDoesNotCloseCallerHandle() throws {
        struct ExpectedError: Error {}
        let url = try makeFile(Data("first\nsecond\n".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertThrowsError(try handle.forEachPlainTextLine { _ in throw ExpectedError() }) {
            XCTAssertTrue($0 is ExpectedError)
        }
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.read(upToCount: 5), Data("first".utf8))
    }

    func testInvalidUTF8FailsWithoutClosingCallerHandle() throws {
        let data = Data([0xff, 0x0a])
        let handle = try FileHandle(forReadingFrom: makeFile(data))
        defer { try? handle.close() }
        XCTAssertThrowsError(try handle.forEachPlainTextLine { _ in XCTFail("Invalid UTF-8 must not emit a line") }) {
            guard case GzipError.decompressionFailed = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.readToEnd(), data)
    }

    func testCancellationDoesNotCloseCallerHandle() async throws {
        let data = Data("retained\n".utf8)
        let handle = try FileHandle(forReadingFrom: makeFile(data))
        defer { try? handle.close() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try handle.forEachPlainTextLine { _ in XCTFail("Cancelled reader must not emit a line") }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Caller ownership survives cancellation.
        }
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.readToEnd(), data)
    }

    func testReadFailureThrowsAndLeavesWriteOnlyHandleOwnedByCaller() throws {
        let url = try makeFile(Data("original".utf8))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        XCTAssertThrowsError(try handle.forEachPlainTextLine { _ in XCTFail("Unreadable handle must not emit a line") })
        try handle.write(contentsOf: Data("X".utf8))
        XCTAssertEqual(try Data(contentsOf: url).first, UInt8(ascii: "X"))
    }
}
