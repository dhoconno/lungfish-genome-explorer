import XCTest
@testable import LungfishApp

@MainActor
final class SettingsAndImportXCUIReadinessTests: XCTestCase {

    func testSettingsAccessibilityIdentifierCatalogIsStable() {
        XCTAssertEqual(SettingsAccessibilityID.window, "settings-window")
        XCTAssertEqual(SettingsAccessibilityID.root, "settings-root")
        XCTAssertEqual(SettingsAccessibilityID.tab(.general), "settings-tab-general")
        XCTAssertEqual(SettingsAccessibilityID.tab(.storage), "settings-tab-storage")
        XCTAssertEqual(SettingsAccessibilityID.tab(.advanced), "settings-tab-advanced")
        XCTAssertEqual(SettingsAccessibilityID.panel(.aiServices), "settings-panel-ai-services")
        XCTAssertEqual(SettingsAccessibilityID.panel(.advanced), "settings-panel-advanced")
        XCTAssertEqual(SettingsAccessibilityID.storageChangeLocationButton, "settings-storage-change-location-button")
        XCTAssertEqual(SettingsAccessibilityID.aiOpenAIKeyField, "settings-ai-openai-key-field")
        XCTAssertEqual(SettingsAccessibilityID.aiClearKeysButton, "settings-ai-clear-keys-button")
        XCTAssertEqual(SettingsAccessibilityID.experimentalFeaturesToggle, "settings-advanced-experimental-features-toggle")
        XCTAssertEqual(SettingsAccessibilityID.analystIdentityField, "settings-general-analyst-identity-field")
        XCTAssertEqual(SettingsAccessibilityID.contentTextSizePicker, "settings-appearance-content-text-size-picker")
        XCTAssertEqual(InspectorAccessibilityID.analystIdentityLabel, "genotype-annotation-analyst-identity-label")
        XCTAssertEqual(InspectorAccessibilityID.analystIdentitySettingsButton, "genotype-annotation-analyst-identity-settings-button")
        XCTAssertEqual(InspectorAccessibilityID.genotypeVisibilityGroup, "genotype-view-visibility-group")
        XCTAssertEqual(InspectorAccessibilityID.genotypeVisibilityScope, "genotype-view-visibility-scope")
        XCTAssertEqual(InspectorAccessibilityID.genotypeVisibilityStatus, "genotype-view-visibility-status")
        XCTAssertEqual(InspectorAccessibilityID.genotypeVisibilityGuidance, "genotype-view-visibility-guidance")
        XCTAssertEqual(InspectorAccessibilityID.genotypeRowVisibilityMenu, "genotype-view-row-visibility-menu")
        XCTAssertEqual(InspectorAccessibilityID.genotypeHideSelectedRows, "genotype-view-hide-selected-rows")
        XCTAssertEqual(InspectorAccessibilityID.genotypeShowOnlySelectedRows, "genotype-view-show-only-selected-rows")
        XCTAssertEqual(InspectorAccessibilityID.genotypeShowAllRows, "genotype-view-show-all-rows")
        XCTAssertEqual(InspectorAccessibilityID.genotypeColumnVisibilityMenu, "genotype-view-column-visibility-menu")
        XCTAssertEqual(InspectorAccessibilityID.genotypeHideSelectedColumns, "genotype-view-hide-selected-columns")
        XCTAssertEqual(InspectorAccessibilityID.genotypeShowOnlySelectedColumns, "genotype-view-show-only-selected-columns")
        XCTAssertEqual(InspectorAccessibilityID.genotypeShowAllColumns, "genotype-view-show-all-columns")
        XCTAssertEqual(InspectorAccessibilityID.genotypeResetVisibility, "genotype-view-reset-visibility")
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
        XCTAssertEqual(MainMenuAccessibilityID.contentTextSize, "view-menu-content-text-size")
        XCTAssertEqual(MainMenuAccessibilityID.contentTextSizeLarger, "view-menu-content-text-size-larger")
        XCTAssertEqual(MainMenuAccessibilityID.contentTextSizeSmaller, "view-menu-content-text-size-smaller")
        XCTAssertEqual(MainMenuAccessibilityID.contentTextSizeDefault, "view-menu-content-text-size-default")
        XCTAssertEqual(MainMenuAccessibilityID.newProject, "file-menu-new-project")
        XCTAssertEqual(MainMenuAccessibilityID.importCenter, "file-menu-import-center")
        XCTAssertEqual(MainMenuAccessibilityID.callVariants, "tools-menu-call-variants")
        XCTAssertEqual(MainMenuAccessibilityID.freyjaDemix, "tools-menu-freyja-demix")
        XCTAssertEqual(MainMenuAccessibilityID.workflowLibrary, "tools-menu-workflow-library")
        XCTAssertEqual(MainMenuAccessibilityID.workflowBuilder, "tools-menu-workflow-builder")
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

    func testSettingsWindowDefaultWidthShowsAllTabs() throws {
        let window = try XCTUnwrap(SettingsWindowController().window)

        XCTAssertGreaterThanOrEqual(window.frame.width, 820)
        XCTAssertGreaterThanOrEqual(window.minSize.width, 820)
        XCTAssertEqual(window.toolbarStyle, .unified)
    }

    func testStorageSettingsUsesSheetModalChooserAndStableIdentifiers() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift"),
            encoding: .utf8
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // StorageSettingsTab is a pure SwiftUI View; no ViewInspector/snapshot harness
        // exists in this repo to observe modal-chooser wiring or accessibility
        // identifiers assigned inside its body at runtime.
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // AIServicesSettingsTab is a pure SwiftUI View; no rendering/inspection harness
        // exists in this repo to observe identifiers/guards at runtime.
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiSearchToggle"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiPreferredProviderPicker"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiAnthropicKeyField"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiOpenAIKeyField"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.aiGeminiKeyField"))
        XCTAssertTrue(source.contains("cancelPendingSaves()"))
        XCTAssertTrue(source.contains("shouldApplyValidationResult(expectedKey: value, provider: provider)"))
    }

