// MainMenu.swift - Application menu bar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)
// Reference: Apple Human Interface Guidelines

import AppKit
import UniformTypeIdentifiers

/// Builds the application's main menu bar programmatically.
///
/// Following Apple HIG, the menu structure is:
/// - Application menu (Lungfish)
/// - File menu
/// - Edit menu
/// - View menu
/// - Sequence menu
/// - Tools menu
/// - Window menu
/// - Help menu
@MainActor
public final class MainMenu {

    /// Creates and returns the main menu bar.
    public static func createMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // Application menu
        mainMenu.addItem(createApplicationMenu())

        // File menu
        mainMenu.addItem(createFileMenu())

        // Edit menu
        mainMenu.addItem(createEditMenu())

        // View menu
        mainMenu.addItem(createViewMenu())

        // Sequence menu
        mainMenu.addItem(createSequenceMenu())

        // Tools menu
        mainMenu.addItem(createToolsMenu())

        // Operations menu
        mainMenu.addItem(createOperationsMenu())

        // Window menu
        mainMenu.addItem(createWindowMenu())

        // Help menu
        mainMenu.addItem(createHelpMenu())

        return mainMenu
    }

    // MARK: - Application Menu

    private static func createApplicationMenu() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        // About
        appMenu.addItem(
            withTitle: "About Lungfish Genome Explorer",
            action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: ""
        )

        appMenu.addItem(.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(AppDelegate.showPreferences(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(prefsItem)

        appMenu.addItem(.separator())

        // Services submenu
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())

        // Hide/Show/Quit
        appMenu.addItem(
            withTitle: "Hide Lungfish Genome Explorer",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )

        appMenu.addItem(.separator())

        appMenu.addItem(
            withTitle: "Quit Lungfish Genome Explorer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    // MARK: - File Menu

    private static func createFileMenu() -> NSMenuItem {
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        // New
        fileMenu.addItem(
            withTitle: "New Project",
            action: #selector(AppDelegate.newDocument(_:)),
            keyEquivalent: "n"
        )

        // Open
        fileMenu.addItem(
            withTitle: "Open...",
            action: #selector(AppDelegate.openDocument(_:)),
            keyEquivalent: "o"
        )

        // Open Project Folder (Cmd-Shift-O)
        let openFolderItem = fileMenu.addItem(
            withTitle: "Open Project Folder...",
            action: #selector(AppDelegate.openProjectFolder(_:)),
            keyEquivalent: "o"
        )
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]

        // Open Recent submenu
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())

        // Close
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        // Save
        fileMenu.addItem(
            withTitle: "Save",
            action: #selector(NSDocument.save(_:)),
            keyEquivalent: "s"
        )

        let saveAsItem = fileMenu.addItem(
            withTitle: "Save As...",
            action: #selector(NSDocument.saveAs(_:)),
            keyEquivalent: "s"
        )
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(.separator())

        // Import submenu
        let importItem = NSMenuItem(title: "Import", action: nil, keyEquivalent: "")
        let importMenu = NSMenu(title: "Import")

        let importFilesItem = importMenu.addItem(
            withTitle: "Files\u{2026}",
            action: #selector(FileMenuActions.importFiles(_:)),
            keyEquivalent: "i"
        )
        importFilesItem.keyEquivalentModifierMask = [.command, .shift]

        // ONT Run import (no shortcut -- Cmd-Shift-O is used by Open Project Folder)
        importMenu.addItem(
            withTitle: "ONT Run\u{2026}",
            action: #selector(FileMenuActions.importONTRun(_:)),
            keyEquivalent: ""
        )

        importMenu.addItem(.separator())

        importMenu.addItem(
            withTitle: "VCF Variants\u{2026}",
            action: #selector(FileMenuActions.importVCFToBundle(_:)),
            keyEquivalent: ""
        )
        importMenu.addItem(
            withTitle: "BAM/CRAM Alignments\u{2026}",
            action: #selector(FileMenuActions.importBAMToBundle(_:)),
            keyEquivalent: ""
        )
        importMenu.addItem(
            withTitle: "Sample Metadata\u{2026}",
            action: #selector(FileMenuActions.importSampleMetadataToBundle(_:)),
            keyEquivalent: ""
        )

        importItem.submenu = importMenu
        fileMenu.addItem(importItem)

        // Export submenu
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "Export")

        // Sequence formats
        exportMenu.addItem(
            withTitle: "Sequences (FASTA/GenBank)\u{2026}",
            action: #selector(FileMenuActions.exportFASTA(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "Annotations (GFF3)\u{2026}",
            action: #selector(FileMenuActions.exportGFF3(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "FASTQ\u{2026}",
            action: #selector(FileMenuActions.exportFASTQ(_:)),
            keyEquivalent: ""
        )

        exportMenu.addItem(.separator())

        // Images
        exportMenu.addItem(
            withTitle: "Image (PNG)\u{2026}",
            action: #selector(FileMenuActions.exportImage(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "Image (PDF)\u{2026}",
            action: #selector(FileMenuActions.exportPDF(_:)),
            keyEquivalent: ""
        )

        exportMenu.addItem(.separator())

        // Provenance submenu
        let provenanceItem = NSMenuItem(title: "Provenance", action: nil, keyEquivalent: "")
        let provenanceMenu = NSMenu(title: "Provenance")

        provenanceMenu.addItem(
            withTitle: "Shell Script\u{2026}",
            action: #selector(FileMenuActions.exportProvenanceShell(_:)),
            keyEquivalent: ""
        )
        provenanceMenu.addItem(
            withTitle: "Python Script\u{2026}",
            action: #selector(FileMenuActions.exportProvenancePython(_:)),
            keyEquivalent: ""
        )
        provenanceMenu.addItem(
            withTitle: "Nextflow Pipeline\u{2026}",
            action: #selector(FileMenuActions.exportProvenanceNextflow(_:)),
            keyEquivalent: ""
        )
        provenanceMenu.addItem(
            withTitle: "Snakemake Workflow\u{2026}",
            action: #selector(FileMenuActions.exportProvenanceSnakemake(_:)),
            keyEquivalent: ""
        )
        provenanceMenu.addItem(.separator())
        provenanceMenu.addItem(
            withTitle: "Methods Section\u{2026}",
            action: #selector(FileMenuActions.exportProvenanceMethods(_:)),
            keyEquivalent: ""
        )
        provenanceMenu.addItem(
            withTitle: "Full Provenance (JSON)\u{2026}",
            action: #selector(FileMenuActions.exportProvenanceJSON(_:)),
            keyEquivalent: ""
        )

        provenanceItem.submenu = provenanceMenu
        exportMenu.addItem(provenanceItem)

        exportItem.submenu = exportMenu
        fileMenu.addItem(exportItem)

        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    // MARK: - Edit Menu

    private static func createEditMenu() -> NSMenuItem {
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        // Undo/Redo
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )

        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        editMenu.addItem(.separator())

        // Cut/Copy/Paste
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )

        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )

        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )

        editMenu.addItem(
            withTitle: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )

        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        editMenu.addItem(.separator())

        // Find submenu
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")

        findMenu.addItem(
            withTitle: "Find...",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        ).tag = NSTextFinder.Action.showFindInterface.rawValue

        findMenu.addItem(
            withTitle: "Find Next",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        ).tag = NSTextFinder.Action.nextMatch.rawValue

        // Find Previous (no shortcut -- Cmd-Shift-G is used by Go to Gene in Sequence menu)
        let findPrevItem = findMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: ""
        )
        findPrevItem.tag = NSTextFinder.Action.previousMatch.rawValue

        findItem.submenu = findMenu
        editMenu.addItem(findItem)

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    // MARK: - View Menu

    private static func createViewMenu() -> NSMenuItem {
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")

        // Sidebar toggle (Control-Command-S per macOS standard)
        // Apple HIG: Title should dynamically update to "Show Sidebar" / "Hide Sidebar"
        // Tag 1000 enables dynamic title updates in validateMenuItem
        let sidebarItem = viewMenu.addItem(
            withTitle: "Show Sidebar",
            action: #selector(ViewMenuActions.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        sidebarItem.tag = 1000  // Tag for dynamic title validation

        // Inspector toggle
        // Apple HIG: Title should dynamically update to "Show Inspector" / "Hide Inspector"
        let inspectorItem = viewMenu.addItem(
            withTitle: "Show Inspector",
            action: #selector(ViewMenuActions.toggleInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        inspectorItem.tag = 1001  // Tag to identify this menu item for validation

        viewMenu.addItem(.separator())

        // AI Assistant
        let aiItem = viewMenu.addItem(
            withTitle: "AI Assistant",
            action: #selector(ViewMenuActions.showAIAssistant(_:)),
            keyEquivalent: "a"
        )
        aiItem.keyEquivalentModifierMask = [.command, .shift]

        viewMenu.addItem(.separator())

        // Zoom controls
        viewMenu.addItem(
            withTitle: "Zoom In",
            action: #selector(ViewMenuActions.zoomIn(_:)),
            keyEquivalent: "+"
        )

        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(ViewMenuActions.zoomOut(_:)),
            keyEquivalent: "-"
        )

        viewMenu.addItem(
            withTitle: "Zoom to Fit",
            action: #selector(ViewMenuActions.zoomToFit(_:)),
            keyEquivalent: "0"
        )

        viewMenu.addItem(
            withTitle: "Zoom Reset (10kb)",
            action: #selector(ViewMenuActions.zoomReset(_:)),
            keyEquivalent: "1"
        )

        viewMenu.addItem(.separator())

        // DNA/RNA mode toggle
        let nucleotideModeItem = viewMenu.addItem(
            withTitle: "Show as RNA (U instead of T)",
            action: #selector(ViewMenuActions.toggleNucleotideMode(_:)),
            keyEquivalent: "u"
        )
        nucleotideModeItem.keyEquivalentModifierMask = [.command, .shift]
        nucleotideModeItem.tag = 1002  // Tag for validation/state

        viewMenu.addItem(.separator())

        // Reset View Settings
        viewMenu.addItem(
            withTitle: "Reset View Settings to Defaults",
            action: #selector(ViewMenuActions.resetViewSettingsToDefaults(_:)),
            keyEquivalent: ""
        )

        viewMenu.addItem(.separator())

        // Enter Full Screen
        let fullScreenItem = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    // MARK: - Sequence Menu

    private static func createSequenceMenu() -> NSMenuItem {
        let seqMenuItem = NSMenuItem(title: "Sequence", action: nil, keyEquivalent: "")
        let seqMenu = NSMenu(title: "Sequence")

        // Sequence operations
        seqMenu.addItem(
            withTitle: "Reverse Complement",
            action: #selector(SequenceMenuActions.reverseComplement(_:)),
            keyEquivalent: "r"
        ).keyEquivalentModifierMask = [.command, .shift]

        seqMenu.addItem(
            withTitle: "Translate...",
            action: #selector(SequenceMenuActions.translate(_:)),
            keyEquivalent: "t"
        ).keyEquivalentModifierMask = [.command, .shift]

        seqMenu.addItem(.separator())

        // Navigation operations (Command-L to avoid conflict with Find Next Command-G)
        seqMenu.addItem(
            withTitle: "Go to Position...",
            action: #selector(SequenceMenuActions.goToPosition(_:)),
            keyEquivalent: "l"
        )

        // Go to Gene (Cmd-Shift-G) - search annotations by gene name
        let goToGeneItem = seqMenu.addItem(
            withTitle: "Go to Gene...",
            action: #selector(SequenceMenuActions.goToGene(_:)),
            keyEquivalent: "g"
        )
        goToGeneItem.keyEquivalentModifierMask = [.command, .shift]

        seqMenu.addItem(.separator())

        // Visible-region extraction operations
        let copySelFASTAItem = seqMenu.addItem(
            withTitle: "Copy Visible Region as FASTA",
            action: #selector(SequenceMenuActions.copySelectionFASTA(_:)),
            keyEquivalent: "c"
        )
        copySelFASTAItem.keyEquivalentModifierMask = [.command, .shift]

        let extractSelItem = seqMenu.addItem(
            withTitle: "Extract Visible Region\u{2026}",
            action: #selector(SequenceMenuActions.extractSelection(_:)),
            keyEquivalent: "e"
        )
        extractSelItem.keyEquivalentModifierMask = [.command, .shift]

        seqMenu.addItem(.separator())

        // Annotation operations
        seqMenu.addItem(
            withTitle: "Add Annotation...",
            action: #selector(SequenceMenuActions.addAnnotation(_:)),
            keyEquivalent: ""
        )

        seqMenu.addItem(
            withTitle: "Find ORFs...",
            action: #selector(SequenceMenuActions.findORFs(_:)),
            keyEquivalent: ""
        )

        seqMenu.addItem(
            withTitle: "Find Restriction Sites...",
            action: #selector(SequenceMenuActions.findRestrictionSites(_:)),
            keyEquivalent: ""
        )

        seqMenuItem.submenu = seqMenu
        return seqMenuItem
    }

    // MARK: - Tools Menu

    private static func createToolsMenu() -> NSMenuItem {
        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu(title: "Tools")

        // Metagenomics Classification
        let classifyItem = toolsMenu.addItem(
            withTitle: "Classify \u{0026} Profile Reads\u{2026}",
            action: #selector(ToolsMenuActions.classifyReads(_:)),
            keyEquivalent: "k"
        )
        classifyItem.keyEquivalentModifierMask = [.command, .shift]

        toolsMenu.addItem(.separator())

        // Assembly
        toolsMenu.addItem(
            withTitle: "Assemble with SPAdes...",
            action: #selector(ToolsMenuActions.runSPAdes(_:)),
            keyEquivalent: ""
        )

        // Primer Design
        let primerItem = NSMenuItem(title: "Primer Design", action: nil, keyEquivalent: "")
        let primerMenu = NSMenu(title: "Primer Design")

        primerMenu.addItem(
            withTitle: "Design Primers...",
            action: #selector(ToolsMenuActions.designPrimers(_:)),
            keyEquivalent: ""
        )
        primerMenu.addItem(
            withTitle: "PrimalScheme Multiplex...",
            action: #selector(ToolsMenuActions.primalScheme(_:)),
            keyEquivalent: ""
        )
        primerMenu.addItem(
            withTitle: "In-Silico PCR...",
            action: #selector(ToolsMenuActions.inSilicoPCR(_:)),
            keyEquivalent: ""
        )

        primerItem.submenu = primerMenu
        toolsMenu.addItem(primerItem)

        toolsMenu.addItem(.separator())

        // Alignment
        toolsMenu.addItem(
            withTitle: "Align Sequences...",
            action: #selector(ToolsMenuActions.alignSequences(_:)),
            keyEquivalent: ""
        )

        toolsMenu.addItem(.separator())

        // Online databases
        let searchDatabasesItem = NSMenuItem(title: "Search Online Databases...", action: nil, keyEquivalent: "")
        let searchDatabasesMenu = NSMenu(title: "Search Online Databases")

        searchDatabasesMenu.addItem(
            withTitle: "Search NCBI...",
            action: #selector(ToolsMenuActions.searchNCBI(_:)),
            keyEquivalent: ""
        )

        searchDatabasesMenu.addItem(
            withTitle: "Search SRA...",
            action: #selector(ToolsMenuActions.searchSRA(_:)),
            keyEquivalent: ""
        )

        searchDatabasesMenu.addItem(
            withTitle: "Search Pathoplexus...",
            action: #selector(ToolsMenuActions.searchPathoplexus(_:)),
            keyEquivalent: ""
        )

        searchDatabasesItem.submenu = searchDatabasesMenu
        toolsMenu.addItem(searchDatabasesItem)

        toolsMenu.addItem(.separator())

        // Plugin Manager (Cmd-Shift-B for "Bioconda")
        let pluginItem = toolsMenu.addItem(
            withTitle: "Plugin Manager\u{2026}",
            action: #selector(ToolsMenuActions.showPluginManager(_:)),
            keyEquivalent: "b"
        )
        pluginItem.keyEquivalentModifierMask = [.command, .shift]

        toolsMenuItem.submenu = toolsMenu
        return toolsMenuItem
    }

    // MARK: - Operations Menu

    private static func createOperationsMenu() -> NSMenuItem {
        let opsMenuItem = NSMenuItem(title: "Operations", action: nil, keyEquivalent: "")
        let opsMenu = NSMenu(title: "Operations")
        opsMenu.delegate = OperationsMenuDelegate.shared

        // Placeholder for dynamic items (rebuilt by delegate in menuNeedsUpdate)
        let placeholderItem = opsMenu.addItem(
            withTitle: "No Active Operations",
            action: nil,
            keyEquivalent: ""
        )
        placeholderItem.isEnabled = false
        placeholderItem.tag = 5000

        opsMenu.addItem(.separator())

        // Show Operations Panel (Cmd-Shift-P for "Panel")
        let panelItem = opsMenu.addItem(
            withTitle: "Show Operations Panel",
            action: #selector(OperationsMenuActions.showOperationsPanel(_:)),
            keyEquivalent: "p"
        )
        panelItem.keyEquivalentModifierMask = [.command, .shift]

        opsMenu.addItem(.separator())

        // Clear Completed
        opsMenu.addItem(
            withTitle: "Clear Completed",
            action: #selector(OperationsMenuActions.clearCompletedOperations(_:)),
            keyEquivalent: ""
        )

        // Cancel All Operations
        opsMenu.addItem(
            withTitle: "Cancel All Operations",
            action: #selector(OperationsMenuActions.cancelAllOperations(_:)),
            keyEquivalent: ""
        )

        opsMenuItem.submenu = opsMenu
        return opsMenuItem
    }

    // MARK: - Window Menu

    private static func createWindowMenu() -> NSMenuItem {
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )

        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )

        windowMenu.addItem(.separator())

        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        // Set as app's window menu
        NSApp.windowsMenu = windowMenu

        windowMenuItem.submenu = windowMenu
        return windowMenuItem
    }

    // MARK: - Help Menu

    private static func createHelpMenu() -> NSMenuItem {
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        helpMenu.addItem(
            withTitle: "Lungfish Genome Explorer Help",
            action: #selector(HelpMenuActions.showLungfishHelp(_:)),
            keyEquivalent: "?"
        )

        helpMenu.addItem(.separator())

        helpMenu.addItem(
            withTitle: "Getting Started",
            action: #selector(HelpMenuActions.showGettingStarted(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(
            withTitle: "VCF Variants Guide",
            action: #selector(HelpMenuActions.showVCFGuide(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(
            withTitle: "AI Assistant Guide",
            action: #selector(HelpMenuActions.showAIGuide(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(.separator())

        helpMenu.addItem(
            withTitle: "Release Notes",
            action: #selector(HelpMenuActions.openReleaseNotes(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(
            withTitle: "Report an Issue...",
            action: #selector(HelpMenuActions.reportIssue(_:)),
            keyEquivalent: ""
        )

        // Set as app's help menu
        NSApp.helpMenu = helpMenu

        helpMenuItem.submenu = helpMenu
        return helpMenuItem
    }
}

