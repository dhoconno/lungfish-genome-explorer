// SequenceExportSelectionTests.swift - Tests for the Export Sequences skipped-items partition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E2 (2026-08-08 repo review fix campaign, finding AS1): File > Export
// > Sequences used to silently filter a mixed sidebar selection down to
// .referenceBundle/.sequence items with no indication of what was dropped.
// These tests exercise SidebarExportSelection, the shared helper
// that replaced the silent inline filter so the caller can report exactly
// what was skipped.

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class SequenceExportSelectionTests: XCTestCase {

    private func makeItem(type: SidebarItemType, title: String) -> SidebarItem {
        SidebarItem(title: title, type: type, url: URL(fileURLWithPath: "/tmp/\(title)"))
    }

    func testSelectedAnnotatedGenBankRemainsEligibleWithoutBorrowingAnotherDocument() throws {
        let selected = makeItem(type: .sequence, title: "annotated.gb")
        let other = makeItem(type: .sequence, title: "unrelated.fa")
        let scope = SidebarExportSelection.annotations([selected, other],
            loadedDocumentURL: try XCTUnwrap(selected.url), hasLoadedAnnotations: true)
        XCTAssertEqual(scope.exportable.map(\.title), [selected.title])
        XCTAssertEqual(scope.skippedDescriptions, [other.title])
        XCTAssertFalse(SidebarExportSelection.annotations([other],
            loadedDocumentURL: selected.url, hasLoadedAnnotations: true).hasExportableItems)
        XCTAssertFalse(SidebarExportSelection.annotations([selected],
            loadedDocumentURL: selected.url, hasLoadedAnnotations: false).hasExportableItems)
    }

    func testSameNamedAnnotationSourcesHaveDistinctVisiblePaths() {
        let first = AnnotationExportSourceChoice(source: .init(kind: .sidebarBundle,
            urls: [URL(fileURLWithPath: "/tmp/first/Sample.lungfishref")], name: "Sample"), annotations: nil)
        let second = AnnotationExportSourceChoice(source: .init(kind: .sidebarBundle,
            urls: [URL(fileURLWithPath: "/tmp/second/Sample.lungfishref")], name: "Sample"), annotations: nil)
        XCTAssertNotEqual(first.displayTitle, second.displayTitle)
        XCTAssertTrue(first.displayTitle.contains("/tmp/first/Sample.lungfishref"))
        XCTAssertTrue(second.displayTitle.contains("/tmp/second/Sample.lungfishref"))
    }

    func testAnnotationScopeDoesNotBorrowSamePathDocumentWithDifferentIdentity() {
        let native = makeItem(type: .sequence, title: "shared-path")
        let external = makeItem(type: .sequence, title: "shared-path")
        let nativeID = UUID()
        let externalID = UUID()
        native.userInfo["documentID"] = nativeID.uuidString
        external.userInfo["documentID"] = externalID.uuidString
        let scope = SidebarExportSelection.annotations([native, external],
            loadedDocumentURL: external.url, loadedDocumentID: externalID, hasLoadedAnnotations: true)
        XCTAssertEqual(scope.exportable.count, 1)
        XCTAssertTrue(scope.exportable.first === external)
        XCTAssertTrue(scope.skipped.first === native)
    }

    func testFilesystemRowCannotBorrowAnnotationsFromNativeSyntheticPath() {
        let filesystem = makeItem(type: .sequence, title: "shared-path")
        let scope = SidebarExportSelection.annotations([filesystem], loadedDocumentURL: filesystem.url,
            loadedDocumentID: UUID(), loadedNativeSequenceID: UUID(), hasLoadedAnnotations: true)
        XCTAssertFalse(scope.hasExportableItems)
        XCTAssertEqual(scope.skipped.count, 1)
    }

    func testAnnotationMenuRejectsAnOpenDocumentWithNoAnnotations() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        defer { controller.close() }
        let viewer = try XCTUnwrap(controller.mainSplitViewController?.viewerController)
        viewer.displayDocument(LoadedDocument(url: URL(fileURLWithPath: "/tmp/invented.fa"), type: .fasta))
        XCTAssertNotNil(viewer.currentDocument)
        XCTAssertFalse(delegate.canExportGFF3())
    }

    func testAnnotationScopePreservesAllSelectedSourcesAndReportsUnsupportedItems() {
        let first = makeItem(type: .referenceBundle, title: "first reference")
        let second = makeItem(type: .referenceBundle, title: "second reference")
        let unsupported = makeItem(type: .fastqBundle, title: "reads")
        let scope = SidebarExportSelection.annotations([first, unsupported, second])
        XCTAssertEqual(scope.exportable.map(\.title), [first.title, second.title])
        XCTAssertEqual(scope.skippedDescriptions, [unsupported.title])
    }

    func testPartitionKeepsReferenceBundlesAndSequencesAsExportable() {
        let refBundle = makeItem(type: .referenceBundle, title: "ref1")
        let sequence = makeItem(type: .sequence, title: "seq1")

        let selection = SidebarExportSelection([refBundle, sequence], format: .sequences)

        XCTAssertEqual(selection.exportable.map(\.title), ["ref1", "seq1"])
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionSkipsNonExportableKindsAndReportsThem() {
        let refBundle = makeItem(type: .referenceBundle, title: "ref1")
        let fastqBundle = makeItem(type: .fastqBundle, title: "sample1")
        let msaBundle = makeItem(type: .multipleSequenceAlignmentBundle, title: "align1")
        let classificationResult = makeItem(type: .classificationResult, title: "kraken-run1")

        let selection = SidebarExportSelection([refBundle, fastqBundle, msaBundle, classificationResult], format: .sequences)

        XCTAssertEqual(selection.exportable.map(\.title), ["ref1"])
        XCTAssertEqual(Set(selection.skipped.map(\.title)), ["sample1", "align1", "kraken-run1"])
        XCTAssertEqual(Set(selection.skippedDescriptions), ["sample1", "align1", "kraken-run1"])
        XCTAssertTrue(selection.hasExportableItems)
    }

    func testPartitionReportsNoExportableItemsWhenSelectionIsEntirelyNonSequence() {
        let fastqBundle = makeItem(type: .fastqBundle, title: "sample1")
        let folder = makeItem(type: .folder, title: "FASTQ")

        let selection = SidebarExportSelection([fastqBundle, folder], format: .sequences)

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

        let selection = SidebarExportSelection([mhcBundle], format: .sequences)

        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertEqual(selection.skipped.map(\.title), ["MCM"])
    }

    func testPartitionOfEmptySelectionIsEmpty() {
        let selection = SidebarExportSelection([], format: .sequences)
        XCTAssertTrue(selection.exportable.isEmpty)
        XCTAssertTrue(selection.skipped.isEmpty)
        XCTAssertFalse(selection.hasExportableItems)
    }
}
