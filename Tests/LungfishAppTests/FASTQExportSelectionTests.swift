// FASTQExportSelectionTests.swift - Tests for the Export FASTQ skipped-items partition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS15): File >
// Export > FASTQ used to silently filter a mixed sidebar selection down to
// .fastqBundle items with a bare `.filter`, reporting success as if the
// whole selection had been exported. SidebarExportSelection supplies the
// same ordered partition contract for FASTQ and sequence exports so the
// caller can report exactly what was skipped.

import XCTest
@testable import LungfishApp

@MainActor
final class FASTQExportSelectionTests: XCTestCase {

    private func makeItem(type: SidebarItemType, title: String, hasURL: Bool = true) -> SidebarItem {
        SidebarItem(title: title, type: type, url: hasURL ? URL(fileURLWithPath: "/tmp/\(title)") : nil)
    }

    func testPartitionKeepsFASTQBundlesWithURLsAsExportable() {
        let fastq1 = makeItem(type: .fastqBundle, title: "sample1")
        let fastq2 = makeItem(type: .fastqBundle, title: "sample2")

        let selection = SidebarExportSelection([fastq1, fastq2], format: .fastq)

        XCTAssertEqual(selection.exportable.map(\.title), ["sample1", "sample2"])
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionSkipsNonFASTQKindsAndReportsThem() {
        let fastqBundle = makeItem(type: .fastqBundle, title: "sample1")
        let refBundle = makeItem(type: .referenceBundle, title: "ref1")
        let classificationResult = makeItem(type: .classificationResult, title: "kraken-run1")

        let selection = SidebarExportSelection([fastqBundle, refBundle, classificationResult], format: .fastq)

        XCTAssertEqual(selection.exportable.map(\.title), ["sample1"])
        XCTAssertEqual(Set(selection.skipped.map(\.title)), ["ref1", "kraken-run1"])
        XCTAssertEqual(Set(selection.skippedDescriptions), ["ref1", "kraken-run1"])
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionSkipsFASTQBundleMissingURL() {
        let fastqNoURL = makeItem(type: .fastqBundle, title: "orphan", hasURL: false)

        let selection = SidebarExportSelection([fastqNoURL], format: .fastq)

        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertEqual(selection.skipped.map(\.title), ["orphan"])
        XCTAssertFalse(selection.hasExportableItems)
    }

    func testPartitionOfEmptySelectionIsEmpty() {
        let selection = SidebarExportSelection([], format: .fastq)
        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertFalse(selection.hasExportableItems)
    }
}
