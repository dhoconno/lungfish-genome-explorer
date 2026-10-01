// ResultRowMenuValidationTests.swift - Context-menu membership of nested menu items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class ResultRowMenuValidationTests: XCTestCase {
    func testSubmenuItemBelongsToTheContextMenuThatPresentsIt() {
        let context = NSMenu()
        let parent = NSMenuItem(title: "Look Up on NCBI", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let child = NSMenuItem(title: "Search PubMed", action: nil, keyEquivalent: "")
        submenu.addItem(child)
        parent.submenu = submenu
        context.addItem(parent)
        let nested = NSMenu()
        let deep = NSMenuItem(title: "Deep", action: nil, keyEquivalent: "")
        nested.addItem(deep)
        let deepParent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        deepParent.submenu = nested
        submenu.addItem(deepParent)

        XCTAssertTrue(ResultRowMenuValidation.isContextMenuItem(parent, in: [context]))
        XCTAssertTrue(ResultRowMenuValidation.isContextMenuItem(child, in: [context]), "one submenu level")
        XCTAssertTrue(ResultRowMenuValidation.isContextMenuItem(deep, in: [nil, context]), "two submenu levels")
    }

    func testMenuBarItemIsNotAContextMenuItem() {
        let context = NSMenu()
        let barMenu = NSMenu()
        let item = NSMenuItem(title: "Copy Name", action: nil, keyEquivalent: "")
        barMenu.addItem(item)
        XCTAssertFalse(ResultRowMenuValidation.isContextMenuItem(item, in: [context]))
        XCTAssertFalse(ResultRowMenuValidation.isContextMenuItem(NSMenuItem(), in: [context]))
        XCTAssertFalse(ResultRowMenuValidation.isContextMenuItem(item, in: []))
    }
}
