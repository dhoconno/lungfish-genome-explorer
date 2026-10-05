// MSABottomPaneThirdReviewFixTests.swift - Third review fixes S1 to S4 for the MSA bottom pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishAlignmentUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class MSABottomPaneThirdReviewFixTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "lungfish-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // These tests start from a hidden pane. The default-open behaviour is in MSABottomPaneDefaultOpenTests.
        defaults.set(false, forKey: MSABottomPaneView.DefaultsKey.isOpen)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryDirectory.path)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func controller() async throws -> MultipleSequenceAlignmentViewController {
        let source = temporaryDirectory.appendingPathComponent("third.fa")
        try ">Macaca_mulatta_A1\nACGTACGTAC\n>Macaca_fascicularis_B2\nACGTTCGAAC\n>Homo_sapiens_reference_C3\nACGAACGTTC\n>Macaca_nemestrina_D4\nTCGTACGAAC\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = temporaryDirectory.appendingPathComponent("third.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()
        controller.bottomPane.reduceMotion = { true }
        return controller
    }

    private func host(_ controller: MultipleSequenceAlignmentViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        return window
    }

    private func fittingHeight(_ pane: MSABottomPaneView, rows: Int) throws -> CGFloat {
        let fit = try XCTUnwrap(pane.distancePane.fittingHeight(rows: rows))
        let wanted = AnnotationDrawerSizing.dividerHeight + MSABottomPaneView.headerHeight + fit
        return min(wanted, 700 - MSABottomPaneView.reservedAlignmentHeight)
    }

    // MARK: S1 a matrix that lands mid-animation still grows the pane

    func testAnimatedFirstOpenEndsTallEnoughForTheHeaderAndSixRows() async throws {
        let controller = try await controller()
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        pane.reduceMotion = { false }

        controller.showDistanceMatrix()
        XCTAssertGreaterThan(pane.lastAnimationDuration, 0, "the open animates")
        let settled = await waitUntil(timeout: .seconds(20)) {
            pane.distancePane.model.status == .ready && !pane.isAnimatingOpen
        }
        XCTAssertTrue(settled, "the matrix never became ready or the open never finished")
        let wanted = try fittingHeight(pane, rows: 6)
        XCTAssertGreaterThan(wanted, MSABottomPaneView.defaultHeight, "the fixture needs more than the default height")
        let grown = await waitUntil(timeout: .seconds(10)) {
            abs(pane.heightConstraint.constant - wanted) < 0.5
        }
        XCTAssertTrue(grown, "the pane ended at \(pane.heightConstraint.constant), wanted \(wanted)")
    }

    /// The same race made deterministic: the Distances grow is asked for
    /// while the open animation is still running toward the default height.
    func testAGrowAskedForMidAnimationLandsAfterTheAnimation() async throws {
        let controller = try await controller()
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        controller.showDistanceMatrix()
        let ready = await waitUntil(timeout: .seconds(20)) { pane.distancePane.model.status == .ready }
        XCTAssertTrue(ready)
        pane.select(.annotations)
        pane.setOpen(false, animated: false)

        pane.reduceMotion = { false }
        pane.setOpen(true)
        XCTAssertGreaterThan(pane.lastAnimationDuration, 0, "the open animates")
        XCTAssertTrue(pane.isAnimatingOpen)
        pane.select(.distances)
        XCTAssertTrue(pane.isDistancesGrowPending, "the grow waits for the animation to land")

        let wanted = try fittingHeight(pane, rows: 6)
        XCTAssertGreaterThan(wanted, MSABottomPaneView.defaultHeight)
        let grown = await waitUntil(timeout: .seconds(10)) {
            !pane.isAnimatingOpen && abs(pane.heightConstraint.constant - wanted) < 0.5
        }
        XCTAssertTrue(grown, "the pane ended at \(pane.heightConstraint.constant), wanted \(wanted)")
    }

    // MARK: S2 a recompute keeps the height the user dragged

    func testARecomputeAfterADragKeepsTheDraggedHeight() async throws {
        let controller = try await controller()
        controller.showDistanceMatrix()
        let pane = controller.bottomPane
        let model = pane.distancePane.model
        let ready = await waitUntil(timeout: .seconds(20)) { model.status == .ready }
        XCTAssertTrue(ready)

        pane.resize(by: -1000)
        let dragged = pane.heightConstraint.constant
        XCTAssertLessThan(dragged, try fittingHeight(pane, rows: 2), "the drag goes below the two-row fit")

        let newOrder: MSADistanceOrder = model.order == .alignment ? .averageLinkage : .alignment
        model.order = newOrder
        let recomputed = await waitUntil(timeout: .seconds(20)) {
            model.status == .ready && model.matrix?.options.order == newOrder
        }
        XCTAssertTrue(recomputed)
        XCTAssertEqual(pane.heightConstraint.constant, dragged, accuracy: 0.5, "a recompute never pulls the pane up")

        pane.select(.annotations)
        pane.select(.distances)
        XCTAssertEqual(
            pane.heightConstraint.constant, try fittingHeight(pane, rows: 2), accuracy: 0.5,
            "switching back to Distances grows it once"
        )
    }

    // MARK: S3 the export folder exists in a fresh project

    func testExportDirectoryIsCreatedInAFreshProject() throws {
        let project = temporaryDirectory.appendingPathComponent("fresh.lungfish", isDirectory: true)
        let bundleURL = project.appendingPathComponent("Alignments/primates.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analyses.path))

        let directory = try XCTUnwrap(MSADistanceMatrixExportCoordinator.suggestedDirectory(bundleURL: bundleURL))
        XCTAssertEqual(directory.standardizedFileURL.path, analyses.standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: analyses.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExportDirectoryFallsBackToTheProjectRoot() throws {
        let project = temporaryDirectory.appendingPathComponent("locked.lungfish", isDirectory: true)
        let bundleURL = project.appendingPathComponent("primates.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }

        let directory = try XCTUnwrap(MSADistanceMatrixExportCoordinator.suggestedDirectory(bundleURL: bundleURL))
        XCTAssertEqual(directory.standardizedFileURL.path, project.standardizedFileURL.path)
    }

    // MARK: S4 the Annotations tab walks the filter field, the header controls, the table, then out

    func testAnnotationsKeyViewRouteWalksFilterControlsTableThenOut() async throws {
        let controller = try await controller()
        let previous = NSButton(title: "Before", target: nil, action: nil)
        let next = NSButton(title: "After", target: nil, action: nil)
        previous.nextKeyView = controller.alignmentKeyView
        controller.alignmentKeyView.nextKeyView = next
        let window = host(controller)
        defer { window.close() }
        let pane = controller.bottomPane
        pane.setOpen(true)
        pane.select(.annotations)
        controller.view.layoutSubtreeIfNeeded()
        let drawer = pane.annotationDrawer

        var walk: [NSView] = []
        var view: NSView? = pane.tabControl.nextKeyView
        while let current = view, current !== next, walk.count < 40 {
            walk.append(current)
            view = current.nextKeyView
        }
        XCTAssertTrue(view === next, "the walk leaves the pane at the next view")
        XCTAssertTrue(walk.first === drawer.annotationFilterField, "Tab from the tab control reaches the filter field")
        XCTAssertTrue(walk.last === drawer.tableView, "the table comes last")
        let controls = walk.dropFirst().dropLast()
        XCTAssertFalse(controls.isEmpty, "the header controls are on the route")
        for control in controls {
            XCTAssertTrue(control.isDescendant(of: drawer), "\(control) is a drawer control")
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "\(control) is visible in the MSA embed")
        }
        XCTAssertTrue(next.previousKeyView === drawer.tableView, "Shift-Tab from the next view returns to the table")

        pane.select(.distances)
        XCTAssertTrue(pane.tabControl.nextKeyView === pane.distancePane.firstKeyView)
        XCTAssertTrue(pane.distancePane.gridView.nextKeyView === next)
        XCTAssertTrue(next.previousKeyView === pane.distancePane.gridView)
    }
}
