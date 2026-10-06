// SelectionMenuTests.swift - The Selection menu and the other Lane 0 menu-bar items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishGenotypeUI
import LungfishKit
import LungfishTwelveSUI
import XCTest
@testable import LungfishApp

/// The Selection menu gives every row command a menu-bar route, and the
/// items are nil-target so the first responder validates them. Lane 0 adds
/// the menu and the items; the lanes that follow add the handlers.
@MainActor
final class SelectionMenuTests: XCTestCase {

    private func mainMenu() -> NSMenu {
        _ = NSApplication.shared
        return MainMenu.createMainMenu()
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.items.first { $0.title == title }?.submenu, "no \(title) menu")
    }

    private func item(identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == identifier }, "no item \(identifier)")
    }

    // MARK: - Placement

    func testSelectionMenuSitsBetweenSequenceAndTools() throws {
        let titles = mainMenu().items.map(\.title)
        let sequence = try XCTUnwrap(titles.firstIndex(of: "Sequence"))
        let selection = try XCTUnwrap(titles.firstIndex(of: "Selection"))
        let tools = try XCTUnwrap(titles.firstIndex(of: "Tools"))
        XCTAssertEqual(selection, sequence + 1)
        XCTAssertEqual(tools, selection + 1)
        let selectionItem = try XCTUnwrap(mainMenu().items.first { $0.title == "Selection" })
        XCTAssertEqual(selectionItem.identifier?.rawValue, MainMenuAccessibilityID.selectionMenu)
    }

    func testSelectionMenuHoldsTheTwoSubmenusAndOneSharedShowInInspector() throws {
        let menu = try submenu("Selection", in: mainMenu())
        let sidebar = try item(identifier: MainMenuAccessibilityID.selectionSidebarItem, in: menu)
        XCTAssertEqual(sidebar.title, "Sidebar Item")
        XCTAssertNotNil(sidebar.submenu)
        let tableRow = try item(identifier: MainMenuAccessibilityID.selectionTableRow, in: menu)
        XCTAssertEqual(tableRow.title, "Table Row")
        XCTAssertNotNil(tableRow.submenu)

        let inspector = try item(identifier: MainMenuAccessibilityID.selectionShowInInspector, in: menu)
        XCTAssertEqual(inspector.title, "Show in Inspector")
        XCTAssertEqual(inspector.action, #selector(ResultRowMenuActions.showSelectedRowInInspector(_:)))
        XCTAssertNil(inspector.target)
        XCTAssertEqual(inspector.keyEquivalent, "s")
        XCTAssertEqual(inspector.keyEquivalentModifierMask, [.command, .option])

        // Shared once at the top level, so neither submenu repeats it.
        for sub in [sidebar.submenu!, tableRow.submenu!] {
            XCTAssertFalse(sub.items.contains { $0.title == "Show in Inspector" })
        }
    }

    // MARK: - Sidebar Item

    func testSidebarItemSubmenuListsEverySidebarItemActionSectionWithNilTargets() throws {
        let menu = try submenu("Selection", in: mainMenu())
        let sub = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.selectionSidebarItem, in: menu).submenu)

        let expected = SidebarItemAction.menuSections.flatMap { $0 }
        let listed = sub.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(listed.map(\.title), expected.map(\.menuBarTitle))
        XCTAssertEqual(sub.items.filter(\.isSeparatorItem).count, SidebarItemAction.menuSections.count - 1)

        for action in expected {
            let menuItem = try item(identifier: MainMenuAccessibilityID.selectionSidebarItemAction(action), in: sub)
            XCTAssertEqual(menuItem.action, action.menuSelector, action.rawValue)
            XCTAssertNil(menuItem.target, "\(action) must go to the first responder")
            if let chord = action.keyEquivalent {
                XCTAssertEqual(menuItem.keyEquivalent, chord.key, action.rawValue)
                XCTAssertEqual(menuItem.keyEquivalentModifierMask, chord.modifiers, action.rawValue)
            } else {
                XCTAssertEqual(menuItem.keyEquivalent, "", action.rawValue)
            }
        }
    }

    func testHoistedSidebarChordsMatchTheOwnerDecision() {
        XCTAssertEqual(SidebarItemAction.newFolder.keyEquivalent, RowCommandKeyEquivalent("n", [.command, .shift]))
        XCTAssertEqual(SidebarItemAction.duplicate.keyEquivalent, RowCommandKeyEquivalent("d", [.command]))
        XCTAssertEqual(SidebarItemAction.moveToTrash.keyEquivalent, RowCommandKeyEquivalent("\u{8}", [.command]))
        XCTAssertEqual(SidebarItemAction.showInInspector.keyEquivalent, RowCommandKeyEquivalent("s", [.command, .option]))
        XCTAssertEqual(
            SidebarItemAction.showInInspector.menuSelector,
            #selector(ResultRowMenuActions.showSelectedRowInInspector(_:)),
            "the sidebar shares the one Show in Inspector item"
        )
        XCTAssertEqual(
            SidebarItemAction.selectSiblings.keyEquivalent, RowCommandKeyEquivalent("a", [.command, .shift]),
            "Cmd-Shift-A stays with Select Siblings (owner decision, 2026-09-30)"
        )
        let chorded = SidebarItemAction.allCases.filter { $0.keyEquivalent != nil }
        XCTAssertEqual(Set(chorded), [.newFolder, .duplicate, .moveToTrash, .selectSiblings, .showInInspector])
    }

    // MARK: - Genotype Sample and Genotype Call

    /// U2. The genotype review commands act on the selected sample or call, so
    /// they are Selection commands. They follow Tree Node, above the shared
    /// Show in Inspector.
    func testSelectionMenuHoldsGenotypeSampleAndGenotypeCallAfterTreeNode() throws {
        let menu = try submenu("Selection", in: mainMenu())
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }, [
            "Sidebar Item", "Table Row", "Tree Node", "Genotype Sample", "Genotype Call", "-", "Show in Inspector",
        ])
        let sample = try item(identifier: MainMenuAccessibilityID.selectionGenotypeSample, in: menu)
        XCTAssertEqual(sample.identifier?.rawValue, "selection-menu-genotype-sample")
        XCTAssertEqual(sample.title, "Genotype Sample")
        let call = try item(identifier: MainMenuAccessibilityID.selectionGenotypeCall, in: menu)
        XCTAssertEqual(call.identifier?.rawValue, "selection-menu-genotype-call")
        XCTAssertEqual(call.title, "Genotype Call")

        let tools = try submenu("Tools", in: mainMenu())
        XCTAssertNil(tools.items.first { $0.title == "Genotype Review" }, "Tools no longer holds the review commands")
    }

    func testGenotypeSampleSubmenuKeepsTheReviewSelectorsAndChords() throws {
        let menu = try submenu("Selection", in: mainMenu())
        let sample = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.selectionGenotypeSample, in: menu).submenu)
        let expected: [(String, String, NSEvent.ModifierFlags, Selector)] = [
            ("Mark Sample Reviewed", "r", [.command], #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:))),
            ("Mark Sample Confirmed", "k", [.command], #selector(GenotypeResultViewController.markSelectedSampleConfirmed(_:))),
            ("Flag Sample for Review", "f", [.command, .shift], #selector(GenotypeResultViewController.flagSelectedSampleNeedsReview(_:))),
            ("Sample Detail\u{2026}", "o", [.command, .shift], #selector(GenotypeResultViewController.openSelectedSampleDetail(_:))),
        ]
        XCTAssertEqual(sample.items.map(\.title), expected.map(\.0), "four commands and no separator")
        for (index, (title, key, modifiers, action)) in expected.enumerated() {
            let menuItem = sample.items[index]
            XCTAssertEqual(menuItem.keyEquivalent, key, title)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask, modifiers, title)
            XCTAssertEqual(menuItem.action, action, title)
            XCTAssertNil(menuItem.target, "\(title) must dispatch through the responder chain")
        }
    }

    func testGenotypeCallSubmenuKeepsTheMatrixSelectorsAndChords() throws {
        let menu = try submenu("Selection", in: mainMenu())
        let call = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.selectionGenotypeCall, in: menu).submenu)
        let expected: [(String, String, NSEvent.ModifierFlags, Selector)] = [
            ("Mark False Positive", "p", [.command, .option], #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:))),
            ("Mark False Negative", "x", [.command, .option], #selector(GenotypeMatrixReviewMenuActions.markSelectionFalseNegative(_:))),
            ("Clear Review", "r", [.command, .option], #selector(GenotypeMatrixReviewMenuActions.clearSelectionReview(_:))),
            ("Edit Comment\u{2026}", "", [], #selector(GenotypeMatrixReviewMenuActions.editSelectionComment(_:))),
            ("Remove Comments", "", [], #selector(GenotypeMatrixReviewMenuActions.removeSelectionComments(_:))),
        ]
        XCTAssertEqual(call.items.map(\.title), expected.map(\.0), "five commands and no separator")
        for (index, (title, key, modifiers, action)) in expected.enumerated() {
            let menuItem = call.items[index]
            XCTAssertEqual(menuItem.keyEquivalent, key, title)
            if !key.isEmpty { XCTAssertEqual(menuItem.keyEquivalentModifierMask, modifiers, title) }
            XCTAssertEqual(menuItem.action, action, title)
            XCTAssertNil(menuItem.target, "\(title) must dispatch through the responder chain")
        }
    }

    /// With no genotype result focused, nothing answers the genotype commands.
    func testGenotypeItemsAreDisabledWithNothingFocused() throws {
        let menu = try submenu("Selection", in: mainMenu())
        for identifier in [MainMenuAccessibilityID.selectionGenotypeSample, MainMenuAccessibilityID.selectionGenotypeCall] {
            let sub = try XCTUnwrap(try item(identifier: identifier, in: menu).submenu)
            sub.update()
            for menuItem in sub.items where !menuItem.isSeparatorItem {
                XCTAssertFalse(menuItem.isEnabled, "\(menuItem.title) must be disabled with no genotype result focused")
            }
        }
    }

    func testSidebarItemActionsHaveDistinctSelectorsSlugsAndTitles() {
        let actions = SidebarItemAction.allCases
        XCTAssertEqual(Set(actions.map(\.menuSelector)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.identifierSlug)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.title)).count, actions.count)
        for action in actions {
            XCTAssertEqual(SidebarItemAction.command(for: action.menuSelector), action)
        }
    }

    // MARK: - Table Row

    func testTableRowSubmenuListsEveryResultRowCommandSectionWithNilTargets() throws {
        let menu = try submenu("Selection", in: mainMenu())
        let sub = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.selectionTableRow, in: menu).submenu)

        let expected = ResultRowCommand.menuSections.flatMap { $0 }
        XCTAssertFalse(expected.contains(.showInInspector))
        XCTAssertEqual(sub.items.filter { !$0.isSeparatorItem }.map(\.title), expected.map(\.menuBarTitle))

        for command in expected {
            let menuItem = try item(identifier: MainMenuAccessibilityID.selectionTableRowAction(command), in: sub)
            XCTAssertEqual(menuItem.action, command.menuSelector, command.rawValue)
            XCTAssertNil(menuItem.target, "\(command) must go to the first responder")
            XCTAssertEqual(menuItem.keyEquivalent, "", "\(command) has no chord")
        }
        XCTAssertEqual(Set(ResultRowCommand.allCases.map(\.menuSelector)).count, ResultRowCommand.allCases.count)
        XCTAssertEqual(Set(ResultRowCommand.allCases.map(\.identifierSlug)).count, ResultRowCommand.allCases.count)
    }

    func testTableRowItemsAreDisabledWithNothingFocused() throws {
        // A fresh menu with no key window: nil-target items with no responder
        // that implements the selector validate as disabled.
        let menu = try submenu("Selection", in: mainMenu())
        let sub = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.selectionTableRow, in: menu).submenu)
        sub.update()
        for menuItem in sub.items where !menuItem.isSeparatorItem {
            XCTAssertFalse(menuItem.isEnabled, "\(menuItem.title) must be disabled with no table focused")
        }
    }

    // MARK: - Retargeted View items

    func testExpandAllAndCollapseAllTargetTheSharedOutlineProtocol() throws {
        let view = try submenu("View", in: mainMenu())
        let expand = try item(identifier: MainMenuAccessibilityID.expandAll, in: view)
        XCTAssertEqual(expand.title, "Expand All")
        XCTAssertEqual(expand.action, #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)))
        XCTAssertNil(expand.target)
        let collapse = try item(identifier: MainMenuAccessibilityID.collapseAll, in: view)
        XCTAssertEqual(collapse.title, "Collapse All")
        XCTAssertEqual(collapse.action, #selector(OutlineExpandCollapseActions.collapseAllOutlineItems(_:)))
        XCTAssertNil(collapse.target)

        // The taxonomy table keeps answering the two View items.
        XCTAssertTrue(TaxonomyViewController.instancesRespond(to: #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:))))
        XCTAssertTrue(TaxonomyViewController.instancesRespond(to: #selector(OutlineExpandCollapseActions.collapseAllOutlineItems(_:))))
    }

    // MARK: - Nil-target items for the lanes that follow

    func testViewMenuOffersToggleAnnotationsForSelectedTrack() throws {
        let view = try submenu("View", in: mainMenu())
        let toggle = try item(identifier: MainMenuAccessibilityID.toggleAnnotationsForSelectedTrack, in: view)
        XCTAssertEqual(toggle.title, "Show Annotations for Selected Track", "the viewer switches it between Show and Hide")
        XCTAssertEqual(toggle.action, #selector(TrackHeaderMenuActions.toggleAnnotationsForSelectedTrack(_:)))
        XCTAssertNil(toggle.target)
        XCTAssertEqual(toggle.keyEquivalent, "")
    }

    func testSequenceMenuOffersAddEditAndDeleteAnnotation() throws {
        let sequence = try submenu("Sequence", in: mainMenu())
        let add = try item(identifier: MainMenuAccessibilityID.addAnnotation, in: sequence)
        XCTAssertEqual(add.title, "Add Annotation\u{2026}")
        XCTAssertEqual(add.action, #selector(SequenceMenuActions.addAnnotation(_:)))
        let edit = try item(identifier: MainMenuAccessibilityID.editAnnotation, in: sequence)
        XCTAssertEqual(edit.title, "Edit Annotation\u{2026}")
        XCTAssertEqual(edit.action, #selector(AnnotationEditingMenuActions.editAnnotation(_:)))
        XCTAssertNil(edit.target)
        let delete = try item(identifier: MainMenuAccessibilityID.deleteAnnotation, in: sequence)
        XCTAssertEqual(delete.title, "Delete Annotation", "acts on the selection, so no ellipsis")
        XCTAssertEqual(delete.action, #selector(AnnotationEditingMenuActions.deleteAnnotation(_:)))
        XCTAssertNil(delete.target)

        let titles = sequence.items.map(\.title)
        let addIndex = try XCTUnwrap(titles.firstIndex(of: add.title))
        XCTAssertEqual(titles[addIndex + 1], edit.title)
        XCTAssertEqual(titles[addIndex + 2], delete.title)
    }

    func testFileExportOffersTheTwelveSResultSheet() throws {
        let file = try submenu("File", in: mainMenu())
        let export = try XCTUnwrap(try item(identifier: MainMenuAccessibilityID.export, in: file).submenu)
        let twelveS = try item(identifier: MainMenuAccessibilityID.exportTwelveSResult, in: export)
        XCTAssertEqual(twelveS.title, "12S Result\u{2026}", "opens the format sheet, so it takes an ellipsis")
        XCTAssertEqual(twelveS.action, #selector(TwelveSResultMenuActions.exportTwelveSResult(_:)))
        XCTAssertNil(twelveS.target)
    }

    // MARK: - HIG

    func testEveryNewTitleUsesTheSingleEllipsisCharacterAndTitleCase() throws {
        let menu = mainMenu()
        var titles: [String] = []
        func collect(_ menu: NSMenu) {
            for menuItem in menu.items where !menuItem.isSeparatorItem {
                titles.append(menuItem.title)
                if let sub = menuItem.submenu { collect(sub) }
            }
        }
        collect(try submenu("Selection", in: menu))
        titles += SidebarItemAction.allCases.map(\.title) + ResultRowCommand.allCases.map(\.title)
        // Apple style: articles, coordinating conjunctions and prepositions of
        // three letters or fewer stay lowercase inside a title. "with" is
        // LGE house style, from the established "Verify with BLAST…" title
        // every surface shares.
        let smallWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        for title in titles {
            XCTAssertFalse(title.contains("..."), "\(title) must use U+2026")
            let words = title.replacingOccurrences(of: "\u{2026}", with: "")
                .split(separator: " ")
                .map { $0.drop { "([".contains($0) } }
                .map(String.init)
            for (index, word) in words.enumerated() where index > 0 && !smallWords.contains(word) {
                XCTAssertTrue(word.first?.isUppercase == true || word.first?.isNumber == true, "\(title) is not title case at '\(word)'")
            }
            XCTAssertTrue(words.first?.first?.isUppercase == true || words.first?.first?.isNumber == true, "\(title) must start capitalised")
        }
    }
}
