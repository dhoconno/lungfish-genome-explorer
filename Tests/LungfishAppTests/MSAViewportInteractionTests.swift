// MSAViewportInteractionTests.swift - Native alignment selection and layout regressions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

@MainActor
final class MSAViewportInteractionTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var savedGutterWidth: Any?

    override func setUpWithError() throws {
        savedGutterWidth = UserDefaults.standard.object(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedGutterWidth {
            UserDefaults.standard.set(savedGutterWidth, forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func controller(columns: Int = 6) async throws -> MultipleSequenceAlignmentViewController {
        let source = temporaryDirectory.appendingPathComponent("input.fa")
        let sequences = columns == 6 ? ["ACGT-A", "ACCTTA", "AC-TTA"] : Array(repeating: String(repeating: "A", count: columns), count: 3)
        let fasta = zip(["first", "middle", "last"], sequences).map { ">\($0)\n\($1)\n" }.joined()
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundle = temporaryDirectory.appendingPathComponent("test.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle)
        let controller = MultipleSequenceAlignmentViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        try await controller.displayBundle(at: bundle)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func descendant(_ root: NSView, _ identifier: String) throws -> NSView {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = try? descendant(child, identifier) { return found }
        }
        throw NSError(domain: "Missing view \(identifier)", code: 1)
    }

    private func event(in view: NSView, x: CGFloat, row: Int, modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let point = view.convert(NSPoint(x: x, y: 26 + CGFloat(row) * 24 + 10), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testFitTracksFinalViewportAndResizeWhileManualZoomStaysFixed() async throws {
        let controller = try await controller(columns: 1000)
        controller.view.frame.size.width = 1500
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.testingAlignmentColumnWidth * 1000, controller.testingEffectiveVisibleMatrixWidth - 8, accuracy: 1)
        controller.zoomIn()
        let manualWidth = controller.testingAlignmentColumnWidth
        controller.view.frame.size.width = 1800
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.testingAlignmentColumnWidth, manualWidth, accuracy: 0.001)
        controller.zoomToFit()
        controller.view.frame.size.width = 1200
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.testingAlignmentColumnWidth * 1000, controller.testingEffectiveVisibleMatrixWidth - 8, accuracy: 1)
    }

    func testShortAlignmentDocumentFillsWideViewportWithoutFixedMinimumOverflow() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        XCTAssertEqual(matrix.frame.width, controller.testingEffectiveVisibleMatrixWidth, accuracy: 1)
        controller.view.frame.size.width = 1800
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(matrix.frame.width, controller.testingEffectiveVisibleMatrixWidth, accuracy: 1)
    }

    func testGutterCommandSelectionExportsOnlyExactWholeRows() async throws {
        let controller = try await controller()
        let gutter = try descendant(controller.view, "multiple-sequence-alignment-row-gutter")
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 0))
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 2, modifiers: [.command]))
        XCTAssertEqual(controller.testingSelectedFASTARecords, [">first\nACGTA\n", ">last\nACTTA\n"])
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 0, modifiers: [.command]))
        XCTAssertEqual(controller.testingSelectedRowName, "last")
    }

    func testBlankRowClickAndShiftClickSelectWholeRows() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        matrix.mouseDown(with: try event(in: matrix, x: 250, row: 0))
        matrix.mouseDown(with: try event(in: matrix, x: 250, row: 2, modifiers: [.shift]))
        XCTAssertEqual(controller.testingSelectedFASTARecords.count, 3)
        XCTAssertEqual(controller.testingSelectedFASTARecords.last, ">last\nACTTA\n")
    }

    func testReferenceRowRemainsReadableInDotsMode() async throws {
        let controller = try await controller()
        controller.applyResidueIdentityDisplayMode(.dotsToReference)
        XCTAssertEqual(controller.testingAlignmentMatrixPreview(rowCount: 1, columnCount: 6), ["first ACGT-A"])
    }
    func testAlignmentDoesNotShowGenericAnnotationTabs() async throws {
        let controller = try await controller()
        let drawer = try descendant(controller.view, "annotation-table-drawer")
        XCTAssertTrue(drawer.isHidden || drawer.frame.height == 0)
    }

    func testSelectedCellDoesNotInterceptMatrixDragStart() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        let hit = matrix.hitTest(NSPoint(x: 4, y: 36))
        XCTAssertTrue(hit === matrix)
    }

    private func copyKey() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    }

    func testCopyUsesExactNoncontiguousRowsAndPreservesSelectionOnContextClick() async throws {
        let controller = try await controller()
        let gutter = try descendant(controller.view, "multiple-sequence-alignment-row-gutter")
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        var request: MultipleSequenceAlignmentExportRequest?
        controller.onCopyMSASelectionRequested = { request = $0 }
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 0))
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 2, modifiers: [.command]))
        _ = matrix.menu(for: try event(in: matrix, x: 10, row: 0, type: .rightMouseDown))
        matrix.keyDown(with: try copyKey())
        let rows = try XCTUnwrap(controller.bundle?.rows)
        XCTAssertEqual(request?.rows, [rows[0].id, rows[2].id].joined(separator: ","))
        XCTAssertNil(request?.columns)
        XCTAssertEqual(request?.selectedRowCount, 2)
    }

    func testSingleCellCopyKeepsTheExactColumn() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        var request: MultipleSequenceAlignmentExportRequest?
        controller.onCopyMSASelectionRequested = { request = $0 }
        controller.testingSelect(row: 0, displayedColumn: 4)
        matrix.keyDown(with: try copyKey())
        XCTAssertEqual(request?.columns, "5-5")
        XCTAssertEqual(request?.selectedRowCount, 1)
    }

    func testResidueDragCopiesSelectedColumnsIncludingGaps() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        var request: MultipleSequenceAlignmentExportRequest?
        controller.onCopyMSASelectionRequested = { request = $0 }
        matrix.mouseDown(with: try event(in: matrix, x: 13, row: 0))
        matrix.mouseDragged(with: try event(in: matrix, x: 49, row: 2, type: .leftMouseDragged))
        matrix.mouseUp(with: try event(in: matrix, x: 49, row: 2, type: .leftMouseUp))
        matrix.keyDown(with: try copyKey())
        XCTAssertEqual(request?.columns, "2-5")
        XCTAssertEqual(request?.selectedRowCount, 3)
    }

    func testContextReferenceChangesComparisonAndNotSelectionMembership() async throws {
        let controller = try await controller()
        let gutter = try descendant(controller.view, "multiple-sequence-alignment-row-gutter")
        var changedReference: String?
        controller.onReferenceRowChanged = { changedReference = $0 }
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 0))
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 2, modifiers: [.command]))
        let menu = try XCTUnwrap(gutter.menu(for: try event(in: gutter, x: 70, row: 2, type: .rightMouseDown)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Use as Reference" })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(changedReference, controller.bundle?.rows[2].id)
        XCTAssertEqual(controller.testingSelectedRowName, "2 rows")
        XCTAssertEqual(controller.testingReferenceRowName, "last")
        XCTAssertEqual(controller.testingAlignmentMatrixPreview(rowCount: 3, columnCount: 6).last, "last AC-TTA")
    }

    func testNativeCopyAndSelectAllResponderActionsKeepSelectionScope() async throws {
        let controller = try await controller()
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        var request: MultipleSequenceAlignmentExportRequest?
        controller.onCopyMSASelectionRequested = { request = $0 }
        XCTAssertTrue(matrix.tryToPerform(NSSelectorFromString("selectAll:"), with: nil))
        XCTAssertTrue(matrix.tryToPerform(NSSelectorFromString("copy:"), with: nil))
        XCTAssertEqual(request?.selectedRowCount, 3)
        XCTAssertNil(request?.columns)
    }

    func testExportAlignmentKeepsExactNoncontiguousRowsAndCellRange() async throws {
        let controller = try await controller()
        let gutter = try descendant(controller.view, "multiple-sequence-alignment-row-gutter")
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        var request: MultipleSequenceAlignmentExportRequest?
        controller.onExportAlignmentRequested = { request = $0 }
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 0))
        gutter.mouseDown(with: try event(in: gutter, x: 70, row: 2, modifiers: [.command]))
        let menu = try XCTUnwrap(gutter.menu(for: try event(in: gutter, x: 70, row: 2, type: .rightMouseDown)))
        let export = try XCTUnwrap(menu.items.first { $0.title == "Export Alignment…" })
        let action = try XCTUnwrap(export.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: export.target, from: export))
        let rows = try XCTUnwrap(controller.bundle?.rows)
        XCTAssertEqual(request?.rows, [rows[0].id, rows[2].id].joined(separator: ","))
        XCTAssertNil(request?.columns)
        controller.testingSelectBlock(rowRange: 0...2, displayedColumnRange: 1...4)
        let blockMenu = try XCTUnwrap(matrix.menu(for: try event(in: matrix, x: 13, row: 2, type: .rightMouseDown)))
        let blockExport = try XCTUnwrap(blockMenu.items.first { $0.title == "Export Alignment…" })
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: blockExport.target, from: blockExport))
        XCTAssertEqual(request?.columns, "2-5")
        XCTAssertEqual(request?.selectedRowCount, 3)
    }

    func testAnnotationAccessibilityOverlayDoesNotSwallowModifiedRowClicks() async throws {
        let controller = try await controller()
        try controller.testingAddAnnotationFromSelection(name: "feature", type: "gene")
        let matrix = try descendant(controller.view, "multiple-sequence-alignment-matrix-view")
        XCTAssertTrue(matrix.hitTest(NSPoint(x: 4, y: 44)) === matrix)
        matrix.mouseDown(with: try event(in: matrix, x: 4, row: 2, modifiers: [.command]))
        XCTAssertEqual(controller.testingSelectedRowName, "2 rows")
    }

    func testGutterResizeRefitsAlignmentAndSelectingOneRowNeverInfersAllRows() async throws {
        let controller = try await controller(columns: 1000)
        controller.view.frame.size.width = 1500
        controller.view.layoutSubtreeIfNeeded()
        controller.testingSetGutterWidth(400)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.testingAlignmentColumnWidth * 1000, controller.testingEffectiveVisibleMatrixWidth - 8, accuracy: 1)
        var inferred = false
        controller.onInferTreeRequested = { _ in inferred = true }
        controller.testingInferTreeFromAlignment()
        XCTAssertFalse(inferred)
    }

}
