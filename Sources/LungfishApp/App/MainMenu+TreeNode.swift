// MainMenu+TreeNode.swift - Selection > Tree Node submenu and the Build Tree item the Tools layout places
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishPhylogeneticsUI

extension MainMenu {
    /// Selection > Tree Node, the menu-bar twins of the tree node context menu.
    static func makeTreeNodeMenuItem() -> NSMenuItem {
        let treeNodeItem = NSMenuItem(title: "Tree Node", action: nil, keyEquivalent: "")
        treeNodeItem.identifier = NSUserInterfaceItemIdentifier("selection-menu-tree-node")
        let treeNodeMenu = NSMenu(title: treeNodeItem.title)
        for (index, section) in PhylogeneticTreeViewController.nodeMenuBarSections.enumerated() {
            if index > 0 { treeNodeMenu.addItem(.separator()) }
            for command in section {
                // Nil target: the tree view controller validates and performs these
                // through the responder chain while its node table or canvas has focus.
                let item = NSMenuItem(title: command.title, action: command.selector, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier("selection-menu-tree-node-\(command.identifierSlug)")
                treeNodeMenu.addItem(item)
            }
        }
        treeNodeItem.submenu = treeNodeMenu
        return treeNodeItem
    }

    /// IQ-TREE is not in the FASTQ dialog family because its input is a .lungfishmsa,
    /// so the item is hand-written rather than built from FASTQOperationToolID.
    /// `ToolsMenuLayout` places it as the trailing command of the alignment entry.
    static func makeBuildTreeItem() -> NSMenuItem {
        let buildTreeItem = NSMenuItem(
            title: "Build Tree with IQ-TREE\u{2026}",
            action: #selector(ToolsMenuActions.showIQTreeInference(_:)),
            keyEquivalent: ""
        )
        buildTreeItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.buildTreeIQTree)
        return buildTreeItem
    }
}
