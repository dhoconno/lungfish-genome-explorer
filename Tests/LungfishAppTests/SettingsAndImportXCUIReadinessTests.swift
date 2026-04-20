import XCTest
@testable import LungfishApp

@MainActor
final class SettingsAndImportXCUIReadinessTests: XCTestCase {

    func testSettingsAccessibilityIdentifierCatalogIsStable() {
        XCTAssertEqual(SettingsAccessibilityID.window, "settings-window")
        XCTAssertEqual(SettingsAccessibilityID.root, "settings-root")
        XCTAssertEqual(SettingsAccessibilityID.tab(.general), "settings-tab-general")
        XCTAssertEqual(SettingsAccessibilityID.tab(.storage), "settings-tab-storage")
        XCTAssertEqual(SettingsAccessibilityID.panel(.aiServices), "settings-panel-ai-services")
        XCTAssertEqual(SettingsAccessibilityID.storageChangeLocationButton, "settings-storage-change-location-button")
        XCTAssertEqual(SettingsAccessibilityID.aiOpenAIKeyField, "settings-ai-openai-key-field")
        XCTAssertEqual(SettingsAccessibilityID.aiClearKeysButton, "settings-ai-clear-keys-button")
    }

    func testImportCenterAccessibilityIdentifierCatalogIsStable() {
        XCTAssertEqual(ImportCenterAccessibilityID.window, "import-center-window")
        XCTAssertEqual(ImportCenterAccessibilityID.root, "import-center-root")
        XCTAssertEqual(ImportCenterAccessibilityID.tab(.classificationResults), "import-center-tab-classification-results")
        XCTAssertEqual(ImportCenterAccessibilityID.cardID("fastq"), "import-center-card-fastq")
        XCTAssertEqual(ImportCenterAccessibilityID.buttonID("nvd"), "import-center-button-nvd")
    }

    func testMainMenuAccessibilityIdentifierCatalogIsStable() {
        XCTAssertEqual(MainMenuAccessibilityID.applicationMenu, "main-menu-application")
        XCTAssertEqual(MainMenuAccessibilityID.fileMenu, "main-menu-file")
        XCTAssertEqual(MainMenuAccessibilityID.helpMenu, "main-menu-help")
        XCTAssertEqual(MainMenuAccessibilityID.newProject, "file-menu-new-project")
        XCTAssertEqual(MainMenuAccessibilityID.importCenter, "file-menu-import-center")
        XCTAssertEqual(MainMenuAccessibilityID.pluginManager, "tools-menu-plugin-manager")
        XCTAssertEqual(MainMenuAccessibilityID.showOperationsPanel, "operations-menu-show-panel")
        XCTAssertEqual(MainMenuAccessibilityID.reportIssue, "help-menu-report-issue")
    }

    func testPluginManagerAccessibilityIdentifierCatalogIsStable() {
        XCTAssertEqual(PluginManagerAccessibilityID.window, "plugin-manager-window")
        XCTAssertEqual(PluginManagerAccessibilityID.root, "plugin-manager-root")
        XCTAssertEqual(PluginManagerAccessibilityID.installedBrowsePacksButton, "plugin-manager-installed-browse-packs-button")
        XCTAssertEqual(PluginManagerAccessibilityID.environmentRow("Env 1"), "plugin-manager-environment-env-1")
        XCTAssertEqual(PluginManagerAccessibilityID.packCard("core_tools"), "plugin-manager-pack-core-tools")
        XCTAssertEqual(PluginManagerAccessibilityID.databaseDownloadButton("Kraken2 Standard"), "plugin-manager-database-download-kraken2-standard")
        XCTAssertEqual(PluginManagerAccessibilityID.databaseDismissErrorButton("RVDB/2026"), "plugin-manager-database-dismiss-error-rvdb-2026")
    }

    func testSettingsWindowUsesStableWindowIdentifier() {
        let controller = SettingsWindowController()

        XCTAssertEqual(controller.window?.identifier?.rawValue, SettingsAccessibilityID.window)
    }

    func testStorageSettingsUsesSheetModalChooserAndStableIdentifiers() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("beginSheetModal(for: window"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.storageForm"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.storageChangeLocationButton"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.storageCleanupButton"))
        XCTAssertFalse(source.contains("DispatchQueue.main.async"))
    }

    func testAISettingsSourceAppliesStableXCUIIdentifiersAndStaleWriteGuards() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiSearchToggle"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiPreferredProviderPicker"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiAnthropicKeyField"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiOpenAIKeyField"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiGeminiKeyField"))
        XCTAssertTrue(source.contains("cancelPendingSaves()"))
        XCTAssertTrue(source.contains("shouldApplyValidationResult(expectedKey: value, provider: provider)"))
    }

    func testImportCenterSourceAppliesStableXCUIIdentifiers() throws {
        let viewSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/ImportCenter/ImportCenterWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.root"))
        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.sidebar"))
        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.cardList"))
        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.tab(tab)"))
        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.cardID(card.id)"))
        XCTAssertTrue(viewSource.contains("ImportCenterAccessibilityID.buttonID(card.id)"))
        XCTAssertTrue(viewSource.contains("LockedURLCollector"))
        XCTAssertTrue(controllerSource.contains("ImportCenterAccessibilityID.window"))
    }

    func testAppDelegateFinderOpenPathUsesPreflightAndProjectRouting() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func canQueueDocumentOpen(at url: URL) -> DocumentType?"))
        XCTAssertTrue(source.contains("sender.reply(toOpenOrPrint: allQueued ? .success : .failure)"))
        XCTAssertTrue(source.contains("if type == .lungfishProject"))
        XCTAssertTrue(source.contains("let controller = ensureMainWindowForDocumentOpen()"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
