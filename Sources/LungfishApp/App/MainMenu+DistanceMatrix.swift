// MainMenu+DistanceMatrix.swift - View and File menu items for the MSA distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Distance matrix commands (rulings U2 and U8). The targets are nil: the
/// grid answers them while it has focus, and the main window controller
/// forwards them to the MSA viewport's grid otherwise.
@MainActor
@objc protocol DistanceMatrixMenuActions {
    func toggleDistanceMatrix(_ sender: Any?)
    func showDistanceMatrix(_ sender: Any?)
    func revealPairInAlignment(_ sender: Any?)
    func selectRowSequences(_ sender: Any?)
    func copyMatrix(_ sender: Any?)
    func exportDistanceMatrix(_ sender: Any?)
}

enum DistanceMatrixMenuID {
    static let toggle = "view-menu-toggle-distance-matrix"
    static let submenu = "view-menu-distance-matrix"
    static let reveal = "view-menu-distance-matrix-reveal-pair"
    static let selectRow = "view-menu-distance-matrix-select-row-sequences"
    static let copyMatrix = "view-menu-distance-matrix-copy-matrix"
    static let export = "view-menu-distance-matrix-export"
    static let fileExport = "file-menu-export-distance-matrix"
}

extension MainMenu {
    /// View > Show Distance Matrix (Control-Command-M) and the View >
    /// Distance Matrix submenu with the matrix commands.
    static func addDistanceMatrixItems(to viewMenu: NSMenu) {
        let toggleItem = viewMenu.addItem(
            withTitle: "Show Distance Matrix",
            action: #selector(DistanceMatrixMenuActions.toggleDistanceMatrix(_:)),
            keyEquivalent: "m"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .control]
        toggleItem.identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.toggle)

        let submenuItem = NSMenuItem(title: "Distance Matrix", action: nil, keyEquivalent: "")
        submenuItem.identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.submenu)
        let submenu = NSMenu(title: "Distance Matrix")
        submenu.addItem(
            withTitle: "Reveal Pair in Alignment",
            action: #selector(DistanceMatrixMenuActions.revealPairInAlignment(_:)),
            keyEquivalent: ""
        ).identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.reveal)
        submenu.addItem(
            withTitle: "Select Row's Sequences",
            action: #selector(DistanceMatrixMenuActions.selectRowSequences(_:)),
            keyEquivalent: ""
        ).identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.selectRow)
        submenu.addItem(
            withTitle: "Copy Matrix",
            action: #selector(DistanceMatrixMenuActions.copyMatrix(_:)),
            keyEquivalent: ""
        ).identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.copyMatrix)
        submenu.addItem(
            withTitle: "Export Matrix as TSV\u{2026}",
            action: #selector(DistanceMatrixMenuActions.exportDistanceMatrix(_:)),
            keyEquivalent: ""
        ).identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.export)
        submenuItem.submenu = submenu
        viewMenu.addItem(submenuItem)
    }

    /// File > Export > Distance Matrix (TSV)…
    static func distanceMatrixExportItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Distance Matrix (TSV)\u{2026}",
            action: #selector(DistanceMatrixMenuActions.exportDistanceMatrix(_:)),
            keyEquivalent: ""
        )
        item.identifier = NSUserInterfaceItemIdentifier(DistanceMatrixMenuID.fileExport)
        return item
    }
}
