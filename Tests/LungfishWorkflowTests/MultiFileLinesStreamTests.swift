// MultiFileLinesStreamTests.swift - The line stream across several FASTQ files: order, an error, a cancel and no files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DEMUXSPLIT-MEM review SF1 and SF3. `URL.multiFileLinesAutoDecompressing` is pulled on demand and four callers read it
// (the exact-bare pass, the exact barcode demux, the ONT and PacBio materializer and the FASTQ reads export). These pins
// hold what each of them relies on: the lines of every file in list order, plain or gzip; the earlier lines and then the
// error of a file that cannot be read; the end of the stream at its first error; the end at the next pull of a cancelled
// task; and no line for no files. Pins 1, 2 and 5 give the same answer on the base stream, which read ahead in a producer task. At the base pin 3 threw on its second pull and pin 4 counted 22 lines where the head stops at 10.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MultiFileLinesStreamTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "multi-file-lines")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Four lines of a file, different from the lines of every other file: `<tag>1` to `<tag>4`.
    private func fourLines(_ tag: String) -> [String] {
        (1...4).map { "\(tag)\($0)" }
    }

    @discardableResult
    private func write(_ lines: [String], to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collect(_ urls: [URL]) async throws -> [String] {
        var collected: [String] = []
        for try await line in URL.multiFileLinesAutoDecompressing(urls) { collected.append(line) }
        return collected
    }

    /// A plain file, a gzip file and a plain file give their lines in the order of the list.
    func testPlainGzipAndPlainFilesYieldTheirLinesInListOrder() async throws {
        let a = fourLines("a"), b = fourLines("b"), c = fourLines("c")
        let first = try write(a, to: "a.fastq")
        let plainB = try write(b, to: "b-plain.txt")
        let gz = root.appendingPathComponent("b.fastq.gz")
        try await SystemToolProbe.gzip(plainB, to: gz)
        let third = try write(c, to: "c.fastq")
        let collected = try await collect([first, gz, third])
        XCTAssertEqual(collected.filter { !$0.isEmpty }, a + b + c)
    }

    /// A file that cannot be read ends the stream with its error, after the lines of the file before it.
    func testAMissingSecondFileGivesTheFirstFilesLinesThenTheError() async throws {
        let a = fourLines("a")
        let first = try write(a, to: "a.fastq")
        let missing = root.appendingPathComponent("missing.fastq")
        var collected: [String] = []
        var caught: Error?
        do {
            for try await line in URL.multiFileLinesAutoDecompressing([first, missing]) { collected.append(line) }
        } catch {
            caught = error
        }
        XCTAssertEqual(collected, a, "the lines of the first file arrive before the error")
        XCTAssertNotNil(caught, "the missing file ends the stream with its error")
    }

    /// After its first error the stream gives no line: it does not read on, and a file whose pull failed does not start
    /// again from its first line (SF3).
    func testAnErrorEndsTheStream() async throws {
        let missing = root.appendingPathComponent("missing.fastq")
        var iterator = URL.multiFileLinesAutoDecompressing([missing]).makeAsyncIterator()
        var threw = false
        do {
            _ = try await iterator.next()
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "the first pull throws the error of the missing file")
        let second = try await iterator.next()
        XCTAssertNil(second, "the pull after the error returns nil")
    }

    /// A consumer that cancels its own task gets no line after the pull in which it cancelled, and no error.
    func testACancelledConsumerEndsTheStreamAtItsNextPull() async throws {
        let first = try write((1...1_000).map { "a\($0)" }, to: "a.fastq")
        let second = try write((1...1_000).map { "b\($0)" }, to: "b.fastq")
        let consumer = Task { () -> (count: Int, error: Error?) in
            var count = 0
            do {
                for try await _ in URL.multiFileLinesAutoDecompressing([first, second]) {
                    count += 1
                    if count == 10 { _ = withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch {
                return (count, error)
            }
            return (count, nil)
        }
        let outcome = await consumer.value
        XCTAssertNil(outcome.error, "a cancel ends the stream with no error")
        XCTAssertEqual(outcome.count, 10, "the loop ended at the next pull after the 10th line")
    }

    /// No files give no line and no error.
    func testNoFilesEndsAtOnce() async throws {
        let collected = try await collect([])
        XCTAssertEqual(collected, [])
    }
}
