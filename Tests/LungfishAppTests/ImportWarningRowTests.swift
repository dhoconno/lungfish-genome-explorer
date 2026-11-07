// ImportWarningRowTests.swift - What the row of a FASTQ import says when its run logged a warning
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane OPSWORDS, row IMPORT-WARN-SUBTITLE (walk W-29). An import whose merge dropped pairs, or whose reads had
// no mate, ended Completed with Warnings and only the Log said why. Each test logs on a row as the import runner does
// (a line at the level the command gave it), ends the row as the run does, and reads the row the panel draws. The
// two causes are the lines the walk read in the Log of an Illumina Amplicon Merge import and of an SRA pair import.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit

@MainActor
final class ImportWarningRowTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/tmp/import-warning-row/S2_S2_L001.lungfishfastq", isDirectory: true)
    private let merge = "S2_S2_L001 \u{2014} Illumina Amplicon Merge kept 500 merged reads and dropped 1,500 pairs that did not merge."
    private let mates = "SRR123 \u{2014} SRR123.fastq.gz holds 500 reads whose mate is missing. They import as unpaired reads beside the 10000 pairs."

    /// The row of an import that logged `lines`, ended the way the run ends it.
    private func finishedImport(logging lines: [(OperationLogLevel, String)]) throws -> OperationCenter.Item {
        let center = OperationCenter()
        let id = center.begin(
            title: "FASTQ Import: S2_S2_L001", detail: "Importing", operationType: .ingestion,
            cliCommand: "lungfish-cli import fastq"
        ).rowID
        for (level, message) in lines { center.log(id: id, level: level, message: message) }
        XCTAssertTrue(FASTQIngestionService.completeImportRow(id, bundleURL: bundle, center: center))
        return try XCTUnwrap(center.items.first { $0.id == id })
    }

    /// The row reads Completed with Warnings, and its detail line, the subtitle under the title, leads with the Log's cause
    /// and its counts. The line is one label that cuts at the edge (88 characters at the width of the walk's panel), so the
    /// count of dropped pairs must end inside the first 88 characters. Red at the picked tree, where `Imported X with a
    /// warning.` leads and the count ends 126 characters in (76 once the cause leads).
    func testImportWithDroppedPairsNamesTheWarningInItsRow() throws {
        let item = try finishedImport(logging: [
            (.info, "Platform: Unknown"), (.warning, merge), (.info, "Statistics computed"),
        ])

        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        let count = try XCTUnwrap(item.detail.range(of: "1,500"), item.detail)
        XCTAssertLessThan(
            item.detail.distance(from: item.detail.startIndex, to: count.upperBound), 88,
            "the count is in view: \(item.detail)"
        )
    }

    /// Several causes read as one line, the first named and the rest counted, and a cause the Log repeats counts once.
    /// Red at the base.
    func testSeveralWarningsNameTheFirstAndCountTheRest() throws {
        let item = try finishedImport(logging: [(.warning, merge), (.warning, mates), (.warning, merge)])

        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertTrue(item.detail.hasPrefix("2 warnings. "), item.detail)
        XCTAssertTrue(item.detail.contains("dropped 1,500 pairs that did not merge"), item.detail)
        XCTAssertFalse(item.detail.contains("whose mate is missing"), "only the first cause is named: \(item.detail)")
        XCTAssertTrue(item.detail.hasSuffix("The Log names the other warning."), item.detail)
    }

    /// Pin, green at the base and after. An import that logged no warning keeps its words and its label.
    func testACleanImportKeepsItsWords() throws {
        let item = try finishedImport(logging: [(.info, "Platform: Illumina"), (.info, "Statistics computed")])

        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertEqual(item.detail, "Imported S2_S2_L001.lungfishfastq")
    }
}
