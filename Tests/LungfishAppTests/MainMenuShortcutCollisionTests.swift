// MainMenuShortcutCollisionTests.swift - Every shortcut is unique and HIG-conformant
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// The shortcut audit. Every key equivalent in the whole menu tree is bound
/// once, no menu-bar chord repurposes a view-local chord, and the standard
/// macOS shortcuts keep their standard meaning (Apple HIG, Keyboard).
@MainActor
final class MainMenuShortcutCollisionTests: XCTestCase {
    private struct Chord: Hashable, CustomStringConvertible {
        let key: String
        let modifiers: NSEvent.ModifierFlags

        init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
            self.key = key.lowercased()
            self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        }

        static func == (lhs: Chord, rhs: Chord) -> Bool {
            lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(modifiers.rawValue)
        }

        var description: String {
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Ctrl") }
            if modifiers.contains(.option) { parts.append("Opt") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Cmd") }
            parts.append(keyName)
            return parts.joined(separator: "-")
        }

        private var keyName: String {
            switch key {
            case "\u{8}": return "Delete"
            case "\u{7f}": return "Forward Delete"
            case "\r": return "Return"
            case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): return "Left"
            case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): return "Right"
            default: return key.uppercased()
            }
        }
    }

    private struct Binding {
        let chord: Chord
        let path: String
        let title: String
    }

    private func bindings(in menu: NSMenu, path: String = "") -> [Binding] {
        menu.items.flatMap { item -> [Binding] in
            let itemPath = path.isEmpty ? item.title : "\(path) > \(item.title)"
            var found: [Binding] = []
            if !item.keyEquivalent.isEmpty {
                found.append(Binding(chord: Chord(item.keyEquivalent, item.keyEquivalentModifierMask), path: itemPath, title: item.title))
            }
            if let submenu = item.submenu { found += bindings(in: submenu, path: itemPath) }
            return found
        }
    }

    private func menuBindings() -> [Binding] {
        _ = NSApplication.shared
        return bindings(in: MainMenu.createMainMenu())
    }

    // MARK: - Uniqueness across the whole tree

    func testEveryKeyEquivalentInTheMenuTreeIsBoundExactlyOnce() {
        var owners: [Chord: [String]] = [:]
        for binding in menuBindings() {
            owners[binding.chord, default: []].append(binding.path)
        }
        for (chord, paths) in owners where paths.count > 1 {
            XCTFail("\(chord) is bound by \(paths)")
        }
        XCTAssertFalse(owners.isEmpty)
    }

    // MARK: - View-local chords

    /// Chords handled inside a view's keyDown or a view-local context menu,
    /// which the menu bar must not bind to something else.
    private static let viewLocalChords: [(Chord, String)] = [
        (Chord("p", [.command, .option]), "genotype matrix: mark false positive"),
        (Chord("x", [.command, .option]), "genotype matrix: mark false negative"),
        (Chord("r", [.command, .option]), "genotype matrix: clear review mark"),
        (Chord("m", [.command, .option]), "genotype matrix: add or edit comment"),
        (Chord("\u{8}", []), "sidebar: move to Trash"),
        (Chord("\u{7f}", []), "sidebar: move to Trash"),
        (Chord(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.option]), "taxonomy table: expand row recursively"),
        (Chord("\r", []), "annotation table: activate row"),
    ]

    /// No view-local chord is also a menu-bar chord. Cmd-Shift-A used to be
    /// both (View > AI Assistant and the sidebar's select-siblings monitor);
    /// Select Siblings is now a Selection > Sidebar Item menu item and AI
    /// Assistant moved to Cmd-Opt-A, so there are no exceptions left.
    func testMenuBarDoesNotRepurposeViewLocalChords() {
        let bound = Dictionary(grouping: menuBindings(), by: \.chord)
        for (chord, owner) in Self.viewLocalChords {
            XCTAssertNil(bound[chord], "\(chord) belongs to \(owner) but the menu bar binds it to \(bound[chord]?.map(\.path) ?? [])")
        }
    }

    // MARK: - HIG standard shortcuts

    /// Standard macOS shortcuts and the only titles they may carry. A chord
    /// listed here that is bound to anything else has been repurposed, which
    /// the HIG forbids. A chord with no allowed title must not be bound.
    private static let standardShortcuts: [(Chord, [String], String)] = [
        (Chord("a", [.command]), ["Select All"], "Select All"),
        (Chord("c", [.command]), ["Copy"], "Copy"),
        (Chord("v", [.command]), ["Paste"], "Paste"),
        (Chord("x", [.command]), ["Cut"], "Cut"),
        (Chord("z", [.command]), ["Undo"], "Undo"),
        (Chord("z", [.command, .shift]), ["Redo"], "Redo"),
        (Chord("s", [.command]), ["Save", "Save\u{2026}"], "Save"),
        (Chord("s", [.command, .shift]), ["Save As\u{2026}", "Duplicate"], "Save As"),
        (Chord("w", [.command]), ["Close", "Close Window"], "Close"),
        (Chord("q", [.command]), [], "Quit (title starts with Quit)"),
        (Chord("h", [.command]), [], "Hide (title starts with Hide)"),
        (Chord("h", [.command, .option]), ["Hide Others"], "Hide Others"),
        (Chord("m", [.command]), ["Minimize"], "Minimize"),
        (Chord("n", [.command]), [], "New (title starts with New)"),
        (Chord("o", [.command]), [], "Open (title starts with Open)"),
        (Chord("p", [.command]), ["Print\u{2026}"], "Print"),
        (Chord("f", [.command]), ["Find\u{2026}", "Find"], "Find"),
        (Chord("g", [.command]), ["Find Next"], "Find Next"),
        (Chord("g", [.command, .shift]), ["Find Previous"], "Find Previous"),
        (Chord(",", [.command]), ["Settings\u{2026}", "Preferences\u{2026}"], "Settings"),
        (Chord("?", [.command, .shift]), [], "Help (title ends with Help)"),
        (Chord("f", [.command, .control]), ["Enter Full Screen", "Exit Full Screen"], "Full Screen"),
        (Chord("n", [.command, .shift]), ["New Folder\u{2026}", "New Folder"], "New Folder (Finder)"),
        (Chord("\u{8}", [.command]), ["Move to Trash"], "Move to Trash (Finder)"),
        (Chord("t", [.command]), ["New Tab"], "New Tab"),
        (Chord("i", [.command]), ["Get Info", "Italic"], "Get Info"),
        (Chord("d", [.command]), ["Duplicate"], "Duplicate (Finder)"),
    ]

    private static func titleMatches(_ title: String, standard: String) -> Bool {
        switch standard {
        case "Quit (title starts with Quit)": return title.hasPrefix("Quit")
        case "Hide (title starts with Hide)": return title.hasPrefix("Hide")
        case "New (title starts with New)": return title.hasPrefix("New")
        case "Open (title starts with Open)": return title.hasPrefix("Open")
        case "Help (title ends with Help)": return title.hasSuffix("Help")
        default: return false
        }
    }

    func testStandardShortcutsKeepTheirStandardMeaning() {
        let bound = Dictionary(grouping: menuBindings(), by: \.chord)
        for (chord, allowedTitles, standard) in Self.standardShortcuts {
            for binding in bound[chord] ?? [] {
                XCTAssertTrue(
                    allowedTitles.contains(binding.title) || Self.titleMatches(binding.title, standard: standard),
                    "\(chord) is \(standard) on macOS but the menu bar binds it to '\(binding.path)'"
                )
            }
        }
        // Standard shortcuts LGE must offer with the standard meaning.
        for chord in [Chord("c", [.command]), Chord("v", [.command]), Chord("z", [.command]), Chord("a", [.command]), Chord("q", [.command]), Chord("w", [.command]), Chord(",", [.command])] {
            XCTAssertNotNil(bound[chord], "\(chord) must be bound")
        }
        XCTAssertNil(bound[Chord("s", [.command])], "LGE saves as you go and binds nothing to Cmd-S")
    }

    /// Chords the system reserves. An app menu item bound to one of these
    /// never receives the key, so it is a shortcut that does not work.
    private static let systemReservedChords: [(Chord, String)] = [
        (Chord("\t", [.command]), "app switcher"),
        (Chord(" ", [.command]), "Spotlight"),
        (Chord(" ", [.command, .option]), "Finder search"),
        (Chord("\u{1b}", [.command, .option]), "Force Quit"),
        (Chord("3", [.command, .shift]), "screenshot"),
        (Chord("4", [.command, .shift]), "screenshot"),
        (Chord("5", [.command, .shift]), "screenshot"),
        (Chord("q", [.command, .control]), "lock screen"),
        (Chord("q", [.command, .shift]), "log out"),
        (Chord("d", [.command, .option]), "show or hide the Dock"),
    ]

    /// No exceptions: View > Document Inspector carried Cmd-Opt-D, the
    /// Dock's chord, until the owner unbound it (2026-09-30). The item stays
    /// in the menu without a shortcut.
    func testNoMenuItemBindsASystemReservedChord() {
        let bound = Dictionary(grouping: menuBindings(), by: \.chord)
        for (chord, purpose) in Self.systemReservedChords {
            XCTAssertNil(bound[chord], "\(chord) is the system's \(purpose) chord but the menu bar binds it to \(bound[chord]?.map(\.path) ?? [])")
        }
    }

    // MARK: - The chords this pass adds

    func testThePassAddsOnlyTheOwnerApprovedChords() {
        let bound = Dictionary(grouping: menuBindings(), by: \.chord)
        let expected: [(Chord, String)] = [
            (Chord("s", [.command, .option]), "Selection > Show in Inspector"),
            (Chord("n", [.command, .shift]), "Selection > Sidebar Item > New Folder\u{2026}"),
            (Chord("d", [.command]), "Selection > Sidebar Item > Duplicate"),
            (Chord("\u{8}", [.command]), "Selection > Sidebar Item > Move to Trash"),
            (Chord("a", [.command, .shift]), "Selection > Sidebar Item > Select Siblings"),
            (Chord("a", [.command, .option]), "View > AI Assistant"),
        ]
        for (chord, path) in expected {
            XCTAssertEqual(bound[chord]?.map(\.path), [path], "\(chord)")
        }
    }

    /// The owner's two rebinding decisions of 2026-09-30.
    func testDocumentInspectorIsUnboundAndAIAssistantLeftCmdShiftA() {
        let bound = Dictionary(grouping: menuBindings(), by: \.chord)
        XCTAssertNil(bound[Chord("d", [.command, .option])], "Cmd-Opt-D is the Dock's")
        XCTAssertEqual(bound[Chord("a", [.command, .option])]?.map(\.title), ["AI Assistant"])
        XCTAssertEqual(bound[Chord("a", [.command, .shift])]?.map(\.title), ["Select Siblings"])
        let documentInspector = bindings(in: MainMenu.createMainMenu()).first { $0.title == "Document Inspector" }
        XCTAssertNil(documentInspector, "Document Inspector stays in View, unbound")
    }
}
