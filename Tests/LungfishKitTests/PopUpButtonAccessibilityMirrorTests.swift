// PopUpButtonAccessibilityMirrorTests.swift - Menus behind buttons are reachable as AX actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

/// `AccessibilityMenuMirror` lists a button's or header's menu items as
/// custom actions on the owner, and performing one does what choosing the
/// item does.
@MainActor
final class PopUpButtonAccessibilityMirrorTests: XCTestCase {

    private final class Target: NSObject {
        var chosen: [String] = []
        var popUpFired = 0
        @objc func choose(_ sender: Any?) {
            chosen.append((sender as? NSMenuItem)?.title ?? "?")
        }
        @objc func popUpChanged(_ sender: Any?) {
            popUpFired += 1
        }
    }

    func testPullDownMirrorsEveryEnabledItemAfterItsTitleItem() throws {
        let target = Target()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.addItem(withTitle: "Export")
        for title in ["Export CSV\u{2026}", "Export TSV\u{2026}", "Export Excel\u{2026}"] {
            let item = NSMenuItem(title: title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        let disabled = NSMenuItem(title: "Nothing to Export", action: #selector(Target.choose(_:)), keyEquivalent: "")
        disabled.target = target
        disabled.isEnabled = false
        button.menu?.autoenablesItems = false
        button.menu?.addItem(disabled)

        AccessibilityMenuMirror.install(on: button)

        let actions = try XCTUnwrap(button.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Export CSV\u{2026}", "Export TSV\u{2026}", "Export Excel\u{2026}"])
        XCTAssertEqual(actions[1].handler?(), true)
        XCTAssertEqual(target.chosen, ["Export TSV\u{2026}"])
    }

    func testPopUpMirrorSelectsTheItemAndFiresTheButtonAction() throws {
        let target = Target()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: ["Name", "Length", "GC Content"])
        button.target = target
        button.action = #selector(Target.popUpChanged(_:))

        AccessibilityMenuMirror.install(on: button)

        let actions = try XCTUnwrap(button.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Name", "Length", "GC Content"])
        XCTAssertEqual(actions[2].handler?(), true)
        XCTAssertEqual(button.titleOfSelectedItem, "GC Content")
        XCTAssertEqual(target.popUpFired, 1)
    }

    func testHeaderMenuMirrorFlattensOneSubmenuLevelAndSkipsActionlessItems() throws {
        let target = Target()
        let menu = NSMenu(title: "Column")
        menu.autoenablesItems = false
        let sort = NSMenuItem(title: "Sort Ascending", action: #selector(Target.choose(_:)), keyEquivalent: "")
        sort.target = target
        menu.addItem(sort)
        menu.addItem(.separator())
        let filterParent = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        let filterMenu = NSMenu(title: "Filter")
        filterMenu.autoenablesItems = false
        for title in ["Contains\u{2026}", "Is Empty"] {
            let item = NSMenuItem(title: title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            filterMenu.addItem(item)
        }
        filterParent.submenu = filterMenu
        menu.addItem(filterParent)
        menu.addItem(NSMenuItem(title: "Informational", action: nil, keyEquivalent: ""))

        let header = NSTableHeaderView()
        AccessibilityMenuMirror.install(menu, on: header)

        let actions = try XCTUnwrap(header.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Sort Ascending", "Filter: Contains\u{2026}", "Filter: Is Empty"])
        XCTAssertEqual(actions[2].handler?(), true)
        XCTAssertEqual(target.chosen, ["Is Empty"])
    }

    func testEmptyMenuClearsTheMirror() {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "stale") { true }])
        button.menu = NSMenu()
        AccessibilityMenuMirror.install(on: button)
        XCTAssertNil(button.accessibilityCustomActions())
    }
}
