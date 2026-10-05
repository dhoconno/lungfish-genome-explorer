// PhylogeneticTreeNodeMenuBarTests.swift - Selection > Tree Node validation and canvas AX
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishPhylogeneticsUI

/// The Selection > Tree Node items are nil-target, so the tree view controller
/// validates them while its node table or canvas has focus and a node is
/// selected. The canvas node elements carry the same commands as AX actions.
@MainActor
final class PhylogeneticTreeNodeMenuBarTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow!
    private var controller: PhylogeneticTreeViewController!
    private let pasteboard = NSPasteboard.withUniqueName()

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhylogeneticTreeNodeMenuBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("tree.nwk")
        try "((tipA:0.0123,tipB:0.1)99.9/100:0.2,tipC:0.3);\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = directory.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        controller = PhylogeneticTreeViewController()
        controller.pasteboard = pasteboard
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        try controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        controller = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private var treeNodeItems: [NSMenuItem] {
        PhylogeneticTreeViewController.nodeMenuBarSections.flatMap { $0 }.map {
            NSMenuItem(title: $0.title, action: $0.selector, keyEquivalent: "")
        }
    }

    func testTreeNodeItemsAreEnabledWithTableFocusAndASelectedNode() throws {
        controller.testingSelectNode(label: "tipA")
        XCTAssertTrue(window.makeFirstResponder(controller.testingNodeTableView))
        for item in treeNodeItems where item.title != "Expand Clade" && item.title != "Collapse Clade" {
            XCTAssertTrue(controller.validateMenuItem(item), item.title)
        }
    }

    func testTreeNodeItemsAreEnabledWithCanvasFocus() throws {
        controller.testingSelectNode(label: "tipA")
        XCTAssertTrue(window.makeFirstResponder(controller.testingCanvasView))
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(
            title: "", action: #selector(PhylogeneticTreeViewController.copySelectedSubtreeNewick(_:)), keyEquivalent: ""
        )))
    }

    func testTreeNodeItemsAreDisabledWithoutFocus() throws {
        controller.testingSelectNode(label: "tipA")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        controller.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        for item in treeNodeItems {
            XCTAssertFalse(controller.validateMenuItem(item), item.title)
        }
    }

    func testTreeNodeItemsAreDisabledWhenNoNodeIsSelected() throws {
        let empty = PhylogeneticTreeViewController()
        empty.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let emptyWindow = NSWindow(contentRect: empty.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        emptyWindow.isReleasedWhenClosed = false
        emptyWindow.contentView = empty.view
        emptyWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(emptyWindow.makeFirstResponder(empty.testingNodeTableView))
        for item in treeNodeItems {
            XCTAssertFalse(empty.validateMenuItem(item), item.title)
        }
        emptyWindow.orderOut(nil)
        emptyWindow.contentView = nil
    }

    func testCanvasNodeLabelsCarryBranchLengthAndSupport() throws {
        let labels = controller.testingCanvasAccessibilityElements.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("tipA, tip, branch length 0.0123"), "\(labels)")
        XCTAssertTrue(
            labels.contains { $0.hasPrefix("internal node, 2 tips, branch length 0.2, support 99.9/100") },
            "\(labels)"
        )
    }

    func testCanvasNodePressSelectsTheNodeAndOffersTheNodeCommands() throws {
        let element = try XCTUnwrap(
            controller.testingCanvasAccessibilityElements.first {
                ($0.accessibilityLabel() ?? "").hasPrefix("tipB")
            }
        )
        XCTAssertEqual(element.accessibilityRole(), .button)
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(controller.testingSelectedNodeLabel, "tipB")

        let names = (element.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertEqual(names.first, "Show in Inspector")
        XCTAssertTrue(names.contains("Copy Subtree as Newick"))
        XCTAssertTrue(names.contains("Root on Selected Branch"))
        XCTAssertTrue(names.contains("Center Node"))

        pasteboard.clearContents()
        let copy = try XCTUnwrap(element.accessibilityCustomActions()?.first { $0.name == "Copy Name" })
        XCTAssertEqual(copy.handler?(), true)
        XCTAssertEqual(pasteboard.string(forType: .string), "tipB")
    }
}
