// SequenceExportSelectionTests.swift - Tests for the Export Sequences skipped-items partition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E2 (2026-08-08 repo review fix campaign, finding AS1): File > Export
// > Sequences used to silently filter a mixed sidebar selection down to
// .referenceBundle/.sequence items with no indication of what was dropped.
// These tests pin down SequenceExportSelection.partition, the pure helper
// that replaced the silent inline filter so the caller can report exactly
// what was skipped.

import XCTest
@testable import LungfishApp

@MainActor
final class SequenceExportSelectionTests: XCTestCase {

    private func makeItem(type: SidebarItemType, title: String) -> SidebarItem {
        SidebarItem(title: title, type: type, url: URL(fileURLWithPath: "/tmp/\(title)"))
    }

    func testPartitionKeepsReferenceBundlesAndSequencesAsExportable() {
        let refBundle = makeItem(type: .referenceBundle, title: "ref1")
        let sequence = makeItem(type: .sequence, title: "seq1")

        let selection = SequenceExportSelection.partition([refBundle, sequence])

        XCTAssertEqual(selection.exportable.map(\.title), ["ref1", "seq1"])
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionSkipsNonExportableKindsAndReportsThem() {
        let refBundle = makeItem(type: .referenceBundle, title: "ref1")
        let fastqBundle = makeItem(type: .fastqBundle, title: "sample1")
        let msaBundle = makeItem(type: .multipleSequenceAlignmentBundle, title: "align1")
        let classificationResult = makeItem(type: .classificationResult, title: "kraken-run1")

        let selection = SequenceExportSelection.partition([refBundle, fastqBundle, msaBundle, classificationResult])

        XCTAssertEqual(selection.exportable.map(\.title), ["ref1"])
        XCTAssertEqual(Set(selection.skipped.map(\.title)), ["sample1", "align1", "kraken-run1"])
        XCTAssertEqual(Set(selection.skippedDescriptions), ["sample1", "align1", "kraken-run1"])
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionReportsNoExportableItemsWhenSelectionIsEntirelyNonSequence() {
        let fastqBundle = makeItem(type: .fastqBundle, title: "sample1")
        let folder = makeItem(type: .folder, title: "FASTQ")

        let selection = SequenceExportSelection.partition([fastqBundle, folder])

        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertFalse(selection.hasExportableItems)
        XCTAssertEqual(Set(selection.skippedDescriptions), ["sample1", "FASTQ"])
    }

    func testMHCReferenceBundleIsNotExportableYet() {
        // See SidebarItem.bundleCapabilities: the export pipeline's
        // loadSequencesForExport only reads .lungfishref's manifest shape,
        // not MHCAmpliconReferenceBundleManifest, so MHC bundles are
        // correctly reported as skipped rather than silently mishandled.
        let mhcBundle = makeItem(type: .mhcReferenceBundle, title: "MCM")

        let selection = SequenceExportSelection.partition([mhcBundle])

        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertEqual(selection.skipped.map(\.title), ["MCM"])
    }

    func testPartitionOfEmptySelectionIsEmpty() {
        let selection = SequenceExportSelection.partition([])
        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertFalse(selection.hasExportableItems)
    }
}
