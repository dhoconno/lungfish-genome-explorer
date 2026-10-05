// MSADistanceMatrixMenuRoutingTests.swift - Menu items and window routes for the MSA bottom pane and distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishAlignmentUI
import LungfishTestSupport

@MainActor
final class MSADistanceMatrixMenuRoutingTests: XCTestCase {
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
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems(in:)) ?? []) }
    }

    func testViewAndFileMenusOfferTheDistanceMatrixCommands() throws {
        let menu = MainMenu.createMainMenu()
        let items = allItems(in: menu)
        let toggle = try XCTUnwrap(items.first { $0.identifier?.rawValue == DistanceMatrixMenuID.toggle })
        XCTAssertEqual(toggle.title, "Show Distance Matrix")
        XCTAssertEqual(toggle.keyEquivalent, "m")
        XCTAssertEqual(toggle.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .control])
        XCTAssertEqual(toggle.action, #selector(DistanceMatrixMenuActions.toggleDistanceMatrix(_:)))
        XCTAssertNil(toggle.target)

        let submenu = try XCTUnwrap(items.first { $0.identifier?.rawValue == DistanceMatrixMenuID.submenu }?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), [
            "Reveal Pair in Alignment", "Select Row's Sequences", "Copy Matrix", "Export Matrix as TSV\u{2026}",
        ])
        XCTAssertEqual(submenu.items.map(\.action), [
            #selector(DistanceMatrixMenuActions.revealPairInAlignment(_:)),
            #selector(DistanceMatrixMenuActions.selectRowSequences(_:)),
            #selector(DistanceMatrixMenuActions.copyMatrix(_:)),
            #selector(DistanceMatrixMenuActions.exportDistanceMatrix(_:)),
        ])

        let fileExport = try XCTUnwrap(items.first { $0.identifier?.rawValue == DistanceMatrixMenuID.fileExport })
        XCTAssertEqual(fileExport.title, "Distance Matrix (TSV)\u{2026}")
        XCTAssertEqual(fileExport.parent?.title, "Export")
        XCTAssertEqual(fileExport.action, #selector(DistanceMatrixMenuActions.exportDistanceMatrix(_:)))

        // Control-Command-M is used once in the whole menu bar.
        let controlCommandM = items.filter {
            $0.keyEquivalent == "m" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .control]
        }
        XCTAssertEqual(controlCommandM.count, 1)
    }

    func testShowDrawerAndDistanceMatrixRoutesDriveTheMSAPane() async throws {
        let source = temporaryDirectory.appendingPathComponent("routes.fa")
        try ">a\nACGTAC\n>b\nACGAAC\n>c\nTCGAAC\n".write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = temporaryDirectory.appendingPathComponent("routes.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)

        let windowController = MainWindowController()
        defer { windowController.close() }
        let split = try XCTUnwrap(windowController.mainSplitViewController)
        _ = split.view
        let viewer = try XCTUnwrap(split.viewerController)
        try await viewer.displayMultipleSequenceAlignmentBundle(at: bundleURL)
        let msa = try XCTUnwrap(viewer.multipleSequenceAlignmentViewController)
        // A stored Annotations choice, so Show Drawer opens on the tab Show Distance Matrix then switches.
        defaults.set("annotations", forKey: MSABottomPaneView.DefaultsKey.tab)
        msa.bottomPane.defaults = defaults
        msa.bottomPane.reduceMotion = { true }
        XCTAssertFalse(msa.isBottomPaneOpen)

        func validated(_ action: Selector, title: String = "") -> (enabled: Bool, title: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            let enabled = windowController.validateMenuItem(item)
            return (enabled, item.title)
        }

        // View > Show Drawer (Control-Command-B) was a dead route on an MSA.
        XCTAssertEqual(validated(#selector(MainWindowController.toggleAnnotationDrawer(_:))).title, "Show Drawer")
        windowController.toggleAnnotationDrawer(nil)
        XCTAssertTrue(msa.isBottomPaneOpen)
        XCTAssertEqual(validated(#selector(MainWindowController.toggleAnnotationDrawer(_:))).title, "Hide Drawer")
        XCTAssertTrue(validated(#selector(MainWindowController.makeDrawerTaller(_:))).enabled)
        let height = msa.bottomPane.heightConstraint.constant
        windowController.makeDrawerTaller(nil)
        XCTAssertEqual(msa.bottomPane.heightConstraint.constant, height + DrawerDividerView.keyboardStep)

        // View > Show Distance Matrix (Control-Command-M).
        XCTAssertEqual(validated(#selector(MainWindowController.toggleDistanceMatrix(_:))).title, "Show Distance Matrix")
        XCTAssertFalse(validated(#selector(MainWindowController.copyMatrix(_:))).enabled, "no matrix on screen yet")
        XCTAssertFalse(validated(#selector(MainWindowController.selectRowSequences(_:))).enabled)
        windowController.toggleDistanceMatrix(nil)
        XCTAssertTrue(msa.isDistanceMatrixShowing)
        let toggle = validated(#selector(MainWindowController.toggleDistanceMatrix(_:)))
        XCTAssertTrue(toggle.enabled)
        XCTAssertEqual(toggle.title, "Hide Distance Matrix")
        XCTAssertTrue(validated(#selector(MainWindowController.exportDistanceMatrix(_:))).enabled)

        // View > Distance Matrix > Select Row's Sequences, the twin of the
        // cell and header command (review S4).
        let ready = await waitUntil(timeout: .seconds(20)) { msa.bottomPane.distancePane.model.status == .ready }
        XCTAssertTrue(ready)
        let grid = msa.bottomPane.distancePane.gridView
        grid.updateSelection { $0.click(MSADistanceCell(row: 2, column: 0)) }
        XCTAssertTrue(validated(#selector(MainWindowController.selectRowSequences(_:))).enabled)
        windowController.selectRowSequences(nil)
        XCTAssertEqual(msa.testingSelectedRowIndices, IndexSet(integer: 2))
        XCTAssertEqual(grid.selection.selectedSequences, IndexSet(integer: 2))

        windowController.toggleDistanceMatrix(nil)
        XCTAssertFalse(msa.isBottomPaneOpen)
        XCTAssertEqual(validated(#selector(MainWindowController.toggleDistanceMatrix(_:))).title, "Show Distance Matrix")
    }
}
