// ViewerPaneCapturePinTests.swift - Pins what the kept capture of a document draws
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.30 (GFX-2), QA condition 1 of the V1 vote. A document that is not a bundle keeps its
// Tracks and Selected Region captures (O18, V1-3). Before the scope list changes, this pin holds
// the view and the rect each capture draws, and that a capture begins no Operations row. It
// asserts no image bytes.

import AppKit
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp

@MainActor
final class ViewerPaneCapturePinTests: XCTestCase {
    func testADocumentCaptureDrawsTheViewerViewAndItsSelectionAndBeginsNoRow() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        defer { controller.close() }
        let viewer = try XCTUnwrap(controller.mainSplitViewController?.viewerController)
        let document = LoadedDocument(url: URL(fileURLWithPath: "/tmp/invented-capture.fa"), type: .fasta)
        document.sequences = [try Sequence(name: "invented", alphabet: .dna, bases: String(repeating: "ACGT", count: 250))]
        let rowsBefore = OperationCenter.shared.items.count
        viewer.displayDocument(document)

        let (tracksView, tracksRect) = try delegate.viewerExportViewAndRect(viewerController: viewer, scope: .tracks)
        XCTAssertTrue(tracksView === viewer.viewerView)
        XCTAssertEqual(tracksRect, viewer.viewerView.bounds)

        viewer.viewerView.selectionRange = nil
        XCTAssertThrowsError(try delegate.viewerExportViewAndRect(viewerController: viewer, scope: .selectedRegion)) {
            XCTAssertEqual($0.localizedDescription, "No selected region is available for export.")
        }

        let frame = try XCTUnwrap(viewer.referenceFrame)
        viewer.viewerView.selectionRange = 100..<300
        let (selectionView, selectionRect) = try delegate.viewerExportViewAndRect(
            viewerController: viewer, scope: .selectedRegion
        )
        XCTAssertTrue(selectionView === viewer.viewerView)
        let bounds = viewer.viewerView.bounds
        let startX = frame.screenPosition(for: 100)
        let endX = frame.screenPosition(for: 300)
        let minX = max(frame.leadingInset, min(startX, endX))
        let maxX = min(max(frame.leadingInset, bounds.width - frame.trailingInset), max(startX, endX))
        XCTAssertEqual(selectionRect, NSRect(x: minX, y: 0, width: max(1, maxX - minX), height: bounds.height))
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore)
    }
}
