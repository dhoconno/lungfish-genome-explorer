// MainMenu+GenotypeReview.swift - Selection > Genotype Sample and Genotype Call submenus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishGenotypeUI

extension MainMenu {
    // MARK: - Genotype Sample and Genotype Call Submenus

    /// Selection > Genotype Sample, the commands that review the sample selected
    /// in a genotype result (`⌘R`, `⌘K`, `⇧⌘F`, `⇧⌘O`).
    ///
    /// These were previously implemented only as a
    /// `GenotypeResultViewController.performKeyEquivalent` override, which
    /// AppKit never reaches: key equivalents are dispatched down the view
    /// hierarchy, not to view controllers. Real menu items with a nil target
    /// reach the controller through the responder chain and auto-disable
    /// (via its `validateMenuItem`) when no reviewable sample is selected,
    /// matching the TaxTriage sample-stepping items in the View menu.
    static func makeGenotypeSampleMenuItem() -> NSMenuItem {
        let sampleItem = NSMenuItem(title: "Genotype Sample", action: nil, keyEquivalent: "")
        sampleItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.selectionGenotypeSample)
        let sampleMenu = NSMenu(title: sampleItem.title)

        let reviewedItem = sampleMenu.addItem(
            withTitle: "Mark Sample Reviewed",
            action: #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:)),
            keyEquivalent: "r"
        )
        reviewedItem.keyEquivalentModifierMask = [.command]

        let confirmedItem = sampleMenu.addItem(
            withTitle: "Mark Sample Confirmed",
            action: #selector(GenotypeResultViewController.markSelectedSampleConfirmed(_:)),
            keyEquivalent: "k"
        )
        confirmedItem.keyEquivalentModifierMask = [.command]

        let flagItem = sampleMenu.addItem(
            withTitle: "Flag Sample for Review",
            action: #selector(GenotypeResultViewController.flagSelectedSampleNeedsReview(_:)),
            keyEquivalent: "f"
        )
        flagItem.keyEquivalentModifierMask = [.command, .shift]

        let detailItem = sampleMenu.addItem(
            withTitle: "Sample Detail\u{2026}",
            action: #selector(GenotypeResultViewController.openSelectedSampleDetail(_:)),
            keyEquivalent: "o"
        )
        detailItem.keyEquivalentModifierMask = [.command, .shift]

        sampleItem.submenu = sampleMenu
        return sampleItem
    }

    /// Selection > Genotype Call, the matrix review commands for the call
    /// selected in the genotype matrix. They carry the matrix's own chords
    /// (`⌥⌘P`, `⌥⌘X`, `⌥⌘R`) and are enabled only while the genotype matrix
    /// has the keyboard focus and a selection. Edit Comment stays unbound
    /// because `⌥⌘M` is macOS's Minimize All. They are real nil-target menu
    /// items for the same reason the Genotype Sample commands are.
    static func makeGenotypeCallMenuItem() -> NSMenuItem {
        let callItem = NSMenuItem(title: "Genotype Call", action: nil, keyEquivalent: "")
        callItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.selectionGenotypeCall)
        let callMenu = NSMenu(title: callItem.title)

        let callCommands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Mark False Positive", #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:)), "p", [.command, .option]),
            ("Mark False Negative", #selector(GenotypeMatrixReviewMenuActions.markSelectionFalseNegative(_:)), "x", [.command, .option]),
            ("Clear Review", #selector(GenotypeMatrixReviewMenuActions.clearSelectionReview(_:)), "r", [.command, .option]),
            ("Edit Comment\u{2026}", #selector(GenotypeMatrixReviewMenuActions.editSelectionComment(_:)), "", []),
            ("Remove Comments", #selector(GenotypeMatrixReviewMenuActions.removeSelectionComments(_:)), "", []),
        ]
        for (title, selector, key, modifiers) in callCommands {
            let item = callMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        }

        callItem.submenu = callMenu
        return callItem
    }
}