// MARK: - Menu Action Protocols

/// File menu action handlers.
@MainActor
@objc protocol FileMenuActions {
    /// Unified import with format auto-detection
    func importFiles(_ sender: Any?)
    /// Import VCF variants into the current bundle
    func importVCFToBundle(_ sender: Any?)
    /// Import BAM/CRAM alignments into the current bundle
    func importBAMToBundle(_ sender: Any?)
    /// Import sample metadata into the current bundle
    func importSampleMetadataToBundle(_ sender: Any?)
    func exportFASTA(_ sender: Any?)
    func exportGenBank(_ sender: Any?)
    func exportGFF3(_ sender: Any?)
    func exportImage(_ sender: Any?)
    func exportPDF(_ sender: Any?)
    func exportProvenanceShell(_ sender: Any?)
    func exportProvenancePython(_ sender: Any?)
    func exportProvenanceNextflow(_ sender: Any?)
    func exportProvenanceSnakemake(_ sender: Any?)
    func exportProvenanceMethods(_ sender: Any?)
    func exportProvenanceJSON(_ sender: Any?)
    func exportFASTQ(_ sender: Any?)
    func importONTRun(_ sender: Any?)
}

/// View menu action handlers.
@MainActor
@objc protocol ViewMenuActions {
    func toggleSidebar(_ sender: Any?)
    func toggleInspector(_ sender: Any?)
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    func zoomToFit(_ sender: Any?)
    func zoomReset(_ sender: Any?)
    func toggleNucleotideMode(_ sender: Any?)
    func resetViewSettingsToDefaults(_ sender: Any?)
    func showAIAssistant(_ sender: Any?)
}

