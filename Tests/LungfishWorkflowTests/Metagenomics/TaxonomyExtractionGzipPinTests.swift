// TaxonomyExtractionGzipPinTests.swift - Pins how the extraction pipeline reads a gzipped Kraken2 output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishCore
@testable import LungfishWorkflow
@testable import LungfishIO

/// Pins the read-ID set that ``TaxonomyExtractionPipeline`` takes from a gzipped Kraken2 per-read output
/// (SPAWN-0, MD92, exit check X6).
///
/// The route is `extractEachSource`. The set is seen through the records it extracts from a source FASTQ, since
/// `buildReadIdSet` is private. Every gzipped input is compared with the same bytes as a plain file, with and
/// without `keepReadPairs`, and the errors of a missing and of a corrupt file are the ones the route throws.
final class TaxonomyExtractionGzipPinTests: XCTestCase {

    // MARK: - Fixtures

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("extraction-gzip-pin-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The reads of the small source FASTQ. `pairA` has both mates listed for tax ID 562, `pairB` only its first
    /// mate, so `keepReadPairs` decides whether `pairB/2` comes out.
    private static let smallReads = ["pairA/1", "pairA/2", "solo1", "other1", "unc1", "pairB/1", "pairB/2", "solo2"]

    /// A Kraken2 per-read output without a final newline, as the tests of the pipeline write it.
    private static let smallClassification = [
        "C\tpairA/1\t562\t150\t562:116",
        "C\tpairA/2\t562\t150\t562:116",
        "C\tsolo1\t562\t150\t562:116",
        "C\tother1\t1280\t150\t1280:116",
        "U\tunc1\t0\t150\t0:116",
        "C\tpairB/1\t562\t150\t562:116",
        "C\tsolo2\t562\t150\t562:116",
    ].joined(separator: "\n")

    private static let smallExpected: [Bool: [String]] = [
        false: ["pairA/1", "pairA/2", "solo1", "pairB/1", "solo2"],
        true: ["pairA/1", "pairA/2", "solo1", "pairB/1", "pairB/2", "solo2"],
    ]

    private static let bigCount = 40_000

    private static func bigName(_ index: Int) -> String {
        "big" + String(format: "%05d", index)
    }

    /// 40,000 lines of about 85 bytes with a pseudo-random last column, so the decoded text is over 3 MB
    /// (several 1 MB chunks, lines that cross a chunk edge) and the gzip file is over 1 MB (several reads of it).
    /// Every third read is tax ID 562.
    private static func bigClassification() -> String {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var text = ""
        text.reserveCapacity(bigCount * 90)
        for index in 0..<bigCount {
            text += "C\t\(bigName(index))\t\(index % 3 == 0 ? 562 : 1280)\t150\t"
            for _ in 0..<4 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += String(state, radix: 16)
            }
            text += "\n"
        }
        return text
    }

