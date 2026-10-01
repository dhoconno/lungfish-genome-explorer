// ContextMenuParityAssert.swift - Every context menu command has a keyboard or AX route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

/// Asserts that a context menu offers nothing a mouse-free client cannot
/// reach.
///
/// Every titled item of the context menu must have either a cell
/// accessibility action of the same title or a menu-bar item that sends the
/// same selector. Separators are ignored, and so are items that only open a
/// submenu (their children are a separate concern, like the sidebar's
/// "Move to"). Titles listed in `exempt` are skipped, which is for commands
/// the owner has decided stay mouse-only.
@MainActor
public enum ContextMenuParityAssert {
    /// Every selector any item of `mainMenu`'s tree sends.
    public static func selectors(in mainMenu: NSMenu) -> Set<Selector> {
        var found: Set<Selector> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action { found.insert(action) }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(mainMenu)
        return found
    }

    /// The context-menu titles that have neither route. Empty means parity.
    public static func unreachableTitles(
        contextMenu: NSMenu,
        cellActionNames: [String],
        menuBarSelectors: Set<Selector>,
        exempt: Set<String> = []
    ) -> [String] {
        let cellNames = Set(cellActionNames)
        return contextMenu.items.compactMap { item -> String? in
            guard !item.isSeparatorItem, item.submenu == nil, !exempt.contains(item.title) else { return nil }
            if cellNames.contains(item.title) { return nil }
            if let action = item.action, menuBarSelectors.contains(action) { return nil }
            return item.title
        }
    }

    /// Fails the test for every context-menu command without a route.
    public static func assertParity(
        contextMenu: NSMenu,
        cellActionNames: [String],
        mainMenu: NSMenu,
        exempt: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let missing = unreachableTitles(
            contextMenu: contextMenu,
            cellActionNames: cellActionNames,
            menuBarSelectors: selectors(in: mainMenu),
            exempt: exempt
        )
        XCTAssertTrue(
            missing.isEmpty,
            "Context menu commands with no cell action and no menu-bar selector: \(missing)",
            file: file,
            line: line
        )
    }
}
