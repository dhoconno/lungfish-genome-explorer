// MainMenuKeyEquivalentTests.swift - Every shortcut in the main menu does one thing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class MainMenuKeyEquivalentTests: XCTestCase {
    private struct Binding: Hashable {
        let key: String
        let modifiers: UInt
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            [item] + (item.submenu.map(allItems(in:)) ?? [])
        }
    }

    private func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        allItems(in: menu).first { $0.title == title }
    }

    /// The genotype review commands are real menu items with a nil target, so
    /// AppKit dispatches ⌘R / ⌘K / ⇧⌘F / ⇧⌘O through the responder chain to
    /// `GenotypeResultViewController` (a `performKeyEquivalent` override on a
    /// view controller is never reached).
    func testGenotypeSampleCommandsAreMenuItemsWithTheDocumentedShortcuts() throws {
        let menu = MainMenu.createMainMenu()
        let review = try XCTUnwrap(item(titled: "Genotype Sample", in: menu))
        let submenu = try XCTUnwrap(review.submenu)

        let expected: [(String, String, NSEvent.ModifierFlags, Selector)] = [
            ("Mark Sample Reviewed", "r", [.command], #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:))),
            ("Mark Sample Confirmed", "k", [.command], #selector(GenotypeResultViewController.markSelectedSampleConfirmed(_:))),
            ("Flag Sample for Review", "f", [.command, .shift], #selector(GenotypeResultViewController.flagSelectedSampleNeedsReview(_:))),
            ("Sample Detail\u{2026}", "o", [.command, .shift], #selector(GenotypeResultViewController.openSelectedSampleDetail(_:))),
        ]
        // The four sample commands alone. The matrix commands are the Genotype Call submenu beside it.
        XCTAssertEqual(submenu.items.map(\.title), expected.map(\.0))
        for (title, key, modifiers, action) in expected {
            let item = try XCTUnwrap(submenu.items.first { $0.title == title }, title)
            XCTAssertEqual(item.keyEquivalent, key, title)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, title)
            XCTAssertEqual(item.action, action, title)
            XCTAssertNil(item.target, "\(title) must dispatch through the responder chain")
        }
        XCTAssertEqual(
            expected.map(\.3),
            GenotypeResultViewController.reviewCommandSelectors,
            "menu order and the controller's validation list must agree"
        )
    }

    /// No two menu items share a key equivalent, so each shortcut in the
    /// menu bar does exactly one thing (⌘0 is Zoom to Fit alone; ⌥⌘N is New
    /// Window for Current Project alone).
    func testNoTwoMenuItemsShareAKeyEquivalent() {
        let menu = MainMenu.createMainMenu()
        var seen: [Binding: String] = [:]
        for item in allItems(in: menu) where !item.keyEquivalent.isEmpty {
            let binding = Binding(
                key: item.keyEquivalent.lowercased(),
                modifiers: item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue
            )
            if let previous = seen[binding] {
                XCTFail("'\(item.title)' shares its key equivalent with '\(previous)'")
            }
            seen[binding] = item.title
        }

        let zoomToFit = item(titled: "Zoom to Fit", in: menu)
        XCTAssertEqual(zoomToFit?.keyEquivalent, "0")
        XCTAssertEqual(zoomToFit?.keyEquivalentModifierMask, [.command])
        let newWindow = item(titled: "New Window for Current Project", in: menu)
        XCTAssertEqual(newWindow?.keyEquivalent, "n")
        XCTAssertEqual(newWindow?.keyEquivalentModifierMask, [.command, .option])
    }

    /// The genotype matrix's shortcuts are real menu items now (Selection >
    /// Genotype Call), so each matrix chord must be bound
    /// in the menu bar exactly once, to the item of the same command. The
    /// false-negative command moved from ⌥⌘N (New Window for Current Project)
    /// to ⌥⌘X earlier.
    func testGenotypeMatrixShortcutsDoNotCollideWithMenuBarShortcuts() {
        let menu = MainMenu.createMainMenu()
        let menuBindings = Set(allItems(in: menu).filter { !$0.keyEquivalent.isEmpty }.map {
            Binding(
                key: $0.keyEquivalent.lowercased(),
                modifiers: $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue
            )
        })
        let matrixModifiers: NSEvent.ModifierFlags = [.command, .option]
        let state = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: [],
            capability: GenotypeMatrixReviewCapability.evaluate(
                selection: [], evidence: .init(), reviews: [], comments: [], isWritable: false
            ),
            visibilityCapability: .empty,
            keyModifierRawValue: matrixModifiers.rawValue
        ))
        let matrixKeys = state.items.filter { !$0.keyEquivalent.isEmpty }
        XCTAssertFalse(matrixKeys.isEmpty)
        for item in matrixKeys {
            let owners = allItems(in: menu).filter {
                $0.keyEquivalent.lowercased() == item.keyEquivalent.lowercased()
                    && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == matrixModifiers
            }
            XCTAssertEqual(owners.count, 1, "matrix '\(item.title)' (⌥⌘\(item.keyEquivalent.uppercased())) must be bound once in the menu bar")
            let ownerTitle = owners.first?.title.replacingOccurrences(of: "\u{2026}", with: "") ?? ""
            let matrixTitle = item.title.replacingOccurrences(of: "\u{2026}", with: "")
            XCTAssertTrue(
                matrixTitle.hasSuffix(ownerTitle) || ownerTitle.hasSuffix(matrixTitle.replacingOccurrences(of: "Add ", with: "Edit ")),
                "menu item '\(ownerTitle)' should be the matrix command '\(matrixTitle)'"
            )
        }
        _ = menuBindings
        XCTAssertEqual(matrixKeys.first { $0.command == .markFalseNegative }?.keyEquivalent, "x")
    }
}
