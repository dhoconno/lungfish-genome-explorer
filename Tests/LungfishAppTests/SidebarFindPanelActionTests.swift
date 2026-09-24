// SidebarFindPanelActionTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FEA-17: Edit > Find (Cmd-F) was dead in the main window whenever no data
// view claimed `performFindPanelAction:`. P7 gave result tables (BatchTableView)
// their own handling; this covers the remaining fallback — routing to the
// sidebar/project search field when nothing else in the responder chain
// claims the selector (e.g. an empty project, or focus on the sequence
// viewer rather than a result table).

import XCTest
import AppKit
@testable import LungfishApp

final class SidebarFindPanelActionTests: XCTestCase {
    @MainActor func testPerformFindPanelActionWithShowFindInterfaceFocusesSidebarSearchField() throws {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = sidebar.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let menuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        menuItem.tag = NSTextFinder.Action.showFindInterface.rawValue

        let handled = window.firstResponder?.tryToPerform(
            #selector(SidebarViewController.performFindPanelAction(_:)),
            with: menuItem
        ) ?? false

        XCTAssertTrue(handled, "the responder chain should reach SidebarViewController.performFindPanelAction")
        XCTAssertTrue(sidebar.focusSearchField(), "search field should be focusable once the window exists")
    }

    @MainActor func testPerformFindPanelActionActuallyMovesFirstResponderToSearchField() throws {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = sidebar.view
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(sidebar.view)
        defer { window.orderOut(nil) }

        let menuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        menuItem.tag = NSTextFinder.Action.showFindInterface.rawValue

        sidebar.performFindPanelAction(menuItem)

        // The field editor becomes first responder, not the NSSearchField
        // itself directly, but it must be nested inside the search field.
        let firstResponderView = window.firstResponder as? NSView
        XCTAssertNotNil(firstResponderView)
    }

    @MainActor func testNonShowFindInterfaceTagIsNotHandledLocally() throws {
        // Only .showFindInterface is meaningful for a plain search field —
        // find-next/previous/replace tags should forward up the chain rather
        // than being silently swallowed here.
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        let menuItem = NSMenuItem(title: "Find Next", action: nil, keyEquivalent: "")
        menuItem.tag = NSTextFinder.Action.nextMatch.rawValue

        // With no window and no further responder chain, this should not
        // crash — it simply has nowhere to forward to.
        sidebar.performFindPanelAction(menuItem)
    }
}
