// TrimGaloreReportTests.swift - Trim Galore's JSON report read through the portable types, with no tool (CHTC lane K2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The report reader tells a boolean from a floating-point number and from an integer by `NSNumber.objCType`, since
// `CFGetTypeID` and `CFNumberIsFloatType` do not exist on Linux. The Linux tier builds that code, and this test makes it
// read a report there, so the types the record states do not move between the two platforms.

import XCTest
import Foundation
import LungfishPortable

final class TrimGaloreReportTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimGaloreReport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let reportJSON = """
    {
      "read_number": 1,
      "mode": "paired-end",
      "trim_galore_version": "2.3.0",
      "read_processing": {"total_reads": 12, "reads_written": 11},
      "parameters": {
        "length_cutoff": 20,
        "quality_cutoff": 20,
        "some_flag": true,
        "ratio": 0.5,
        "name": "x",
        "list": [1, "a"],
        "nested": {"off": false},
        "nothing": null
      }
    }
    """

    private func assertStorageFailed(
        _ expression: @autoclosure () throws -> Void, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? PortableStorageError, .storageFailed(message), file: file, line: line)
        }
    }

    func testTrimGaloreReportReadsCountsAndTypedParameters() throws {
        let root = try makeRoot()
        try reportJSON.write(
            to: root.appendingPathComponent("x_R1_trimming_report.json"), atomically: true, encoding: .utf8
        )

        let report = try TrimGaloreReport.read(in: root)

        XCTAssertTrue(report.paired)
        XCTAssertEqual(report.version, "2.3.0")
        XCTAssertEqual(report.totalReads, 12)
        XCTAssertEqual(report.readsWritten, 11)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.recordsRead, 24)
        XCTAssertEqual(report.recordsWritten, 22)
        XCTAssertEqual(report.lengthCutoff, 20)
        XCTAssertEqual(report.qualityCutoff, 20)
        XCTAssertEqual(report.parameters["length_cutoff"], .integer(20))
        XCTAssertEqual(report.parameters["some_flag"], .boolean(true))
        XCTAssertEqual(report.parameters["ratio"], .number(0.5))
        XCTAssertEqual(report.parameters["name"], .string("x"))
        XCTAssertEqual(report.parameters["list"], .array([.integer(1), .string("a")]))
        XCTAssertEqual(report.parameters["nested"], .dictionary(["off": .boolean(false)]))
        XCTAssertEqual(report.parameters["nothing"], .null)
        XCTAssertEqual(
            report.removalStatement,
            "Trim Galore 2.3.0 adapter- and quality-trims every read (quality cutoff 20) and removes each read that "
                + "trimming leaves shorter than the length cutoff of 20 bases, a pair as a unit in paired mode. "
                + "No Trim Galore 2.3.0 option set turns this off. This call removed 1 of 12 pairs."
        )

        try report.verifyAccounting(scanned: 24, counted: 22)
        assertStorageFailed(
            try report.verifyAccounting(scanned: 24, counted: 21),
            "trim_galore reports 22 reads written but its output holds 21; originals were kept"
        )
        assertStorageFailed(
            try report.verifyAccounting(scanned: 26, counted: 22),
            "trim_galore reports 24 reads read but its input holds 26; originals were kept"
        )

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        assertStorageFailed(_ = try TrimGaloreReport.read(in: empty), TrimGaloreReport.unreadable)
    }
}
