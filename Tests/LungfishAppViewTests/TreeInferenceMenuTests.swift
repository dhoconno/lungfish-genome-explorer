// TreeInferenceMenuTests.swift - Tools > Build Tree with IQ-TREE and Selection > Tree Node placement
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishPhylogeneticsUI
import XCTest
@testable import LungfishApp

@MainActor
final class TreeInferenceMenuTests: XCTestCase {
    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.items.first { $0.title == title }?.submenu, "no \(title) menu")
    }

    func testAlignmentSubmenuEndsWithBuildTreeAfterASeparator() throws {
        _ = NSApplication.shared
        let tools = try submenu("Tools", in: MainMenu.createMainMenu())
        let alignment = try submenu("Alignment & Phylogenetics", in: tools)
        XCTAssertNil(tools.items.first { $0.title == "Multiple Sequence Alignment" })

        let items = alignment.items
        let buildTree = try XCTUnwrap(items.last)
        XCTAssertEqual(buildTree.title, "Build Tree with IQ-TREE\u{2026}")
        XCTAssertEqual(buildTree.identifier?.rawValue, "tools-build-tree-iqtree")
        XCTAssertEqual(buildTree.action, #selector(ToolsMenuActions.showIQTreeInference(_:)))
        XCTAssertEqual(buildTree.keyEquivalent, "")
        XCTAssertNil(buildTree.target)
        XCTAssertTrue(items[items.count - 2].isSeparatorItem)
        XCTAssertGreaterThan(items.count, 2, "the alignment tools stay above the separator")
    }

    func testSelectionMenuHasTreeNodeSubmenuWithSectionedNilTargetItems() throws {
        _ = NSApplication.shared
        let selection = try submenu("Selection", in: MainMenu.createMainMenu())
        let titles = selection.items.map(\.title)
        let tableRow = try XCTUnwrap(titles.firstIndex(of: "Table Row"))
        XCTAssertEqual(titles[tableRow + 1], "Tree Node")

        let treeNode = try XCTUnwrap(selection.items[tableRow + 1].submenu)
        XCTAssertEqual(treeNode.title, "Tree Node")
        var sections: [[String]] = [[]]
        for item in treeNode.items {
            if item.isSeparatorItem { sections.append([]) } else { sections[sections.count - 1].append(item.title) }
        }
        XCTAssertEqual(sections, [
            ["Show in Inspector"],
            ["Copy Name", "Copy Subtree as Newick", "Copy Selected Tip Names"],
            ["Root on Selected Branch", "Collapse Clade", "Center Node"],
            ["Extract Subtree as New Bundle\u{2026}", "Export Subtree\u{2026}"],
            ["Reveal Provenance"],
        ])
        for item in treeNode.items where !item.isSeparatorItem {
            XCTAssertNil(item.target, item.title)
            XCTAssertEqual(item.keyEquivalent, "", item.title)
            XCTAssertNotNil(item.action, item.title)
        }
    }
}
