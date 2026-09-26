import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ImportCenterMenuTests: XCTestCase {

    func testFileMenuImportSubmenuContainsOnlyImportCenter() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        XCTAssertNil(fileMenu.items.first(where: { $0.title == "Import" }))
        XCTAssertNotNil(fileMenu.items.first(where: { $0.title == "Import Center…" }))
    }

    func testApplicationMenuContainsQuitItem() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        XCTAssertNotNil(appMenu.items.first(where: { $0.title == "Quit Lungfish Genome Explorer" }))
    }

    func testApplicationMenuContainsCheckForUpdatesItem() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let item = try XCTUnwrap(appMenu.items.first(where: { $0.title == "Check for Updates…" }))

        XCTAssertEqual(item.identifier?.rawValue, MainMenuAccessibilityID.checkForUpdates)
        XCTAssertEqual(item.action, #selector(AppDelegate.checkForUpdates(_:)))
    }

    func testOpenRecentMenuIncludesPersistedRecentProjects() throws {
        let _ = NSApplication.shared
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Open Recent Project With Spaces-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let originalProjects = RecentProjectsManager.shared.recentProjects
        RecentProjectsManager.shared.replaceRecentProjectsForTesting([])
        defer {
            RecentProjectsManager.shared.replaceRecentProjectsForTesting(originalProjects)
            try? FileManager.default.removeItem(at: projectURL)
        }
        RecentProjectsManager.shared.addRecentProject(url: projectURL, name: "Open Recent Project With Spaces")

        let mainMenu = MainMenu.createMainMenu()
        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        let openRecentMenu = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Open Recent" })?.submenu)
        let projectItem = try XCTUnwrap(openRecentMenu.items.first(where: { $0.title == "Open Recent Project With Spaces" }))

        XCTAssertEqual((projectItem.representedObject as? URL)?.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(projectItem.action, #selector(AppDelegate.openRecentProjectFromMenu(_:)))
    }

    // NEW-03: adding the "same" project twice via URLs that are not `==`
    // under raw URL equality (one without a trailing slash, one built with
    // `isDirectory: true`) must not produce two Open Recent entries.
    func testAddRecentProjectDeduplicatesEquivalentURLsRegardlessOfConstruction() throws {
        let _ = NSApplication.shared
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dedup Project-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let originalProjects = RecentProjectsManager.shared.recentProjects
        RecentProjectsManager.shared.replaceRecentProjectsForTesting([])
        defer {
            RecentProjectsManager.shared.replaceRecentProjectsForTesting(originalProjects)
            try? FileManager.default.removeItem(at: baseURL)
        }

        let withoutTrailingSlash = URL(fileURLWithPath: baseURL.path, isDirectory: false)
        let withTrailingSlash = URL(fileURLWithPath: baseURL.path, isDirectory: true)
        XCTAssertNotEqual(withoutTrailingSlash, withTrailingSlash, "Precondition: these must differ under raw URL equality for this test to be meaningful")

        RecentProjectsManager.shared.addRecentProject(url: withoutTrailingSlash, name: "Dedup Project")
        RecentProjectsManager.shared.addRecentProject(url: withTrailingSlash, name: "Dedup Project")

        XCTAssertEqual(
            RecentProjectsManager.shared.recentProjects.count, 1,
            "Two additions naming the same project folder must collapse into a single Open Recent entry"
        )
    }

    func testMainMenuTopLevelMenusExposeStableIdentifiers() {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()

        XCTAssertEqual(mainMenu.items.first?.identifier?.rawValue, MainMenuAccessibilityID.applicationMenu)
        XCTAssertEqual(mainMenu.items.first(where: { $0.title == "File" })?.identifier?.rawValue, MainMenuAccessibilityID.fileMenu)
        XCTAssertEqual(mainMenu.items.first(where: { $0.title == "Tools" })?.identifier?.rawValue, MainMenuAccessibilityID.toolsMenu)
        XCTAssertEqual(mainMenu.items.first(where: { $0.title == "Help" })?.identifier?.rawValue, MainMenuAccessibilityID.helpMenu)
    }

    func testMainMenuKeyItemsExposeStableIdentifiers() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: true,
                hasHaplotypeDefinitions: true
            )
        )
        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let operationsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Operations" })?.submenu)

        XCTAssertEqual(appMenu.items.first(where: { $0.title == "About Lungfish Genome Explorer" })?.identifier?.rawValue, MainMenuAccessibilityID.about)
        XCTAssertEqual(appMenu.items.first(where: { $0.title == "Check for Updates…" })?.identifier?.rawValue, MainMenuAccessibilityID.checkForUpdates)
        XCTAssertEqual(appMenu.items.first(where: { $0.title == "Settings…" })?.identifier?.rawValue, MainMenuAccessibilityID.settings)
        XCTAssertEqual(appMenu.items.first(where: { $0.title == "Quit Lungfish Genome Explorer" })?.identifier?.rawValue, MainMenuAccessibilityID.quit)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "New Project" })?.identifier?.rawValue, MainMenuAccessibilityID.newProject)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "Open Project Folder…" })?.identifier?.rawValue, MainMenuAccessibilityID.openProjectFolder)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "Import Center…" })?.identifier?.rawValue, MainMenuAccessibilityID.importCenter)
        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Workflow Operations…" }))
        XCTAssertNotNil(toolsMenu.items.first(where: { $0.title == "Genotyping" })?.submenu)
        let workflowsItem = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Workflows" }))
        XCTAssertEqual(workflowsItem.identifier?.rawValue, MainMenuAccessibilityID.workflows)
        let workflowsMenu = try XCTUnwrap(workflowsItem.submenu)
        XCTAssertEqual(workflowsMenu.items.first(where: { $0.title == "Workflow Library…" })?.identifier?.rawValue, MainMenuAccessibilityID.workflowLibrary)
        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Workflow Library…" }))
        XCTAssertEqual(toolsMenu.items.first(where: { $0.title == "Plugin Manager…" })?.identifier?.rawValue, MainMenuAccessibilityID.pluginManager)
        XCTAssertEqual(operationsMenu.items.first(where: { $0.title == "Show Operations Panel" })?.identifier?.rawValue, MainMenuAccessibilityID.showOperationsPanel)
    }


    func testToolsMenuExposesCallVariantsItemWithStableIdentifier() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let callVariantsItem = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Call Variants…" }))

        XCTAssertEqual(callVariantsItem.identifier?.rawValue, MainMenuAccessibilityID.callVariants)
    }




    func testWorkflowLibraryMenuItemRoutesThroughToolsMenuActionProtocol() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let workflowsMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Workflows" })?.submenu)
        let workflowLibraryItem = try XCTUnwrap(workflowsMenu.items.first(where: { $0.title == "Workflow Library…" }))
        let selector = NSSelectorFromString("showWorkflowLibrary:")
        let protocolMethod = protocol_getMethodDescription(ToolsMenuActions.self, selector, true, true)
        let recorder = ToolsMenuActionRecorder()

        XCTAssertNotNil(protocolMethod.name)
        XCTAssertEqual(workflowLibraryItem.action, selector)
        XCTAssertTrue(recorder.responds(to: selector))

        recorder.perform(workflowLibraryItem.action, with: workflowLibraryItem)

        XCTAssertEqual(recorder.workflowLibraryInvocationCount, 1)
    }

    func testInlinedWorkflowMenuItemRoutesThroughToolsMenuActionProtocol() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: true,
                hasHaplotypeDefinitions: false
            )
        )
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let genotypingMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Genotyping" })?.submenu)
        let workflowItem = try XCTUnwrap(genotypingMenu.items.first(where: {
            $0.title == "\(FASTQOperationToolID.ontGenotyping.title)\u{2026}"
        }))
        let selector = NSSelectorFromString("launchWorkflowFromMenu:")
        let protocolMethod = protocol_getMethodDescription(ToolsMenuActions.self, selector, true, true)
        let recorder = ToolsMenuActionRecorder()

        XCTAssertNotNil(protocolMethod.name)
        XCTAssertEqual(workflowItem.action, selector)
        XCTAssertEqual(workflowItem.representedObject as? FASTQOperationToolID, .ontGenotyping)
        XCTAssertTrue(recorder.responds(to: selector))

        recorder.perform(workflowItem.action, with: workflowItem)

        XCTAssertEqual(recorder.launchWorkflowInvocationCount, 1)
    }

    func testWorkflowFeatureMenuItemsAreHiddenWhenNoOptionalWorkflowUsesThem() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: false,
                hasHaplotypeDefinitions: false
            )
        )
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Workflow Operations…" }))
        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Haplotype Definitions…" }))
    }

    func testWorkflowOperationsCanAppearWithoutHaplotypeDefinitionsForCustomWorkflows() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: true,
                hasHaplotypeDefinitions: false
            )
        )
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Workflow Operations…" }))
        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Haplotype Definitions…" }))
        XCTAssertNotNil(toolsMenu.items.first(where: { $0.title == "Genotyping" })?.submenu)
    }

    func testHaplotypeDefinitionsAppearOnlyWhenEnabledWorkflowUsesThem() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: true,
                hasHaplotypeDefinitions: true
            )
        )
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "Workflow Operations…" }))
        XCTAssertNotNil(toolsMenu.items.first(where: { $0.title == "Haplotype Definitions…" }))
    }

    func testTwelveSCapabilityDrivesWorkflowOperationsButNotHaplotypeDefinitions() throws {
        let suiteName = "WorkflowFeatureAvailability-12S-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)

        // ONT genotyping (which declares `.haplotypeDefinitions`) is enabled by
        // default; disable it so this test isolates the 12S capability. With only
        // 12S amplicon matching enabled, the 12S item declares `.workflowOperations`
        // (and NOT `.haplotypeDefinitions`), so the Tools menu surfaces Workflow
        // Operations but not Haplotype Definitions.
        store.setWorkflow(.ontGenotyping, enabled: false)
        store.setWorkflow(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem, enabled: true)
        let twelveSOnly = WorkflowFeatureAvailability.current(enablementStore: store)
        XCTAssertTrue(twelveSOnly.hasWorkflowOperations)
        XCTAssertFalse(twelveSOnly.hasHaplotypeDefinitions)
    }

    func testONTGenotypingCapabilityDrivesBothWorkflowFeatures() throws {
        let suiteName = "WorkflowFeatureAvailability-ONT-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)

        // ONT genotyping declares both `.workflowOperations` and
        // `.haplotypeDefinitions`, so enabling it surfaces both Tools-menu features.
        store.setWorkflow(.ontGenotyping, enabled: true)
        let availability = WorkflowFeatureAvailability.current(enablementStore: store)
        XCTAssertTrue(availability.hasWorkflowOperations)
        XCTAssertTrue(availability.hasHaplotypeDefinitions)
    }

    func testToolsMenuOmitsGenericNFCoreWorkflowSurface() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "nf-core Workflows…" }))
        XCTAssertFalse(toolsMenu.items.contains { $0.identifier?.rawValue == "tools-menu-nf-core-workflows" })
    }

    func testFASTQFASTAToolMenuRoutesTransformActionsToFASTQFASTADialog() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let operationsMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Read Processing" })?.submenu)

        let reverseComplement = try XCTUnwrap(
            operationsMenu.items.first(where: { $0.title == "Reverse Complement\u{2026}" })
        )
        let translate = try XCTUnwrap(
            operationsMenu.items.first(where: { $0.title == "Translate\u{2026}" })
        )

        XCTAssertEqual(reverseComplement.action, #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)))
        XCTAssertEqual(translate.action, #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)))
        XCTAssertEqual(reverseComplement.representedObject as? FASTQOperationToolID, .reverseComplement)
        XCTAssertEqual(translate.representedObject as? FASTQOperationToolID, .translate)
    }

    func testFASTQFASTAOperationsMenuEnumeratesToolLeafCommands() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        let demultiplexingMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Demultiplexing" })?.submenu)
        XCTAssertEqual(demultiplexingMenu.items.map(\.title), [
            "Demultiplex Barcodes\u{2026}",
            "ONT Fluidigm Sample Split\u{2026}",
        ])
        XCTAssertTrue(demultiplexingMenu.items.allSatisfy {
            $0.action == #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:))
        })

        let mappingMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Mapping" })?.submenu)
        XCTAssertEqual(mappingMenu.items.map(\.title), [
            "minimap2\u{2026}",
            "BWA-MEM2\u{2026}",
            "Bowtie2\u{2026}",
            "BBMap\u{2026}",
            "Viral Recon\u{2026}",
        ])
        XCTAssertEqual(mappingMenu.items.compactMap { $0.representedObject as? FASTQOperationToolID }, [
            .minimap2,
            .bwaMem2,
            .bowtie2,
            .bbmap,
            .viralRecon,
        ])

        let readProcessingMenu = try XCTUnwrap(toolsMenu.items.first(where: { $0.title == "Read Processing" })?.submenu)
        XCTAssertTrue(readProcessingMenu.items.contains { $0.title == "Merge Overlapping Pairs\u{2026}" })
        XCTAssertNotNil(readProcessingMenu.items.first {
            $0.title == "Reverse Complement\u{2026}"
                && $0.representedObject as? FASTQOperationToolID == .reverseComplement
        })
        XCTAssertNotNil(readProcessingMenu.items.first {
            $0.title == "Translate\u{2026}"
                && $0.representedObject as? FASTQOperationToolID == .translate
        })
    }

    func testFASTQFASTAOperationsMenuOmitsPluginManagementShortcuts() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let operationSubmenus = toolsMenu.items.compactMap(\.submenu)

        XCTAssertFalse(operationSubmenus.contains { menu in
            menu.items.contains { $0.title == "Lineage Demixing" }
        })
        XCTAssertFalse(operationSubmenus.contains { menu in
            menu.items.contains { $0.title == "Install/Configure Freyja…" }
        })
    }

    func testImportCenterCatalogUsesExplicitImportCategoriesInsteadOfProjectFiles() throws {
        let viewModel = ImportCenterViewModel()
        let ids = Set(viewModel.allCards.map(\.id))

        XCTAssertTrue(ids.contains("fastq"))
        XCTAssertTrue(ids.contains("fastq-sample-sheet"))
        XCTAssertTrue(ids.contains("ont-run"))
        XCTAssertTrue(ids.contains("bam-cram"))
        XCTAssertTrue(ids.contains("vcf"))
        XCTAssertTrue(ids.contains("kraken2"))
        XCTAssertTrue(ids.contains("esviritu"))
        XCTAssertTrue(ids.contains("taxtriage"))
        XCTAssertTrue(ids.contains("nvd"))
        XCTAssertTrue(ids.contains("cz-id"))
        XCTAssertTrue(ids.contains("fasta"))
        XCTAssertTrue(ids.contains("annotation-track"))
        XCTAssertTrue(ids.contains("geneious-export"))
        let czIdCard = try XCTUnwrap(viewModel.allCards.first { $0.id == "cz-id" })
        XCTAssertTrue(czIdCard.description.contains("imported, not run locally"))
        let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "geneious-export" })
        XCTAssertEqual(card.title, "Geneious Export")
        XCTAssertEqual(card.importAction, .geneiousExport)
        XCTAssertEqual(card.tab, .applicationExports)
        XCTAssertFalse(ids.contains("project-files"))
        XCTAssertFalse(ids.contains("bundle-sample-metadata"))
        XCTAssertFalse(ids.contains("project-sample-metadata"))
    }

    func testImportCenterSampleSheetCardRoutesToBatchFASTQImport() throws {
        let viewModel = ImportCenterViewModel()
        let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "fastq-sample-sheet" })

        XCTAssertEqual(card.title, "FASTQ Sample Sheet")
        XCTAssertEqual(card.importAction, .fastqSampleSheet)
        XCTAssertEqual(card.tab, .sequencingReads)
        XCTAssertEqual(card.fileHint, ".csv with sample,r1,r2 columns")

        guard case .openPanel(let config, let action) = card.importKind else {
            return XCTFail("FASTQ sample sheet should use an open panel")
        }
        XCTAssertEqual(action, .fastqSampleSheet)
        XCTAssertTrue(config.canChooseFiles)
        XCTAssertFalse(config.canChooseDirectories)
        XCTAssertFalse(config.allowsMultipleSelection)
        XCTAssertTrue(config.allowedTypes?.contains { $0.preferredFilenameExtension == "csv" } ?? false)
    }

    func testSequencingReadCardAcceptsBAM() throws {
        let viewModel = ImportCenterViewModel()
        let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "fastq" })
        guard case .openPanel(let configuration, _) = card.importKind else {
            return XCTFail("Expected sequencing reads to use an open panel")
        }

        XCTAssertEqual(card.title, "Sequencing Read Files")
        XCTAssertTrue(configuration.allowedTypes?.contains {
            $0.preferredFilenameExtension == "bam"
        } ?? false)
    }

    func testImportCenterHasApplicationExportsTab() {
        XCTAssertTrue(ImportCenterViewModel.Tab.allCases.contains(.applicationExports))
        XCTAssertEqual(ImportCenterViewModel.Tab.applicationExports.title, "Application Exports")
    }

    func testApplicationExportsTabOnlyContainsTestedGeneiousCard() throws {
        let viewModel = ImportCenterViewModel()
        viewModel.selectedTab = .applicationExports
        let ids = viewModel.visibleCards.map(\.id)

        XCTAssertEqual(ids, ["geneious-export"])
        XCTAssertFalse(viewModel.allCards.contains { $0.id.localizedCaseInsensitiveContains("sanger") })
    }

    func testApplicationExportCardsUseSingleSourceFileOrFolderPanels() throws {
        let viewModel = ImportCenterViewModel()
        let cards = viewModel.allCards.filter { $0.tab == .applicationExports }
        XCTAssertEqual(cards.map(\.id), ["geneious-export"])

        for card in cards {
            guard case .openPanel(let config, _) = card.importKind else {
                return XCTFail("\(card.id) must use an open panel")
            }
            XCTAssertTrue(config.canChooseFiles, card.id)
            XCTAssertTrue(config.canChooseDirectories, card.id)
            XCTAssertFalse(config.allowsMultipleSelection, card.id)
            XCTAssertTrue(config.allowsOtherFileTypes, card.id)
        }
    }

    func testGeneiousImportCardAcceptsArchivesAndFolders() throws {
        let viewModel = ImportCenterViewModel()
        let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "geneious-export" })
        guard case .openPanel(let config, let action) = card.importKind else {
            return XCTFail("Geneious import must use an open panel")
        }
        XCTAssertEqual(action, .geneiousExport)
        XCTAssertTrue(config.canChooseFiles)
        XCTAssertTrue(config.canChooseDirectories)
        XCTAssertFalse(config.allowsMultipleSelection)
    }

    func testImportCenterOmitsDeferredMetadataSection() {
        let viewModel = ImportCenterViewModel()
        let metadataCardNames = viewModel.allCards
            .map { "\($0.id) \($0.title)" }
            .joined(separator: "\n")

        XCTAssertFalse(ImportCenterViewModel.Tab.allCases.map(\.title).contains("Metadata"))
        XCTAssertFalse(metadataCardNames.localizedCaseInsensitiveContains("metadata"))
    }
}