/// Sequence menu action handlers.
@MainActor
@objc protocol SequenceMenuActions {
    func reverseComplement(_ sender: Any?)
    func translate(_ sender: Any?)
    func goToPosition(_ sender: Any?)
    /// Navigate to a gene by searching the annotation index.
    func goToGene(_ sender: Any?)
    func copySelectionFASTA(_ sender: Any?)
    func extractSelection(_ sender: Any?)
    func addAnnotation(_ sender: Any?)
    func findORFs(_ sender: Any?)
    func findRestrictionSites(_ sender: Any?)
}

/// Tools menu action handlers.
@MainActor
@objc protocol ToolsMenuActions {
    /// Opens the classification wizard for the currently selected FASTQ.
    func classifyReads(_ sender: Any?)
    func runSPAdes(_ sender: Any?)
    func designPrimers(_ sender: Any?)
    func primalScheme(_ sender: Any?)
    func inSilicoPCR(_ sender: Any?)
    func alignSequences(_ sender: Any?)
    func searchNCBI(_ sender: Any?)
    func searchSRA(_ sender: Any?)
    func searchPathoplexus(_ sender: Any?)
    /// Opens the Plugin Manager window for browsing and installing bioconda tools.
    func showPluginManager(_ sender: Any?)
}

/// Operations menu action handlers.
@MainActor
@objc protocol OperationsMenuActions {
    func showOperationsPanel(_ sender: Any?)
    func cancelAllOperations(_ sender: Any?)
    func clearCompletedOperations(_ sender: Any?)
    func cancelOperation(_ sender: Any?)
}

