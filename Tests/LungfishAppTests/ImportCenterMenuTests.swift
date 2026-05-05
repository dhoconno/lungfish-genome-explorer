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
        let mainMenu = MainMenu.createMainMenu()
        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let operationsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Operations" })?.submenu)

        XCTAssertEqual(appMenu.items.first(where: { $0.title == "About Lungfish Genome Explorer" })?.identifier?.rawValue, MainMenuAccessibilityID.about)
        XCTAssertEqual(appMenu.items.first(where: { $0.title == "Settings..." })?.identifier?.rawValue, MainMenuAccessibilityID.settings)
        XCTAssertEqual(appMenu.items.first(where: { $0.title == "Quit Lungfish Genome Explorer" })?.identifier?.rawValue, MainMenuAccessibilityID.quit)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "New Project" })?.identifier?.rawValue, MainMenuAccessibilityID.newProject)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "Open Project Folder..." })?.identifier?.rawValue, MainMenuAccessibilityID.openProjectFolder)
        XCTAssertEqual(fileMenu.items.first(where: { $0.title == "Import Center…" })?.identifier?.rawValue, MainMenuAccessibilityID.importCenter)
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

    func testToolsMenuOmitsGenericNFCoreWorkflowSurface() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)

        XCTAssertNil(toolsMenu.items.first(where: { $0.title == "nf-core Workflows…" }))
        XCTAssertFalse(toolsMenu.items.contains { $0.identifier?.rawValue == "tools-menu-nf-core-workflows" })
    }

    func testFASTQFASTAOperationsMenuIncludesSequenceTransformActions() throws {
        let _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "Tools" })?.submenu)
        let operationsMenu = try XCTUnwrap(
            toolsMenu.items.first(where: { $0.title == "FASTQ/FASTA Operations" })?.submenu
        )

        let reverseComplement = try XCTUnwrap(
            operationsMenu.items.first(where: { $0.title == "Reverse Complement Selection" })
        )
        let translate = try XCTUnwrap(
            operationsMenu.items.first(where: { $0.title == "Translate Selection…" })
        )

        XCTAssertEqual(reverseComplement.action, #selector(AppDelegate.reverseComplement(_:)))
        XCTAssertEqual(translate.action, #selector(AppDelegate.translate(_:)))
    }

    func testImportCenterCatalogUsesExplicitImportCategoriesInsteadOfProjectFiles() throws {
        let viewModel = ImportCenterViewModel()
        let ids = Set(viewModel.allCards.map(\.id))

        XCTAssertTrue(ids.contains("fastq"))
        XCTAssertTrue(ids.contains("ont-run"))
        XCTAssertTrue(ids.contains("bam-cram"))
        XCTAssertTrue(ids.contains("vcf"))
        XCTAssertTrue(ids.contains("kraken2"))
        XCTAssertTrue(ids.contains("esviritu"))
        XCTAssertTrue(ids.contains("taxtriage"))
        XCTAssertTrue(ids.contains("nvd"))
        XCTAssertTrue(ids.contains("fasta"))
        XCTAssertTrue(ids.contains("annotation-track"))
        XCTAssertTrue(ids.contains("geneious-export"))
        let card = try XCTUnwrap(viewModel.allCards.first { $0.id == "geneious-export" })
        XCTAssertEqual(card.title, "Geneious Export")
        XCTAssertEqual(card.importAction, .geneiousExport)
        XCTAssertEqual(card.tab, .applicationExports)
        XCTAssertFalse(ids.contains("project-files"))
        XCTAssertFalse(ids.contains("bundle-sample-metadata"))
        XCTAssertFalse(ids.contains("project-sample-metadata"))
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
        XCTAssertFalse(ImportCenterViewModel.Tab.allCases.map(\.title).contains("Metadata"))
    }

    func testDeferredImportCenterTodoMentionsDatasetLevelMetadataRequirements() throws {
        let todo = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/TODO.md"),
            encoding: .utf8
        )

        XCTAssertTrue(todo.contains("Import Center dataset-level metadata import"))
        XCTAssertTrue(todo.contains("Support both CSV and TSV"))
        XCTAssertTrue(todo.contains("Choose which dataset in the current project receives the metadata file"))
        XCTAssertTrue(todo.contains("Preview and matching UI"))
    }
}
