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
            withTitle: "About Lungfish",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
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
            withTitle: "Hide Lungfish",
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
            withTitle: "Quit Lungfish",
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

        // Open Project Folder
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

        // Import - single unified option with auto-detection
        let importItem = fileMenu.addItem(
            withTitle: "Import Files...",
            action: #selector(FileMenuActions.importFiles(_:)),
            keyEquivalent: "i"
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]

        // Import VCF variants into the current bundle
        fileMenu.addItem(
            withTitle: "Import VCF Variants...",
            action: #selector(FileMenuActions.importVCFToBundle(_:)),
            keyEquivalent: ""
        )

        // Export submenu
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "Export")

        exportMenu.addItem(
            withTitle: "FASTA...",
            action: #selector(FileMenuActions.exportFASTA(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "GenBank...",
            action: #selector(FileMenuActions.exportGenBank(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "GFF3...",
            action: #selector(FileMenuActions.exportGFF3(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(.separator())
        exportMenu.addItem(
            withTitle: "Image (PNG)...",
            action: #selector(FileMenuActions.exportImage(_:)),
            keyEquivalent: ""
        )
        exportMenu.addItem(
            withTitle: "Image (PDF)...",
            action: #selector(FileMenuActions.exportPDF(_:)),
            keyEquivalent: ""
        )

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

        let findPrevItem = findMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
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

        // Sidebar toggle (Option-Command-S per HIG)
        // Apple HIG: Title should dynamically update to "Show Sidebar" / "Hide Sidebar"
        // Tag 1000 enables dynamic title updates in validateMenuItem
        let sidebarItem = viewMenu.addItem(
            withTitle: "Show Sidebar",
            action: #selector(ViewMenuActions.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
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

        // Display mode submenu
        let displayModeItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let displayModeMenu = NSMenu(title: "Display Mode")

        displayModeMenu.addItem(
            withTitle: "Collapsed",
            action: #selector(ViewMenuActions.setDisplayModeCollapsed(_:)),
            keyEquivalent: ""
        )
        displayModeMenu.addItem(
            withTitle: "Squished",
            action: #selector(ViewMenuActions.setDisplayModeSquished(_:)),
            keyEquivalent: ""
        )
        displayModeMenu.addItem(
            withTitle: "Expanded",
            action: #selector(ViewMenuActions.setDisplayModeExpanded(_:)),
            keyEquivalent: ""
        )

        displayModeItem.submenu = displayModeMenu
        viewMenu.addItem(displayModeItem)

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

        // Selection operations (Command-L to avoid conflict with Find Next Command-G)
        seqMenu.addItem(
            withTitle: "Go to Position...",
            action: #selector(SequenceMenuActions.goToPosition(_:)),
            keyEquivalent: "l"
        )

        seqMenu.addItem(
            withTitle: "Select Region...",
            action: #selector(SequenceMenuActions.selectRegion(_:)),
            keyEquivalent: ""
        )

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

        // Assembly
        let assemblyItem = NSMenuItem(title: "Assembly", action: nil, keyEquivalent: "")
        let assemblyMenu = NSMenu(title: "Assembly")

        assemblyMenu.addItem(
            withTitle: "SPAdes Assembly...",
            action: #selector(ToolsMenuActions.runSPAdes(_:)),
            keyEquivalent: ""
        )
        assemblyMenu.addItem(
            withTitle: "MEGAHIT Assembly...",
            action: #selector(ToolsMenuActions.runMEGAHIT(_:)),
            keyEquivalent: ""
        )

        assemblyItem.submenu = assemblyMenu
        toolsMenu.addItem(assemblyItem)

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

        // Database access - Unified NCBI search
        toolsMenu.addItem(
            withTitle: "Search NCBI...",
            action: #selector(ToolsMenuActions.searchNCBI(_:)),
            keyEquivalent: ""
        )

        // SRA/FASTQ download via ENA
        toolsMenu.addItem(
            withTitle: "Download SRA (FASTQ)...",
            action: #selector(ToolsMenuActions.searchSRA(_:)),
            keyEquivalent: ""
        )

        // Pathoplexus viral sequences
        toolsMenu.addItem(
            withTitle: "Search Pathoplexus...",
            action: #selector(ToolsMenuActions.searchPathoplexus(_:)),
            keyEquivalent: ""
        )

        // Genome assembly download with bundle building
        toolsMenu.addItem(
            withTitle: "Download Genome Assembly...",
            action: #selector(ToolsMenuActions.downloadGenomeAssembly(_:)),
            keyEquivalent: ""
        )

        toolsMenu.addItem(.separator())

        // Workflows
        let workflowItem = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
        let workflowMenu = NSMenu(title: "Workflows")

        workflowMenu.addItem(
            withTitle: "Run Nextflow Pipeline...",
            action: #selector(ToolsMenuActions.runNextflow(_:)),
            keyEquivalent: ""
        )
        workflowMenu.addItem(
            withTitle: "Run Snakemake Workflow...",
            action: #selector(ToolsMenuActions.runSnakemake(_:)),
            keyEquivalent: ""
        )
        workflowMenu.addItem(.separator())
        workflowMenu.addItem(
            withTitle: "Workflow Builder...",
            action: #selector(ToolsMenuActions.openWorkflowBuilder(_:)),
            keyEquivalent: ""
        )

        workflowItem.submenu = workflowMenu
        toolsMenu.addItem(workflowItem)

        toolsMenuItem.submenu = toolsMenu
        return toolsMenuItem
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
            withTitle: "Lungfish Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )

        helpMenu.addItem(.separator())

        helpMenu.addItem(
            withTitle: "Documentation",
            action: #selector(HelpMenuActions.openDocumentation(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(
            withTitle: "Release Notes",
            action: #selector(HelpMenuActions.openReleaseNotes(_:)),
            keyEquivalent: ""
        )

        helpMenu.addItem(.separator())

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
    func exportFASTA(_ sender: Any?)
    func exportGenBank(_ sender: Any?)
    func exportGFF3(_ sender: Any?)
    func exportImage(_ sender: Any?)
    func exportPDF(_ sender: Any?)
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
    func setDisplayModeCollapsed(_ sender: Any?)
    func setDisplayModeSquished(_ sender: Any?)
    func setDisplayModeExpanded(_ sender: Any?)
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
    func selectRegion(_ sender: Any?)
    func addAnnotation(_ sender: Any?)
    func findORFs(_ sender: Any?)
    func findRestrictionSites(_ sender: Any?)
}

/// Tools menu action handlers.
@MainActor
@objc protocol ToolsMenuActions {
    func runSPAdes(_ sender: Any?)
    func runMEGAHIT(_ sender: Any?)
    func designPrimers(_ sender: Any?)
    func primalScheme(_ sender: Any?)
    func inSilicoPCR(_ sender: Any?)
    func alignSequences(_ sender: Any?)
    func searchNCBI(_ sender: Any?)
    func searchSRA(_ sender: Any?)
    func searchPathoplexus(_ sender: Any?)
    func downloadGenomeAssembly(_ sender: Any?)
    func runNextflow(_ sender: Any?)
    func runSnakemake(_ sender: Any?)
    func openWorkflowBuilder(_ sender: Any?)
}

/// Help menu action handlers.
@MainActor
@objc protocol HelpMenuActions {
    func openDocumentation(_ sender: Any?)
    func openReleaseNotes(_ sender: Any?)
    func reportIssue(_ sender: Any?)
}
