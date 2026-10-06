// DatabaseSearchSheetLayoutTests.swift - The Search Online Databases sheet keeps its footer in reach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner report (lane U1): showing Advanced Search Filters in the SRA pane made
// the sheet taller than its window, so Cancel and Download Selected fell below
// the screen. The sheet keeps its size when content is disclosed, and the
// extra height scrolls inside the pane instead.

import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class DatabaseSearchSheetLayoutTests: XCTestCase {
    private static let parentSizes = [
        CGSize(width: 900, height: 600),
        CGSize(width: 1200, height: 700),
    ]

    func testSRAFooterStaysVisibleWithAdvancedFiltersOpen() {
        assertFooterStaysVisible(
            source: .ena,
            disclosedControl: SRADownloadSourcePicker.accessibilityIdentifier
        ) { $0.sraRunsViewModel }
    }

    func testGenBankFooterStaysVisibleWithAdvancedFiltersOpen() {
        assertFooterStaysVisible(source: .ncbi) { $0.genBankGenomesViewModel }
    }

    func testPathoplexusFooterStaysVisibleWithAdvancedFiltersOpen() {
        assertFooterStaysVisible(source: .pathoplexus) { $0.pathoplexusViewModel }
    }

    func testSheetContentSizeFitsInsideASmallParent() {
        let size = DatabaseBrowserViewController.sheetContentSize(fitting: CGSize(width: 800, height: 500))
        XCTAssertLessThanOrEqual(size.width, 800)
        XCTAssertLessThanOrEqual(size.height, 500)
        XCTAssertEqual(
            DatabaseBrowserViewController.sheetContentSize(fitting: CGSize(width: 1800, height: 1100)),
            DatabaseBrowserViewController.defaultSheetContentSize
        )
    }

    func testAvailableSheetSizeStopsAtTheVisibleFrameBottom() {
        let visible = NSRect(x: 0, y: 80, width: 1440, height: 800)
        // The parent's content runs below the Dock, so the visible frame wins.
        let parentContent = NSRect(x: 100, y: 0, width: 800, height: 450)
        let size = DatabaseBrowserViewController.availableSheetSize(
            parentContent: parentContent,
            visibleFrame: visible
        )
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 370)
        // Fully on screen, the parent's content area wins.
        let onScreen = NSRect(x: 100, y: 300, width: 800, height: 450)
        XCTAssertEqual(
            DatabaseBrowserViewController.availableSheetSize(parentContent: onScreen, visibleFrame: visible),
            CGSize(width: 800, height: 450)
        )
    }

    func testBeginSheetOnASmallParentKeepsTheSheetAndFooterInside() throws {
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.center()
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }

        let controller = DatabaseBrowserViewController(source: .ena)
        let sheet = NSWindow(contentViewController: controller)
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }
        controller.dialogState!.sraRunsViewModel.isAdvancedExpanded = true
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: sheet, identifier: "database-search-primary-action") != nil
        }
        sheet.layoutIfNeeded()

        XCTAssertNotNil(sheet.sheetParent)
        let visible = try XCTUnwrap(parent.screen?.visibleFrame)
        let parentContent = parent.convertToScreen(parent.contentLayoutRect)
        XCTAssertLessThanOrEqual(sheet.frame.height, parentContent.height + 0.5)
        XCTAssertLessThanOrEqual(sheet.frame.width, parentContent.width + 0.5)
        XCTAssertTrue(parent.frame.insetBy(dx: -1, dy: -1).contains(sheet.frame), "sheet \(sheet.frame) outside parent \(parent.frame)")
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(sheet.frame), "sheet \(sheet.frame) outside \(visible)")
        for identifier in ["database-search-cancel", "database-search-primary-action"] {
            let button = try XCTUnwrap(AccessibilityTreeProbe.element(in: sheet, identifier: identifier), identifier)
            let frame = (button as AnyObject).accessibilityFrame?() ?? .zero
            XCTAssertFalse(frame.isEmpty, identifier)
            XCTAssertTrue(sheet.frame.contains(frame), "\(identifier) at \(frame) outside the sheet \(sheet.frame)")
        }

        // A shorter parent clamps the open sheet again.
        var shorter = parent.frame
        shorter.origin.y += 100
        shorter.size.height -= 100
        parent.setFrame(shorter, display: false)
        let shorterContent = parent.convertToScreen(parent.contentLayoutRect)
        XCTAssertLessThanOrEqual(sheet.frame.height, shorterContent.height + 0.5)
    }

    private func assertFooterStaysVisible(
        source: DatabaseSource,
        disclosedControl: String? = nil,
        viewModel: (DatabaseSearchDialogState) -> DatabaseBrowserViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        for parentSize in Self.parentSizes {
            let controller = DatabaseBrowserViewController(source: source)
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(parentSize)
            window.orderFront(nil)
            defer { window.orderOut(nil) }

            let state = controller.dialogState!
            // Past the Pathoplexus consent screen, without touching the
            // stored consent.
            viewModel(state).hasAcceptedPathoplexusConsent = true
            viewModel(state).isAdvancedExpanded = true
            AccessibilityTreeProbe.waitUntil {
                AccessibilityTreeProbe.element(in: window, identifier: "database-search-primary-action") != nil
                    && !AccessibilityTreeProbe.elements(in: window, labelled: "Hide").isEmpty
            }
            window.layoutIfNeeded()

            let label = "\(source) at \(Int(parentSize.width))x\(Int(parentSize.height))"
            XCTAssertFalse(
                AccessibilityTreeProbe.elements(in: window, labelled: "Hide").isEmpty,
                "\(label): the advanced filters did not open", file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                window.contentLayoutRect.height, parentSize.height + 0.5,
                "\(label): the sheet must not grow past its parent", file: file, line: line
            )
            if let disclosedControl {
                XCTAssertNotNil(
                    AccessibilityTreeProbe.element(in: window, identifier: disclosedControl),
                    "\(label): \(disclosedControl) must stay in the disclosed filters", file: file, line: line
                )
            }
            for identifier in ["database-search-cancel", "database-search-primary-action"] {
                guard let button = AccessibilityTreeProbe.element(in: window, identifier: identifier) else {
                    XCTFail("\(label): \(identifier) missing from the tree", file: file, line: line)
                    continue
                }
                let frame = (button as AnyObject).accessibilityFrame?() ?? .zero
                XCTAssertFalse(frame.isEmpty, "\(label): \(identifier) has no frame", file: file, line: line)
                XCTAssertTrue(
                    window.frame.contains(frame),
                    "\(label): \(identifier) at \(frame) lies outside the sheet \(window.frame)",
                    file: file, line: line
                )
            }
        }
    }
}
