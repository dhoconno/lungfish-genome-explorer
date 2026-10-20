// GzipReaderPinTests.swift - The bytes, lines and words of the gzip readers, pinned before they move to ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Phase 2.13 lane 13.06 (M1). `forEachLine`, `forEachDecompressedChunk`, `readAllSync` and `GzipLineSource` give one
/// answer for every file shape, whatever carries the gzip child. These tests hold that answer, so they pass at the
/// base and unchanged after each reader moves.
final class GzipReaderPinTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        let folder = try TestTempDirectory.make(prefix: "gzip-reader-pin")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        tempDir = folder
    }

    // MARK: Helpers

    private func gzip(_ text: String, named name: String = "f-\(UUID().uuidString).txt") throws -> URL {
        try GzipPinSupport.gzip(text, in: tempDir, named: name)
    }

    /// A gzip of 8,000 lines of 1,000 bytes, which gzip cannot fit in a pipe, so its child waits for the reader.
    private func bigGzip() throws -> URL {
        let line = String(repeating: "ACGT", count: 250)
        return try gzip(Array(repeating: line, count: 8_000).joined(separator: "\n") + "\n", named: "big-\(UUID().uuidString).txt")
    }

    private struct Observed {
        var lines: [String] = []
        var lineError: String?
        var chunkBytes = Data()
        var chunkSizes: [Int] = []
        var chunkError: String?
        var whole: String?
        var wholeError: String?
        var sourceLines: [String] = []
        var sourceError: String?
        var errors: [String] { [lineError, chunkError, wholeError, sourceError].compactMap { $0 } }
    }

    /// What each of the four readers gives for one file, with the words of the error it ended on.
    private func observe(_ url: URL, chunkSize: Int = 1_048_576) -> Observed {
        var observed = Observed()
        do {
            try GzipInputStream(url: url).forEachLine { observed.lines.append($0) }
        } catch { observed.lineError = error.localizedDescription }
        do {
            try GzipInputStream(url: url).forEachDecompressedChunk(chunkSize: chunkSize) {
                observed.chunkBytes.append($0)
                observed.chunkSizes.append($0.count)
            }
        } catch { observed.chunkError = error.localizedDescription }
        do {
            observed.whole = try GzipInputStream(url: url).readAllSync()
        } catch { observed.wholeError = error.localizedDescription }
        do {
            let source = try GzipLineSource(url: url, chunkSize: chunkSize)
            defer { source.close() }
            while let line = try source.next() { observed.sourceLines.append(line) }
        } catch { observed.sourceError = error.localizedDescription }
        return observed
    }

    private func assertFraming(
        _ text: String, lines expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let observed = observe(try gzip(text))
        XCTAssertEqual(observed.lines, expected, "forEachLine", file: file, line: line)
        XCTAssertEqual(observed.sourceLines, expected, "GzipLineSource", file: file, line: line)
        XCTAssertEqual(observed.chunkBytes, Data(text.utf8), "forEachDecompressedChunk", file: file, line: line)
        XCTAssertEqual(observed.whole, text, "readAllSync", file: file, line: line)
        XCTAssertEqual(observed.errors, [], file: file, line: line)
    }

    // MARK: Bytes and line framing

    func testLineFramingIsTheSameForEveryReader() throws {
        try assertFraming("a\nb\n", lines: ["a", "b"])
        try assertFraming("a\r\nb\r\n", lines: ["a", "b"])
        try assertFraming("a\rb\nc\r", lines: ["a\rb", "c"])
        try assertFraming("a\nb", lines: ["a", "b"])
        try assertFraming("a\n\nb\n", lines: ["a", "", "b"])
        try assertFraming("\n", lines: [""])
        try assertFraming("", lines: [])
        try assertFraming("caf\u{e9}\n\u{1F9EC}\n", lines: ["caf\u{e9}", "\u{1F9EC}"])
    }

    func testACRLFSplitAcrossTheOneMebibyteChunkIsOneLineBreak() throws {
        let long = String(repeating: "A", count: 1_048_575)
        try assertFraming("\(long)\r\ntail\r\n", lines: [long, "tail"])
    }

    func testAMultiMemberFileReadsEveryMember() throws {
        let first = try gzip("a\nb\n")
        let second = try gzip("c\nd")
        let joined = tempDir.appendingPathComponent("joined.txt.gz")
        try (Data(contentsOf: first) + Data(contentsOf: second)).write(to: joined)
        let observed = observe(joined)
        XCTAssertEqual(observed.lines, ["a", "b", "c", "d"])
        XCTAssertEqual(observed.sourceLines, ["a", "b", "c", "d"])
        XCTAssertEqual(observed.chunkBytes, Data("a\nb\nc\nd".utf8))
        XCTAssertEqual(observed.whole, "a\nb\nc\nd")
        XCTAssertEqual(observed.errors, [])
    }

    func testDecompressedChunksHaveTheRequestedSizeExceptTheLast() throws {
        let url = try gzip(String(repeating: "ACGT", count: 650_000))
        let observed = observe(url)
        XCTAssertEqual(observed.chunkSizes, [1_048_576, 1_048_576, 2_600_000 - 2 * 1_048_576])
        XCTAssertEqual(observed.chunkBytes.count, 2_600_000)
    }

    // MARK: The words of each GzipError

    func testTheWordsOfEveryGzipError() throws {
        let missing = tempDir.appendingPathComponent("missing.gz")
        XCTAssertEqual(GzipError.fileNotFound(missing).errorDescription, "Gzip file not found: \(missing.path)")
        XCTAssertEqual(GzipError.invalidFormat.errorDescription, "Invalid gzip format (expected magic bytes 0x1f 0x8b)")
        XCTAssertEqual(GzipError.decompressionFailed("x").errorDescription, "Gzip decompression failed: x")
        XCTAssertEqual(GzipError.emptyFile.errorDescription, "Gzip file is empty")

        XCTAssertThrowsError(try GzipInputStream(url: missing)) {
            XCTAssertEqual($0.localizedDescription, "Gzip file not found: \(missing.path)")
        }
        XCTAssertThrowsError(try GzipLineSource(url: missing)) {
            XCTAssertEqual($0.localizedDescription, "Gzip file not found: \(missing.path)")
        }

        let zero = tempDir.appendingPathComponent("zero.gz")
        try Data().write(to: zero)
        XCTAssertEqual(observe(zero).errors, Array(repeating: "Gzip file is empty", count: 4))

        let notGzip = tempDir.appendingPathComponent("plain.gz")
        try Data("hello\n".utf8).write(to: notGzip)
        XCTAssertEqual(
            observe(notGzip).errors,
            Array(repeating: "Invalid gzip format (expected magic bytes 0x1f 0x8b)", count: 4)
        )
    }

    func testInvalidUTF8GivesTheChunkWordsAndLeavesTheBytesAlone() throws {
        let inLine = observe(try GzipPinSupport.gzip([0x61, 0xFF, 0x0A, 0x62], in: tempDir, named: "bad1.txt"))
        XCTAssertEqual(inLine.lineError, "Gzip decompression failed: Invalid UTF-8 encoding in chunk")
        XCTAssertEqual(inLine.sourceError, "Gzip decompression failed: Invalid UTF-8 encoding in chunk")
        XCTAssertEqual(inLine.wholeError, "Gzip decompression failed: Invalid UTF-8 encoding")
        XCTAssertEqual(inLine.chunkBytes, Data([0x61, 0xFF, 0x0A, 0x62]))
        XCTAssertNil(inLine.chunkError)

        let inFinal = observe(try GzipPinSupport.gzip([0x61, 0xFF], in: tempDir, named: "bad2.txt"))
        XCTAssertEqual(inFinal.lineError, "Gzip decompression failed: Invalid UTF-8 encoding in final chunk")
        XCTAssertEqual(inFinal.sourceError, "Gzip decompression failed: Invalid UTF-8 encoding in final chunk")
        XCTAssertEqual(inFinal.chunkBytes, Data([0x61, 0xFF]))
    }

    func testATruncatedFileDeliversWhatGzipDecodedThenGivesGzipsWords() throws {
        let expected = (0..<60_000).map { "line \($0) ACGTTGCAACGTTGCA" }
        let full = try gzip(expected.joined(separator: "\n") + "\n", named: "trunc.txt")
        let observed = observe(try GzipPinSupport.truncated(full, removing: 30, as: "cut.txt.gz"))

        XCTAssertEqual(observed.errors.count, 4, "every reader ends on gzip's error: \(observed.errors)")
        for message in observed.errors {
            XCTAssertTrue(message.hasPrefix("Gzip decompression failed: "), message)
            XCTAssertTrue(message.contains("unexpected end of file"), message)
        }
        XCTAssertNil(observed.whole, "readAllSync returns nothing for a failed file")
        XCTAssertFalse(observed.lines.isEmpty)
        XCTAssertEqual(Array(observed.lines.dropLast()), Array(expected.prefix(observed.lines.count - 1)))
        XCTAssertGreaterThanOrEqual(observed.sourceLines.count, observed.lines.count - 1)
        XCTAssertEqual(Array(observed.lines.prefix(observed.sourceLines.count)), observed.sourceLines)
        XCTAssertFalse(observed.chunkBytes.isEmpty)
    }

    // MARK: A reader that stops early leaves no child

    func testAnEarlyCloseOfALineSourceLeavesNoGzipChild() throws {
        let url = try bigGzip()
        let source = try GzipLineSource(url: url, chunkSize: 65_536)
        XCTAssertNotNil(try source.next())
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 1, "the child waits on its full pipe while the source is open")
        source.close()
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
        XCTAssertNil(try source.next(), "a closed source stays at its end")
    }

    func testDroppingALineSourceMidFileLeavesNoGzipChild() throws {
        let url = try bigGzip()
        var source: GzipLineSource? = try GzipLineSource(url: url, chunkSize: 65_536)
        XCTAssertNotNil(try source?.next())
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 1)
        source = nil
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
    }

    func testABodyThatThrowsLeavesNoGzipChild() throws {
        struct Stop: Error {}
        let url = try bigGzip()
        var seen = 0
        XCTAssertThrowsError(try url.forEachLineAutoDecompressing { _ in
            seen += 1
            if seen == 3 { throw Stop() }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)

        var chunks = 0
        XCTAssertThrowsError(try url.forEachChunkAutoDecompressing(chunkSize: 65_536) { _ in
            chunks += 1
            throw Stop()
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(chunks, 1)
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
    }

    func testACancelledTaskLeavesNoGzipChildAfterForEachLine() async throws {
        let url = try bigGzip()
        let outcome = await Task.detached { () -> String in
            var seen = 0
            do {
                try url.forEachLineAutoDecompressing { _ in
                    seen += 1
                    if seen == 5 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
    }

    func testACancelledTaskLeavesNoGzipChildAfterTheChunkReader() async throws {
        let url = try bigGzip()
        let outcome = await Task.detached { () -> String in
            do {
                try url.forEachChunkAutoDecompressing(chunkSize: 65_536) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
    }

    func testACancelledLinesConsumerLeavesNoGzipChild() async throws {
        let url = try bigGzip()
        let seen = await Task.detached { () -> Int in
            var seen = 0
            do {
                for try await _ in try GzipInputStream(url: url).lines() {
                    seen += 1
                    if seen == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch {}
            return seen
        }.value
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(GzipPinSupport.gzipChildCount(for: url), 0)
    }
}
