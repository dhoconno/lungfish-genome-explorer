// MenuOutline.swift - Renders a built NSMenu as an indented tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Walks a real built menu and renders it as an indented tree. The structure
/// tests compare it with an expected tree, and the same text is what a menu
/// review reads.
///
/// One line per item. A submenu item ends in `▸` and is followed by its items
/// one level deeper. A separator is `---`. A key equivalent follows the title
/// as glyphs in the order Control, Option, Shift, Command. A hidden item is
/// marked `(hidden)`, which no menu in the app should ever show.
@MainActor
enum MenuOutline {
    static func lines(_ menu: NSMenu, depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var result: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                result.append("\(indent)---")
                continue
            }
            var line = indent + item.title
            if item.submenu != nil { line += " \u{25B8}" }
            let chord = chordGlyphs(for: item)
            if !chord.isEmpty { line += "  \(chord)" }
            if item.isHidden { line += " (hidden)" }
            result.append(line)
            if let submenu = item.submenu {
                result += lines(submenu, depth: depth + 1)
            }
        }
        return result
    }

    /// The menu titled `title` in the main menu bar, as a tree that starts with its own title.
    static func lines(titled title: String, in mainMenu: NSMenu) -> [String] {
        guard let menu = mainMenu.items.first(where: { $0.title == title })?.submenu else { return [] }
        return [title] + lines(menu, depth: 1)
    }

    static func text(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// Every item in the menu and its submenus, separators included, in tree order.
    static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            [item] + (item.submenu.map(allItems(in:)) ?? [])
        }
    }

    /// Every menu in the tree, the root first.
    static func allMenus(in menu: NSMenu) -> [NSMenu] {
        [menu] + menu.items.compactMap(\.submenu).flatMap(allMenus(in:))
    }

    /// Problems with the separators of every menu in the tree. A menu may not
    /// start or end with a separator, and no two separators may touch.
    static func separatorProblems(in menu: NSMenu) -> [String] {
        var problems: [String] = []
        for candidate in allMenus(in: menu) {
            let items = candidate.items
            guard !items.isEmpty else { continue }
            if items.first?.isSeparatorItem == true { problems.append("'\(candidate.title)' starts with a separator") }
            if items.last?.isSeparatorItem == true { problems.append("'\(candidate.title)' ends with a separator") }
            for (previous, next) in zip(items, items.dropFirst()) where previous.isSeparatorItem && next.isSeparatorItem {
                problems.append("'\(candidate.title)' has two separators in a row")
            }
        }
        return problems
    }

    private static func chordGlyphs(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "\u{2303}" }
        if modifiers.contains(.option) { glyphs += "\u{2325}" }
        if modifiers.contains(.shift) { glyphs += "\u{21E7}" }
        if modifiers.contains(.command) { glyphs += "\u{2318}" }
        return glyphs + item.keyEquivalent.uppercased()
    }
}
