// MainMenu+Tools.swift - The Tools menu, built from ToolsMenuLayout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

extension MainMenu {
    // MARK: - Tools Menu

    /// Tools, built from `ToolsMenuLayout`. A separator sits between two
    /// groups, and in every submenu between two sections that are not empty.
    static func createToolsMenu(
        workflowLibraryEnablementStore: WorkflowLibraryEnablementStore,
        workflowPackageStore: WorkflowLibraryImportedPackageStore
    ) -> NSMenuItem {
        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsMenuItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.toolsMenu)
        let toolsMenu = NSMenu(title: "Tools")

        let model = ToolsMenuModel.build(
            isEnabled: { workflowLibraryEnablementStore.isWorkflowEnabled($0) },
            linkedPackages: workflowPackageStore.validatedPackages(),
            isPackageEnabled: { workflowLibraryEnablementStore.isUserWorkflowEnabled($0) }
        )
        addSections(
            ToolsMenuLayout.groups.map { group in group.map { menuItem(for: $0, model: model) } },
            to: toolsMenu
        )

        toolsMenuItem.submenu = toolsMenu
        return toolsMenuItem
    }

    /// Adds every section that has items, one after another, with a separator
    /// between two sections. A section with no items adds nothing, so no menu
    /// starts or ends with a separator and none holds two in a row.
    static func addSections(_ sections: [[NSMenuItem]], to menu: NSMenu) {
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem(_:))
        }
    }

    private static func menuItem(for entry: ToolsMenuLayout.Entry, model: ToolsMenuModel) -> NSMenuItem {
        switch entry {
        case .category(let categoryID, let leading, let trailing):
            let category = model.categories.first { $0.id == categoryID }
                ?? ToolsMenuModel.Category(id: categoryID, title: categoryID.displayName, workflows: [])
            return categoryToolsMenuItem(for: category, leading: leading, trailing: trailing)
        case .primerDesign:
            return primerDesignMenuItem()
        case .workflows:
            return workflowsMenuItem(for: model.linkedPackages)
        case .pluginManager:
            return pluginManagerMenuItem()
        }
    }

    // MARK: - Category submenus

    /// One category submenu in three sections. The leading fixed commands and
    /// the generated tools come first, the catalog workflows follow, and the
    /// trailing fixed commands come last.
    private static func categoryToolsMenuItem(
        for category: ToolsMenuModel.Category,
        leading: [ToolsMenuLayout.FixedCommand],
        trailing: [ToolsMenuLayout.FixedCommand]
    ) -> NSMenuItem {
        let categoryItem = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
        categoryItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.toolsCategory(category.id))
        let categoryMenu = NSMenu(title: category.title)

        addSections(
            [
                leading.map(fixedCommandMenuItem(for:)) + operationMenuItems(for: category.id),
                category.workflows.map(workflowMenuItem(for:)),
                trailing.map(fixedCommandMenuItem(for:)),
            ],
            to: categoryMenu
        )

        categoryItem.submenu = categoryMenu
        return categoryItem
    }

    /// The generated read tools of a category. A tool that is also a catalog
    /// workflow is built with the workflows instead.
    private static func operationMenuItems(for categoryID: FASTQOperationCategoryID) -> [NSMenuItem] {
        FASTQOperationDialogState.toolIDs(for: categoryID)
            .filter { toolID in
                WorkflowLibraryCatalog.item(for: toolID)?.capabilities.contains(.workflowOperations) != true
            }
            .map { toolID in
                let item = NSMenuItem(
                    title: "\(toolID.title)\u{2026}",
                    action: #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = toolID
                item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.toolsTool(toolID))
                return item
            }
    }

    private static func fixedCommandMenuItem(for command: ToolsMenuLayout.FixedCommand) -> NSMenuItem {
        switch command {
        case .callVariants:
            let item = NSMenuItem(
                title: "Call Variants\u{2026}",
                action: #selector(ToolsMenuActions.showBAMVariantCalling(_:)),
                keyEquivalent: ""
            )
            item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.callVariants)
            return item
        case .haplotypeDefinitions:
            // Always built. Menu validation disables it, and never hides it, while no
            // enabled workflow uses haplotype definitions.
            let item = NSMenuItem(
                title: "MHC Haplotype Definitions\u{2026}",
                action: #selector(ToolsMenuActions.showHaplotypeDefinitions(_:)),
                keyEquivalent: ""
            )
            item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.haplotypeDefinitions)
            return item
        case .buildTree:
            return makeBuildTreeItem()
        }
    }

    /// What a dimmed MHC Haplotype Definitions… item says turns it on.
    static let haplotypeDefinitionsDisabledToolTip =
        "Enable an MHC genotyping workflow in the Workflow Library to manage haplotype definitions."

    /// Menu validation for MHC Haplotype Definitions…. The item is never
    /// hidden. While no enabled workflow uses haplotype definitions it is
    /// disabled and its tooltip says why.
    static func validateHaplotypeDefinitionsItem(_ item: NSMenuItem, available: Bool) -> Bool {
        item.toolTip = available ? nil : haplotypeDefinitionsDisabledToolTip
        return available
    }

    // MARK: - Workflows

    /// Tools > Workflows holds one item per linked workflow package, then the Workflow Library.
    ///
    /// With no linked packages the submenu holds only "Workflow Library…".
    static func workflowsMenuItem(for packages: [ToolsMenuModel.LinkedPackageEntry]) -> NSMenuItem {
        let workflowsItem = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
        workflowsItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.workflows)
        let workflowsMenu = NSMenu(title: "Workflows")

        let workflowLibraryItem = NSMenuItem(
            title: "Workflow Library\u{2026}",
            action: #selector(ToolsMenuActions.showWorkflowLibrary(_:)),
            keyEquivalent: ""
        )
        workflowLibraryItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.workflowLibrary)

        addSections([packages.map(linkedPackageMenuItem(for:)), [workflowLibraryItem]], to: workflowsMenu)

        workflowsItem.submenu = workflowsMenu
        return workflowsItem
    }

    /// A linked package that is enabled launches. One that is not enabled reads
    /// "Enable <name>…" in normal type and reveals its card in the Workflow
    /// Library, where it is enabled.
    private static func linkedPackageMenuItem(for package: ToolsMenuModel.LinkedPackageEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: package.menuTitle,
            action: package.isEnabled
                ? #selector(ToolsMenuActions.launchLinkedWorkflowPackageFromMenu(_:))
                : #selector(ToolsMenuActions.revealLinkedWorkflowPackageInLibrary(_:)),
            keyEquivalent: ""
        )
        item.representedObject = package.manifestID
        item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.workflowPackage(package.manifestID))
        return item
    }

    /// A catalog workflow that is enabled launches. One that is not enabled
    /// reads "Enable <title>…" in normal type and asks to open the Workflow
    /// Library, which `enableWorkflowAlert(for:)` words from the catalog.
    private static func workflowMenuItem(for workflow: ToolsMenuModel.WorkflowEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: workflow.menuTitle,
            action: workflow.isEnabled
                ? #selector(ToolsMenuActions.launchWorkflowFromMenu(_:))
                : #selector(ToolsMenuActions.promptEnableWorkflowFromMenu(_:)),
            keyEquivalent: ""
        )
        item.representedObject = workflow.representedObject
        item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.toolsWorkflow(workflow.id))
        return item
    }

    /// The alert behind an "Enable <title>…" item. It names the workflow from
    /// the catalog item the menu item represents and never from the item's
    /// title. It is nil when the represented object names no catalog item.
    static func enableWorkflowAlert(for representedObject: Any?) -> NSAlert? {
        guard let workflow = ToolsMenuModel.catalogItem(forRepresentedObject: representedObject) else { return nil }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable \u{201C}\(workflow.title)\u{201D}?"
        alert.informativeText = "This workflow is available but not yet enabled. Enable it in the Workflow Library?"
        alert.addButton(withTitle: "Open Workflow Library")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    // MARK: - Primer design and plug-ins

    private static func primerDesignMenuItem() -> NSMenuItem {
        let primerDesignItem = NSMenuItem(title: "PCR Primer Design", action: nil, keyEquivalent: "")
        primerDesignItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.pcrPrimerDesign)
        let primerDesignMenu = NSMenu(title: primerDesignItem.title)
        for engine in PrimerDesignEngine.allCases {
            let item = primerDesignMenu.addItem(
                withTitle: "\(engine.rawValue)\u{2026}",
                action: #selector(ToolsMenuActions.showPCRPrimerDesign(_:)),
                keyEquivalent: ""
            )
            item.representedObject = engine
            item.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.pcrPrimerDesignEngine(engine))
        }
        primerDesignItem.submenu = primerDesignMenu
        return primerDesignItem
    }

    /// Plugin Manager (Cmd-Shift-B for "Bioconda").
    private static func pluginManagerMenuItem() -> NSMenuItem {
        let pluginItem = NSMenuItem(
            title: "Plugin Manager\u{2026}",
            action: #selector(ToolsMenuActions.showPluginManager(_:)),
            keyEquivalent: "b"
        )
        pluginItem.keyEquivalentModifierMask = [.command, .shift]
        pluginItem.identifier = NSUserInterfaceItemIdentifier(MainMenuAccessibilityID.pluginManager)
        return pluginItem
    }
}
