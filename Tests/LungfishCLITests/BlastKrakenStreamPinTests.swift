// BlastKrakenStreamPinTests.swift - Pins of the gzip -dc reader behind `blast verify`, from before Phase 2.13 lane 13.07
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import XCTest
@testable import LungfishCLI

/// `blastScanKrakenOutput` reads a plain Kraken 2 output file through a file handle and a gzip one through
/// `gzip -dc`. These pins hold the read IDs both hand over across the reader's chunk boundaries and the end
/// of a final line without a newline, and the failure words, and they pass unchanged before and after the
/// gzip stream moves onto `ToolProcess`.
final class BlastKrakenStreamPinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastKrakenStreamPinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static let lineCount = 120_000

    /// A Kraken 2 output of `lineCount` lines and one more without a newline, with the read IDs a scan for
    /// taxon 562 must return.
    private static func krakenOutput() -> (text: Data, expected: Set<String>) {
        var text = String()
        var expected = Set<String>()
        text.reserveCapacity(lineCount * 36)
        for index in 0..<lineCount {
            switch index % 4 {
            case 0:
                text += "C\tread-\(index)/1\t562\t150\t562:150\n"
                expected.insert("read-\(index)")
            case 1:
                text += "U\tread-\(index)\t0\t150\t0:150\n"
            case 2:
                text += "C\tread-\(index)/2\t562\t150\t562:150\n"
                expected.insert("read-\(index)")
            default:
                text += "C\tread-\(index)\t12345\t150\t12345:150\n"
            }
        }
        text += "C\tread-last\t562\t150\t562:150"
        expected.insert("read-last")
        return (Data(text.utf8), expected)
    }

    private func gzipped(_ data: Data) throws -> Data {
        let result = try ToolProcess.runBlocking(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-c"],
            environment: ["PATH": "/usr/bin:/bin"],
            stdin: .data(data),
            label: "gzip"
        ))
        XCTAssertTrue(result.isSuccess, result.stderrText)
        return result.stdout
    }

    func testPlainAndGzipKrakenOutputHandOverTheSameReadIDs() throws {
        let (text, expected) = Self.krakenOutput()
        XCTAssertGreaterThan(text.count, 3 * 1_048_576, "more than three of the reader's megabyte chunks")
        let plain = scratch.appendingPathComponent("classification.kraken")
        let compressed = scratch.appendingPathComponent("classification.kraken.gz")
        try text.write(to: plain)
        try gzipped(text).write(to: compressed)

        XCTAssertEqual(try blastScanKrakenOutput(url: plain, targetTaxIds: [562]), expected)
        XCTAssertEqual(try blastScanKrakenOutput(url: compressed, targetTaxIds: [562]), expected)
        XCTAssertEqual(try blastScanKrakenOutput(url: plain, targetTaxIds: [12345]).count, Self.lineCount / 4)
        XCTAssertEqual(try blastScanKrakenOutput(url: compressed, targetTaxIds: [12345]).count, Self.lineCount / 4)
        XCTAssertEqual(try blastScanKrakenOutput(url: compressed, targetTaxIds: [7]), [])
    }

    func testFailureWordsOfACorruptGzipAMissingGzipAndAMissingPlainFile() throws {
        let bad = scratch.appendingPathComponent("bad.kraken.gz")
        try Data(String(repeating: "this is not gzip data\n", count: 20).utf8).write(to: bad)
        XCTAssertThrowsError(try blastScanKrakenOutput(url: bad, targetTaxIds: [562])) { error in
            guard case CLIError.conversionFailed(let reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(reason, "Failed to decompress Kraken output: gzip: \(bad.path): not in gzip format\n")
        }

        let missingGzip = scratch.appendingPathComponent("missing.kraken.gz")
        XCTAssertThrowsError(try blastScanKrakenOutput(url: missingGzip, targetTaxIds: [562])) { error in
            guard case CLIError.conversionFailed(let reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("Failed to decompress Kraken output: gzip: "), reason)
            XCTAssertTrue(reason.contains("No such file or directory"), reason)
        }

        let missingPlain = scratch.appendingPathComponent("missing.kraken")
        XCTAssertThrowsError(try blastScanKrakenOutput(url: missingPlain, targetTaxIds: [562])) { error in
            guard case CLIError.inputFileNotFound(let path) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, missingPlain.path)
        }
    }
}