/// Delegate that dynamically rebuilds the Operations menu before it opens.
///
/// On `menuNeedsUpdate`, all items with tags in 5000-5099 are removed
/// and replaced with the current running/completed/failed operations
/// from ``OperationCenter.shared``.
@MainActor
final class OperationsMenuDelegate: NSObject, NSMenuDelegate {

    static let shared = OperationsMenuDelegate()

    private static let dynamicTagBase = 5000

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildDynamicItems(in: menu)
    }

    private func rebuildDynamicItems(in menu: NSMenu) {
        // Remove all dynamic items (tags 5000-5099)
        let dynamicItems = menu.items.filter {
            $0.tag >= Self.dynamicTagBase && $0.tag < Self.dynamicTagBase + 100
        }
        for item in dynamicItems {
            menu.removeItem(item)
        }

        let items = OperationCenter.shared.items

        if items.isEmpty {
            let placeholder = NSMenuItem(title: "No Active Operations", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            placeholder.tag = Self.dynamicTagBase
            menu.insertItem(placeholder, at: 0)
            return
        }

        // Insert dynamic items at the top of the menu
        for (index, op) in items.prefix(20).enumerated() {
            let statusSymbol: String
            let statusAccessibility: String
            let progressText: String
            switch op.state {
            case .running:
                statusSymbol = "play.circle"
                statusAccessibility = "Running"
                progressText = " (\(Int(op.progress * 100))%)"
            case .completed:
                statusSymbol = "checkmark.circle"
                statusAccessibility = "Completed"
                progressText = ""
            case .failed:
                statusSymbol = "xmark.circle"
                statusAccessibility = "Failed"
                progressText = ""
            }

            let title = "\(op.title)\(progressText)"
            let menuItem = NSMenuItem(
                title: title,
                action: op.state == .running
                    ? #selector(OperationsMenuActions.cancelOperation(_:))
                    : nil,
                keyEquivalent: ""
            )
            menuItem.image = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: statusAccessibility)
            menuItem.tag = Self.dynamicTagBase + index + 1
            menuItem.representedObject = op.id
            if op.state != .running {
                menuItem.isEnabled = false
            }
            menuItem.toolTip = op.detail
            menu.insertItem(menuItem, at: index)
        }
    }
}

/// Help menu action handlers.
@MainActor
@objc protocol HelpMenuActions {
    func showLungfishHelp(_ sender: Any?)
    func showGettingStarted(_ sender: Any?)
    func showVCFGuide(_ sender: Any?)
    func showAIGuide(_ sender: Any?)
    func openReleaseNotes(_ sender: Any?)
    func reportIssue(_ sender: Any?)
}