    func testAzureAISettingsArePresentedAsTheirOwnProviderAgnosticSection() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift"),
            encoding: .utf8
        )
        let openAISectionStart = try XCTUnwrap(source.range(of: "Section(\"OpenAI\")"))
        let nextSectionStart = try XCTUnwrap(source.range(of: "Section(\"Google Gemini\")", range: openAISectionStart.upperBound..<source.endIndex))
        let openAISection = source[openAISectionStart.lowerBound..<nextSectionStart.lowerBound]

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("Section(\"Azure AI\")"))
        XCTAssertTrue(source.contains("Use Azure AI-hosted endpoint"))
        XCTAssertFalse(openAISection.contains("openAIHostedEndpointEnabled"))
        XCTAssertFalse(openAISection.contains("Advanced Hosted Endpoint"))
    }

    func testAdvancedSettingsSourceAppliesStableXCUIIdentifiersAndExperimentalToggle() throws {
        let settingsSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let advancedSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/AdvancedSettingsTab.swift"),
            encoding: .utf8
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // SettingsView / AdvancedSettingsTab are pure SwiftUI Views; no rendering/
        // inspection harness exists in this repo to observe body wiring at runtime.
        XCTAssertTrue(settingsSource.contains("AdvancedSettingsTab()"))
        XCTAssertTrue(settingsSource.contains("SettingsAccessibilityID.panel(.advanced)"))
        XCTAssertTrue(advancedSource.contains("SettingsAccessibilityID.experimentalFeaturesToggle"))
        XCTAssertTrue(advancedSource.contains("settings.experimentalFeaturesEnabled"))
    }

    func testAppearanceSettingsExposeAccessibleContentTextSizePicker() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/AppearanceSettingsTab.swift"),
            encoding: .utf8
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // AppearanceSettingsTab is a pure SwiftUI View; no rendering/inspection harness
        // exists in this repo to observe body content/bindings at runtime.
        XCTAssertTrue(source.contains("Section(\"Content Text Size\")"))
        XCTAssertTrue(source.contains("Text(\"System\")"))
        XCTAssertTrue(source.contains("ContentTextSizePreference.supportedPercentages"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.contentTextSizePicker"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Content text size\")"))
        XCTAssertTrue(source.contains("settings.contentTextSizePreference ="))
        XCTAssertTrue(source.contains("settings.save()"))
        XCTAssertFalse(source.contains(".onChange(of: colorA)"))
        XCTAssertFalse(source.contains(".onChange(of: colorT)"))
        XCTAssertFalse(source.contains(".onChange(of: colorG)"))
        XCTAssertFalse(source.contains(".onChange(of: colorC)"))
        XCTAssertFalse(source.contains(".onChange(of: colorN)"))
        XCTAssertFalse(source.contains(".onChange(of: colorU)"))
        XCTAssertFalse(source.contains(".onChange(of: settings.variantColorThemeName)"))
        XCTAssertFalse(source.contains(".onChange(of: settings.defaultAnnotationHeight)"))
        XCTAssertFalse(source.contains(".onChange(of: settings.defaultAnnotationSpacing)"))
        XCTAssertFalse(source.contains(".onChange(of: settings.horizontalScrollDirection)"))
        XCTAssertFalse(source.contains(".onChange(of: settings.verticalScrollDirection)"))
        XCTAssertTrue(source.contains("selection: variantColorThemeSelection"))
        XCTAssertTrue(source.contains("value: annotationHeightSelection"))
        XCTAssertTrue(source.contains("value: annotationSpacingSelection"))
        XCTAssertTrue(source.contains("selection: horizontalScrollDirectionSelection"))
        XCTAssertTrue(source.contains("selection: verticalScrollDirectionSelection"))
    }

    func testAnalystIdentitySettingsAndInspectorUseStableIdentifiersAndResolvedAuthors() throws {
        let root = repositoryRoot()
        let generalSettingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift"),
            encoding: .utf8
        )
        let inspectorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorView.swift"),
            encoding: .utf8
        )
        let inspectorControllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift"),
            encoding: .utf8
        )
        let genotypeControllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift"),
            encoding: .utf8
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // GeneralSettingsTab / InspectorView are pure SwiftUI Views (no rendering harness).
        // InspectorViewController's resolvedAnalystIdentity() is private with no
        // testing-prefixed wrapper. GenotypeResultViewController.annotationAuthorProvider
        // IS a real `public var` closure property -- a genuine seam this task did not
        // exploit (a test could construct the controller, override the provider, trigger
        // an annotation-authoring action, and assert the injected author was used instead
        // of NSUserName()) -- left as a named follow-up rather than converted in this fix
        // round to avoid scope creep beyond the two findings requested.
        XCTAssertTrue(generalSettingsSource.contains("SettingsAccessibilityID.analystIdentityField"))
        XCTAssertTrue(generalSettingsSource.contains("settings.analystIdentityOverride"))
        XCTAssertTrue(inspectorSource.contains("InspectorAccessibilityID.analystIdentityLabel"))
        XCTAssertTrue(inspectorSource.contains("InspectorAccessibilityID.analystIdentitySettingsButton"))
        XCTAssertTrue(inspectorControllerSource.contains("resolvedAnalystIdentity()"))
        XCTAssertTrue(genotypeControllerSource.contains("annotationAuthorProvider"))
        XCTAssertTrue(genotypeControllerSource.contains("annotationAuthorProvider: () -> String = { NSUserName() }"))
        XCTAssertTrue(genotypeControllerSource.contains("author: annotationAuthorProvider()"))
        XCTAssertFalse(genotypeControllerSource.contains("author: NSUserName()"))
        XCTAssertFalse(inspectorControllerSource.contains("NSUserName()"))
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // ImportCenterView is a pure SwiftUI View (no rendering harness).
        // ImportCenterWindowController's only initializer is `private init()` reached via
        // the `show()` singleton (same pattern as PluginManagerWindowController elsewhere
        // in this tranche), so a test would create/leak a real visible app window through
        // the shared singleton -- no safe, isolated construction path exists.
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
        // Behavioral replacement for a prior source-text assertion (tranche 1,
        // 2026-08-21): exercises the real Finder-open preflight guard and
        // project-routing path through AppDelegate.openDocument(at:), rather
        // than checking for the presence of the guard/routing source lines.
        let delegate = AppDelegate()

        // Preflight guard: a nonexistent path must be refused before any
        // window is created (no mainWindowController should be set).
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsAndImportXCUIReadinessTests-missing-\(UUID().uuidString).lungfish")
        XCTAssertFalse(delegate.openDocument(at: missingURL))
        XCTAssertNil(delegate.mainWindowController)

        // Project routing: a real .lungfish project must be queued
        // successfully and routed through project-open, ending up as the
        // delegate's main window controller.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateFinderOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let projectURL = temp.appendingPathComponent("Finder.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Finder")

        XCTAssertTrue(delegate.openDocument(at: projectURL))
        let controller = try XCTUnwrap(delegate.mainWindowController)
        XCTAssertEqual(
            controller.projectSession.projectURL?.standardizedFileURL,
            projectURL.standardizedFileURL
        )
    }

    func testAppDelegateRespondsToVariantCallingMenuSelector() {
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: NSSelectorFromString("showBAMVariantCalling:"))
        )
    }

    func testAppDelegateRespondsToWorkflowBuilderMenuSelector() {
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: NSSelectorFromString("showWorkflowBuilder:"))
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