@MainActor
private final class ToolsMenuActionRecorder: NSObject, ToolsMenuActions {
    private(set) var workflowLibraryInvocationCount = 0
    private(set) var workflowOperationsInvocationCount = 0
    private(set) var launchWorkflowInvocationCount = 0

    @objc func showWorkflowLibrary(_ sender: Any?) {
        workflowLibraryInvocationCount += 1
    }

    @objc func showWorkflowOperations(_ sender: Any?) {
        workflowOperationsInvocationCount += 1
    }

    @objc func launchFASTQOperationToolFromMenu(_ sender: NSMenuItem) {}
    @objc func showHaplotypeDefinitions(_ sender: Any?) {}

    @objc func launchWorkflowFromMenu(_ sender: NSMenuItem) {
        launchWorkflowInvocationCount += 1
    }
    @objc func promptEnableWorkflowFromMenu(_ sender: NSMenuItem) {}
    @objc func launchLinkedWorkflowPackageFromMenu(_ sender: NSMenuItem) {}
    @objc func revealLinkedWorkflowPackageInLibrary(_ sender: NSMenuItem) {}
    @objc func showBAMVariantCalling(_ sender: Any?) {}
    @objc func searchNCBI(_ sender: Any?) {}
    @objc func searchSRA(_ sender: Any?) {}
    @objc func searchPathoplexus(_ sender: Any?) {}
    @objc func showPluginManager(_ sender: Any?) {}
    @objc func showPCRPrimerDesign(_ sender: Any?) {}
}
