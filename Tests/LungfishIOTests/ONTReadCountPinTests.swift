// ONTReadCountPinTests.swift - The read count of a plain and a gzip ONT folder, pinned before it moves to ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Phase 2.13 lane 13.06 (M1, BIO 1). `ONTDirectoryImporter.countReadsInFASTQ` counts newlines with `wc -l` and
/// divides by 4, through `gzcat` for a gzip file. These tests record what it gives for each file shape at the base,
/// among them every case where the count is 0 or the call throws.
final class ONTReadCountPinTests: XCTestCase {
    private var tempDir: URL!
    private let importer = ONTDirectoryImporter()

    override func setUpWithError() throws {
        let folder = try TestTempDirectory.make(prefix: "ont-count-pin")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        tempDir = folder
    }

    private func fastq(reads: Int, newline: String = "\n", finalNewline: Bool = true) -> String {
        var text = (0..<reads).map { "@read\($0) runid=abc\(newline)ACGTACGT\(newline)+\(newline)IIIIIIII" }
            .joined(separator: newline)
        if finalNewline && reads > 0 { text += newline }
        return text
    }

    private func plainFile(_ text: String, in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func folder(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAPlainFolderAndAGzipFolderCountTheSameReads() throws {
        let plainDirectory = try folder("barcode01")
        let gzipDirectory = try folder("barcode02")
        var plainTotal = 0
        var gzipTotal = 0
        for (index, reads) in [10, 20, 30].enumerated() {
            let text = fastq(reads: reads)
            plainTotal += try importer.countReadsInFASTQ(
                url: try plainFile(text, in: plainDirectory, named: "chunk_\(index).fastq"))
            gzipTotal += try importer.countReadsInFASTQ(
                url: try GzipPinSupport.gzip(text, in: gzipDirectory, named: "chunk_\(index).fastq"))
        }
        XCTAssertEqual(plainTotal, 60)
        XCTAssertEqual(gzipTotal, 60)
    }

    func testTheCountIsNewlinesOverFourWhateverTheLineEndingsAndTheLastLine() throws {
        let directory = try folder("shapes")
        let shapes: [(name: String, text: String, reads: Int)] = [
            ("crlf", fastq(reads: 3, newline: "\r\n"), 3),
            ("no-final-newline", fastq(reads: 3, finalNewline: false), 2),
            ("one-line", "@read\n", 0),
            ("empty", "", 0),
        ]
        for shape in shapes {
            let plain = try plainFile(shape.text, in: directory, named: "\(shape.name).fastq")
            XCTAssertEqual(try importer.countReadsInFASTQ(url: plain), shape.reads, "plain \(shape.name)")
            let gz = try GzipPinSupport.gzip(shape.text, in: directory, named: "gz-\(shape.name).fastq")
            XCTAssertEqual(try importer.countReadsInFASTQ(url: gz), shape.reads, "gzip \(shape.name)")
        }
    }

    func testAMultiMemberGzipCountsEveryMember() throws {
        let directory = try folder("members")
        let first = try GzipPinSupport.gzip(fastq(reads: 2), in: directory, named: "a.fastq")
        let second = try GzipPinSupport.gzip(fastq(reads: 3), in: directory, named: "b.fastq")
        let joined = directory.appendingPathComponent("joined.fastq.gz")
        try (Data(contentsOf: first) + Data(contentsOf: second)).write(to: joined)
        XCTAssertEqual(try importer.countReadsInFASTQ(url: joined), 5)
    }

    func testAGzipThatGzcatRefusesCountsZero() throws {
        let directory = try folder("broken")
        let whole = try GzipPinSupport.gzip(fastq(reads: 1_000), in: directory, named: "whole.fastq")
        let cut = try GzipPinSupport.truncated(whole, removing: 30, as: "cut.fastq.gz")
        XCTAssertEqual(try importer.countReadsInFASTQ(url: cut), 0, "truncated")

        let notGzip = try plainFile(fastq(reads: 5), in: directory, named: "not-gzip.fastq.gz")
        XCTAssertEqual(try importer.countReadsInFASTQ(url: notGzip), 0, "not gzip")

        let zero = try plainFile("", in: directory, named: "zero.fastq.gz")
        XCTAssertEqual(try importer.countReadsInFASTQ(url: zero), 0, "zero bytes")

        let missing = directory.appendingPathComponent("missing.fastq.gz")
        XCTAssertEqual(try importer.countReadsInFASTQ(url: missing), 0, "missing gzip")
    }

    func testAMissingPlainFileThrowsTheCocoaNoSuchFileError() throws {
        let missing = tempDir.appendingPathComponent("missing.fastq")
        XCTAssertThrowsError(try importer.countReadsInFASTQ(url: missing)) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain, "\(error)")
            XCTAssertEqual(failure.code, NSFileNoSuchFileError, "\(error)")
        }
    }

    /// `true` stands for a counter that exits without reading. A gzip file is not fed by this process, so the call
    /// ends with the count of 0 whether gzcat finished into the pipe or took SIGPIPE.
    func testAGzipCountWhoseCounterExitsEarlyCountsZero() throws {
        let directory = try folder("early")
        let small = try GzipPinSupport.gzip(fastq(reads: 10), in: directory, named: "small.fastq")
        let big = try GzipPinSupport.gzip(fastq(reads: 300_000), in: directory, named: "big.fastq")
        let counter = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertEqual(try importer.countReadsInFASTQ(url: small, lineCounter: counter), 0)
        XCTAssertEqual(try importer.countReadsInFASTQ(url: big, lineCounter: counter), 0)
    }
}
