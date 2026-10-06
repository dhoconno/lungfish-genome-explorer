// MainMenu+GenotypeReview.swift - Genotype Review submenu builder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishGenotypeUI

extension MainMenu {
    // MARK: - Genotype Review Submenu

    /// The genotype review commands (`⌘R`, `⌘K`, `⇧⌘F`, `⇧⌘O`) and the
    /// matrix's Selected Cell commands (`⌥⌘P`, `⌥⌘X`, `⌥⌘R`).
    ///
    /// These were previously implemented only as a
    /// `GenotypeResultViewController.performKeyEquivalent` override, which
    /// AppKit never reaches: key equivalents are dispatched down the view
    /// hierarchy, not to view controllers. Real menu items with a nil target
    /// reach the controller through the responder chain and auto-disable
    /// (via its `validateMenuItem`) when no reviewable sample is selected,
    /// matching the TaxTriage sample-stepping items in the View menu.
    static func createGenotypeReviewMenuItem() -> NSMenuItem {
        let reviewItem = NSMenuItem(title: "Genotype Review", action: nil, keyEquivalent: "")
        reviewItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.genotypeReviewMenu)
        let reviewMenu = NSMenu(title: reviewItem.title)

        let reviewedItem = reviewMenu.addItem(
            withTitle: "Mark Sample Reviewed",
            action: #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:)),
            keyEquivalent: "r"
        )
        reviewedItem.keyEquivalentModifierMask = [.command]

        let confirmedItem = reviewMenu.addItem(
            withTitle: "Mark Sample Confirmed",
            action: #selector(GenotypeResultViewController.markSelectedSampleConfirmed(_:)),
            keyEquivalent: "k"
        )
        confirmedItem.keyEquivalentModifierMask = [.command]

        let flagItem = reviewMenu.addItem(
            withTitle: "Flag Sample for Review",
            action: #selector(GenotypeResultViewController.flagSelectedSampleNeedsReview(_:)),
            keyEquivalent: "f"
        )
        flagItem.keyEquivalentModifierMask = [.command, .shift]

        let detailItem = reviewMenu.addItem(
            withTitle: "Sample Detail\u{2026}",
            action: #selector(GenotypeResultViewController.openSelectedSampleDetail(_:)),
            keyEquivalent: "o"
        )
        detailItem.keyEquivalentModifierMask = [.command, .shift]

        // Selected Cell: the matrix review commands. They carry the matrix's
        // own chords (⌥⌘P, ⌥⌘X, ⌥⌘R) and are enabled only while the
        // genotype matrix has the keyboard focus and a selection. Edit
        // Comment stays unbound because ⌥⌘M is macOS's Minimize All.
        reviewMenu.addItem(.separator())
        let selectedCellItem = NSMenuItem(title: "Selected Cell", action: nil, keyEquivalent: "")
        selectedCellItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.genotypeSelectedCellMenu)
        let selectedCellMenu = NSMenu(title: selectedCellItem.title)
        let cellCommands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Mark False Positive", #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:)), "p", [.command, .option]),
            ("Mark False Negative", #selector(GenotypeMatrixReviewMenuActions.markSelectionFalseNegative(_:)), "x", [.command, .option]),
            ("Clear Review", #selector(GenotypeMatrixReviewMenuActions.clearSelectionReview(_:)), "r", [.command, .option]),
            ("Edit Comment\u{2026}", #selector(GenotypeMatrixReviewMenuActions.editSelectionComment(_:)), "", []),
            ("Remove Comments", #selector(GenotypeMatrixReviewMenuActions.removeSelectionComments(_:)), "", []),
        ]
        for (title, selector, key, modifiers) in cellCommands {
            let item = selectedCellMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        }
        selectedCellItem.submenu = selectedCellMenu
        reviewMenu.addItem(selectedCellItem)

        reviewItem.submenu = reviewMenu
        return reviewItem
    }
}