    private func makeTree() -> TaxonTree {
        let root = TaxonNode(taxId: 1, name: "root", rank: .root, depth: 0,
                             readsDirect: 0, readsClade: 100,
                             fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil)
        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 100)
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeFASTQ(_ names: [String], to url: URL) throws {
        var text = ""
        text.reserveCapacity(names.count * 48)
        for name in names {
            text += "@\(name)\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One gzip member of `data`, made by the system gzip.
    private func gzipped(_ data: Data, named name: String) throws -> Data {
        let input = try write(data, named: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip of \(name)")
        return compressed
    }

    private func recordNames(of url: URL) throws -> [String] {
        var names: [String] = []
        var lineNumber = 0
        try url.forEachLineAutoDecompressing { line in
            if lineNumber % 4 == 0 { names.append(String(line.dropFirst())) }
            lineNumber += 1
        }
        return names
    }

    private struct Extracted {
        let names: [String]
        let readCount: Int
        let taxIds: Set<Int>
        let progress: [(fraction: Double, message: String)]
    }

    /// Runs the route for tax ID 562 over `classification` and reads back the extracted record names.
    private func extract(
        classification: URL,
        reads: [String],
        keepReadPairs: Bool,
        label: String
    ) async throws -> Extracted {
        let directory = tempDir.appendingPathComponent("run-\(label)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.fastq")
        try writeFASTQ(reads, to: source)
        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: source,
            outputFile: directory.appendingPathComponent("extracted.fastq"),
            classificationOutput: classification,
            keepReadPairs: keepReadPairs
        )
        let log = OSAllocatedUnfairLock(initialState: [(fraction: Double, message: String)]())
        let extraction = try await TaxonomyExtractionPipeline().extractEachSource(
            config: config,
            tree: makeTree(),
            progress: { fraction, message in log.withLock { $0.append((fraction: fraction, message: message)) } }
        )
        let output = try XCTUnwrap(extraction.outputs.first ?? nil, "an output for \(label)")
        return Extracted(
            names: try recordNames(of: output),
            readCount: extraction.readCount,
            taxIds: extraction.taxIds,
            progress: log.withLock { $0 }
        )
    }

    private func assertClassificationOutputNotFound(
        _ classification: URL,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await extract(classification: classification, reads: Self.smallReads, keepReadPairs: true, label: label)
            XCTFail("Expected classificationOutputNotFound for \(classification.lastPathComponent)", file: file, line: line)
        } catch let error as TaxonomyExtractionError {
            guard case .classificationOutputNotFound(let url) = error else {
                XCTFail("Expected classificationOutputNotFound for \(classification.lastPathComponent), got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(url, classification, file: file, line: line)
        }
    }

    // MARK: - The read-ID set of a gzipped output

    func testGzippedClassificationOutputGivesTheReadsOfThePlainFile() async throws {
        let text = Data(Self.smallClassification.utf8)
        let plain = try write(text, named: "small.kraken")
        let compressed = try gzipped(text, named: "small-source.kraken")
        let gz = try write(compressed, named: "small.kraken.gz")
        let gzip = try write(compressed, named: "small.kraken.gzip")

        for keepReadPairs in [false, true] {
            let expected = try XCTUnwrap(Self.smallExpected[keepReadPairs])
            let fromPlain = try await extract(classification: plain, reads: Self.smallReads, keepReadPairs: keepReadPairs, label: "small-plain-\(keepReadPairs)")
            XCTAssertEqual(fromPlain.names, expected, "plain, keepReadPairs \(keepReadPairs)")
            XCTAssertEqual(fromPlain.readCount, expected.count)
            XCTAssertEqual(fromPlain.taxIds, [562])

            for (suffix, url) in [("gz", gz), ("gzip", gzip)] {
                let fromGzip = try await extract(classification: url, reads: Self.smallReads, keepReadPairs: keepReadPairs, label: "small-\(suffix)-\(keepReadPairs)")
                XCTAssertEqual(fromGzip.names, fromPlain.names, ".\(suffix), keepReadPairs \(keepReadPairs)")
                XCTAssertEqual(fromGzip.readCount, fromPlain.readCount)
                XCTAssertEqual(fromGzip.taxIds, fromPlain.taxIds)
            }
        }
    }

    func testGzippedClassificationOutputOfSeveralChunksGivesTheReadsOfThePlainFile() async throws {
        let text = Data(Self.bigClassification().utf8)
        XCTAssertGreaterThan(text.count, 3 * 1_048_576, "the fixture spans several 1 MB chunks")
        let plain = try write(text, named: "big.kraken")
        let gz = try write(try gzipped(text, named: "big-source.kraken"), named: "big.kraken.gz")
        XCTAssertGreaterThan(gz.fileSizeBytes, 1_048_576, "the gzip file needs several reads of it")

        let reads = (0..<Self.bigCount).map(Self.bigName)
        let expected = (0..<Self.bigCount).filter { $0 % 3 == 0 }.map(Self.bigName)

        let fromPlain = try await extract(classification: plain, reads: reads, keepReadPairs: false, label: "big-plain")
        XCTAssertEqual(fromPlain.names, expected)
        let fromGzip = try await extract(classification: gz, reads: reads, keepReadPairs: false, label: "big-gz")
        XCTAssertEqual(fromGzip.names, expected)
        XCTAssertEqual(fromGzip.readCount, fromPlain.readCount)

        // Both report their scan between 0.10 and 0.30 and end it on the full count.
        for (label, run) in [("plain", fromPlain), ("gz", fromGzip)] {
            let scans = run.progress.filter { $0.message.hasPrefix("Scanning classification:") }
            XCTAssertFalse(scans.isEmpty, "\(label) reports its scan")
            for scan in scans {
                XCTAssertGreaterThanOrEqual(scan.fraction, 0.10, label)
                XCTAssertLessThanOrEqual(scan.fraction, 0.30, label)
            }
            XCTAssertEqual(scans.last?.message, "Scanning classification: \(expected.count) matches...", label)
        }
    }

    func testMultiMemberGzipGivesTheReadsOfThePlainFile() async throws {
        let text = Data(Self.smallClassification.utf8)
        // Members of 25 bytes cut lines in the middle, with an empty member between two of them.
        var compressed = Data()
        var members = 0
        for start in stride(from: 0, to: text.count, by: 25) {
            let member = Data(text[start..<min(start + 25, text.count)])
            compressed.append(try gzipped(member, named: "member-\(members)"))
            members += 1
            if members == 3 {
                compressed.append(try gzipped(Data(), named: "member-empty"))
                members += 1
            }
        }
        XCTAssertGreaterThan(members, 5)
        let plain = try write(text, named: "multi.kraken")
        let gz = try write(compressed, named: "multi.kraken.gz")

        for keepReadPairs in [false, true] {
            let expected = try XCTUnwrap(Self.smallExpected[keepReadPairs])
            let fromPlain = try await extract(classification: plain, reads: Self.smallReads, keepReadPairs: keepReadPairs, label: "multi-plain-\(keepReadPairs)")
            let fromGzip = try await extract(classification: gz, reads: Self.smallReads, keepReadPairs: keepReadPairs, label: "multi-gz-\(keepReadPairs)")
            XCTAssertEqual(fromPlain.names, expected)
            XCTAssertEqual(fromGzip.names, expected, "keepReadPairs \(keepReadPairs)")
        }
    }

    // MARK: - Errors

    func testMissingClassificationOutputEndsInClassificationOutputNotFound() async throws {
        try await assertClassificationOutputNotFound(tempDir.appendingPathComponent("absent.kraken"), label: "missing-plain")
        try await assertClassificationOutputNotFound(tempDir.appendingPathComponent("absent.kraken.gz"), label: "missing-gz")
    }

    func testCorruptGzipClassificationOutputEndsInClassificationOutputNotFound() async throws {
        let text = Data(Self.smallClassification.utf8)
        let good = try gzipped(text, named: "corrupt-source.kraken")
        XCTAssertGreaterThan(good.count, 40)
        var crcFlipped = good
        crcFlipped[crcFlipped.count - 8] ^= 0xFF
        var lengthFlipped = good
        lengthFlipped[lengthFlipped.count - 1] ^= 0xFF
        // The system gzip exits 1 for the first seven and 2 (a warning) for the last two. The route threw for every
        // nonzero exit status.
        let variants: [(String, Data)] = [
            ("not-gzip", text),
            ("truncated", good.prefix(good.count - 20)),
            ("truncated-no-trailer", good.prefix(good.count - 8)),
            ("header-only", good.prefix(10)),
            ("empty-file", Data()),
            ("crc-flipped", crcFlipped),
            ("length-flipped", lengthFlipped),
            ("trailing-garbage", good + Data("garbage!".utf8)),
            ("trailing-zeros", good + Data(count: 16)),
        ]
        for (label, bytes) in variants {
            let url = try write(bytes, named: "\(label).kraken.gz")
            try await assertClassificationOutputNotFound(url, label: "corrupt-\(label)")
        }
    }

    func testCancelledTaskReadingGzippedClassificationOutputEndsInCancellationError() async throws {
        let gz = try write(try gzipped(Data(Self.smallClassification.utf8), named: "cancel-source.kraken"), named: "cancel.kraken.gz")
        let directory = tempDir.appendingPathComponent("run-cancelled")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.fastq")
        try writeFASTQ(Self.smallReads, to: source)
        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: source,
            outputFile: directory.appendingPathComponent("extracted.fastq"),
            classificationOutput: gz,
            keepReadPairs: false
        )
        let tree = makeTree()

        // The task is cancelled before the route starts, so the scan of the gzipped output meets the cancellation at
        // its first chunk. The closure captures only `config` and `tree`, since an XCTestCase is not Sendable.
        let task = Task { () async throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await TaxonomyExtractionPipeline().extractEachSource(config: config, tree: tree, progress: nil)
        }
        do {
            try await task.value
            XCTFail("Expected CancellationError, but the route returned")
        } catch is CancellationError {
            // The cancellation is not turned into classificationOutputNotFound.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        // GzipChildStream.close() reaps gzip before it returns, so no gzip child of the file is left.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", gz.path]
        let found = Pipe()
        pgrep.standardOutput = found
        pgrep.standardError = FileHandle.nullDevice
        try pgrep.run()
        let leftover = found.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        XCTAssertEqual(
            pgrep.terminationStatus, 1,
            "no process with \(gz.lastPathComponent) in its command line is left, found: \(String(decoding: leftover, as: UTF8.self))"
        )
    }
}
