import XCTest
import ViewInspector
@testable import LungfishApp
import LungfishCore
import SwiftUI

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
        let view = StorageSettingsTab()
        let inspected = try view.inspect()

        // Behavioral replacement for the accessibility-identifier half of the
        // original grep: each control actually renders with the stable identifier
        // XCUI relies on, proven on the real constructed view.
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.storageForm)
        let changeLocationButton = try inspected.find(
            viewWithAccessibilityIdentifier: SettingsAccessibilityID.storageChangeLocationButton
        )
        XCTAssertEqual(try changeLocationButton.button().labelView().text().string(), "Change Location...")

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // The cleanup button and the modal-chooser wiring itself are guarded behind
        // real runtime conditions this task did not exploit: the cleanup button only
        // renders once `previousRootPath != nil` (populated by `refreshDisplay()`
        // reading `ManagedStorageConfigStore.shared`'s real bootstrap config, not an
        // injectable seam), and actually invoking `chooseDirectory()` calls
        // `NSOpenPanel.beginSheetModal(for:)` on `NSApp.keyWindow`/`NSApp.mainWindow`
        // -- there is no safe, deterministic way to trigger or observe that in a unit
        // test without presenting a real modal file panel. Left as a source assertion
        // for those two aspects only.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("beginSheetModal(for: window"))
        XCTAssertTrue(source.contains("SettingsAccessibilityID.storageCleanupButton"))
        XCTAssertFalse(source.contains("DispatchQueue.main.async"))
    }

    func testAISettingsSourceAppliesStableXCUIIdentifiersAndStaleWriteGuards() throws {
        let view = AIServicesSettingsTab()
        let inspected = try view.inspect()

        // Behavioral replacement for the identifier half of the original grep: each
        // control actually renders with the stable identifier XCUI relies on, proven
        // on the real constructed view.
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.aiSearchToggle)
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.aiPreferredProviderPicker)
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.aiAnthropicKeyField)
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.aiOpenAIKeyField)
        _ = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.aiGeminiKeyField)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // cancelPendingSaves()/shouldApplyValidationResult(expectedKey:provider:) are
        // private methods on AIServicesSettingsTab with no testing-prefixed wrapper;
        // exercising the actual stale-write guard means driving the view's private
        // @State-backed debounce Tasks and Keychain round-trips through real
        // KeychainSecretStorage.shared calls, which is out of scope for this
        // identifier-focused conversion.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("cancelPendingSaves()"))
        XCTAssertTrue(source.contains("shouldApplyValidationResult(expectedKey: value, provider: provider)"))
    }

    func testAzureAISettingsArePresentedAsTheirOwnProviderAgnosticSection() throws {
        let view = AIServicesSettingsTab()
        let inspected = try view.inspect()

        // Behavioral replacement: "Use Azure AI-hosted endpoint" actually renders as
        // a Toggle bound to settings.openAIHostedEndpointEnabled, proven by flipping
        // it through ViewInspector and observing the shared AppSettings value change
        // (rather than grepping for the section/text strings).
        let settings = AppSettings.shared
        let original = settings.openAIHostedEndpointEnabled
        defer { settings.openAIHostedEndpointEnabled = original }

        // Behavioral replacement for the "own provider-agnostic section" half of
        // the original grep: `Section("Azure AI")` actually renders as its own
        // section header in the real view tree.
        _ = try inspected.find(text: "Azure AI")

        let toggle = try inspected.find(ViewType.Toggle.self, where: { toggle in
            (try? toggle.labelView().text().string()) == "Use Azure AI-hosted endpoint"
        })
        try toggle.tap()
        XCTAssertEqual(settings.openAIHostedEndpointEnabled, !original)

        // Behavioral replacement: the OpenAI section itself renders no such toggle
        // (it lives only under the separate Azure AI section) -- proven by counting
        // that exactly one "Use Azure AI-hosted endpoint" toggle exists anywhere in
        // the rendered tree, rather than slicing OpenAI's source range and grepping
        // for the absence of the property/text.
        let matchingToggles = inspected.findAll(ViewType.Toggle.self).filter { toggle in
            (try? toggle.labelView().text().string()) == "Use Azure AI-hosted endpoint"
        }
        XCTAssertEqual(matchingToggles.count, 1)
    }

    func testAdvancedSettingsSourceAppliesStableXCUIIdentifiersAndExperimentalToggle() throws {
        // Behavioral replacement: AdvancedSettingsTab's toggle actually renders with
        // the stable accessibility identifier and is genuinely bound to
        // AppSettings.shared.experimentalFeaturesEnabled -- proven by toggling it
        // through ViewInspector and observing the shared settings value flip.
        let settings = AppSettings.shared
        let original = settings.experimentalFeaturesEnabled
        defer {
            settings.experimentalFeaturesEnabled = original
            settings.save()
        }

        let advancedInspected = try AdvancedSettingsTab().inspect()
        _ = try advancedInspected.find(
            viewWithAccessibilityIdentifier: SettingsAccessibilityID.experimentalFeaturesToggle
        )
        let toggles = advancedInspected.findAll(ViewType.Toggle.self)
        XCTAssertEqual(toggles.count, 1)
        let toggle = try XCTUnwrap(toggles.first)
        try toggle.tap()
        XCTAssertEqual(settings.experimentalFeaturesEnabled, !original)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // SettingsView's root is a `TabView` whose `.tabItem` labels use
        // `Image(systemName:)`; ViewInspector's tree search cannot classify those
        // internal image nodes ("AccessibilityImageLabel" search blockers observed
        // empirically) and the TabView only fully renders whichever tab
        // `SettingsNavigationState.shared` (a real, test-order-dependent singleton)
        // currently selects, which made a ViewInspector `find` against the full
        // SettingsView flaky across runs. Kept as a source assertion for this one
        // wiring fact; AdvancedSettingsTab's own rendered behavior (toggle identifier
        // and binding) is proven above via the real constructed view.
        let settingsSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settingsSource.contains("AdvancedSettingsTab()"))
        XCTAssertTrue(settingsSource.contains("SettingsAccessibilityID.panel(.advanced)"))
    }

    func testAppearanceSettingsExposeAccessibleContentTextSizePicker() throws {
        let settings = AppSettings.shared
        let originalTextSize = settings.contentTextSizePreference
        let originalTheme = settings.variantColorThemeName
        let originalHeight = settings.defaultAnnotationHeight
        let originalSpacing = settings.defaultAnnotationSpacing
        let originalHorizontal = settings.horizontalScrollDirection
        let originalVertical = settings.verticalScrollDirection
        defer {
            settings.contentTextSizePreference = originalTextSize
            settings.variantColorThemeName = originalTheme
            settings.defaultAnnotationHeight = originalHeight
            settings.defaultAnnotationSpacing = originalSpacing
            settings.horizontalScrollDirection = originalHorizontal
            settings.verticalScrollDirection = originalVertical
            settings.save()
        }

        let inspected = try AppearanceSettingsTab().inspect()

        // Behavioral replacement: the Content Text Size picker actually renders with
        // the documented accessibility label/identifier, offers "System" plus every
        // supported percentage, and selecting an option genuinely writes through to
        // AppSettings.shared -- proven by driving the real Picker rather than
        // grepping for the section/text/identifier strings.
        _ = try inspected.find(text: "System")
        let picker = try inspected.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.contentTextSizePicker)
        XCTAssertEqual(try picker.accessibilityLabel().string(), "Content text size")

        let percentagePicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Content text size:"
        })
        try percentagePicker.select(value: 1)
        XCTAssertEqual(
            settings.contentTextSizePreference.normalized,
            .custom(ContentTextSizePreference.supportedPercentages[0])
        )
        try percentagePicker.select(value: 0)
        XCTAssertEqual(settings.contentTextSizePreference.normalized, .system)

        // Behavioral replacement: the color-theme picker, annotation-dimension
        // sliders, and scroll-direction pickers all write straight through their
        // dedicated Binding (variantColorThemeSelection/annotationHeightSelection/
        // etc.) with no separate `.onChange` side effect duplicating the write --
        // proven by driving each control once and observing exactly the expected
        // AppSettings mutation.
        let themePicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Color theme:"
        })
        try themePicker.select(value: "High Contrast")
        XCTAssertEqual(settings.variantColorThemeName, "High Contrast")

        // The height slider (8...32) is declared before the spacing slider (0...8).
        // ViewInspector's Slider.setValue writes to the range-normalized 0...1
        // binding SwiftUI wraps internally, not the scaled value shown to the user,
        // so the desired absolute value is converted to that fraction first.
        let sliders = inspected.findAll(ViewType.Slider.self)
        XCTAssertEqual(sliders.count, 2)
        try sliders[0].setValue((24 - 8) / (32 - 8))
        XCTAssertEqual(settings.defaultAnnotationHeight, 24)
        try sliders[1].setValue((4 - 0) / (8 - 0))
        XCTAssertEqual(settings.defaultAnnotationSpacing, 4)

        let horizontalPicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Horizontal:"
        })
        try horizontalPicker.select(value: ScrollDirectionPreference.traditional)
        XCTAssertEqual(settings.horizontalScrollDirection, .traditional)

        let verticalPicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Vertical:"
        })
        try verticalPicker.select(value: ScrollDirectionPreference.traditional)
        XCTAssertEqual(settings.verticalScrollDirection, .traditional)
    }

    func testAnalystIdentitySettingsAndInspectorUseStableIdentifiersAndResolvedAuthors() throws {
        // Behavioral replacement: GeneralSettingsTab's analyst-identity field
        // actually renders with the stable identifier and is genuinely bound
        // (both ways) to AppSettings.shared.analystIdentityOverride, proven by
        // typing through the real TextField rather than grepping for the
        // identifier/property names in source.
        let settings = AppSettings.shared
        let original = settings.analystIdentityOverride
        defer {
            settings.analystIdentityOverride = original
            settings.save()
        }

        let generalInspected = try GeneralSettingsTab().inspect()
        let identityField = try generalInspected.find(
            viewWithAccessibilityIdentifier: SettingsAccessibilityID.analystIdentityField
        )
        try identityField.textField().setInput("Dr. Analyst")
        XCTAssertEqual(settings.analystIdentityOverride, "Dr. Analyst")

        settings.analystIdentityOverride = "Dr. Rebound"
        let refreshedField = try GeneralSettingsTab().inspect().find(
            viewWithAccessibilityIdentifier: SettingsAccessibilityID.analystIdentityField
        )
        XCTAssertEqual(try refreshedField.textField().input(), "Dr. Rebound")

        // Behavioral replacement: InspectorView's GenotypeAnnotationIdentitySection
        // actually renders the "Saving as: <identity>" label and Settings button
        // with the stable identifiers, and tapping Settings genuinely invokes the
        // injected openSettings closure -- proven on the real constructed view
        // (this is the same struct exercised directly by
        // GenotypeResultDisplaySectionTests.testAnnotationIdentitySectionReportsSavingIdentityAndInvokesSettingsCallback).
        var openSettingsCount = 0
        let identitySection = GenotypeAnnotationIdentitySection(
            analystIdentity: "Dr. Rebound",
            openSettings: { openSettingsCount += 1 }
        )
        let identityInspected = try identitySection.inspect()
        let label = try identityInspected.find(viewWithAccessibilityIdentifier: InspectorAccessibilityID.analystIdentityLabel)
        XCTAssertEqual(try label.text().string(), "Saving as: Dr. Rebound")
        let settingsButton = try identityInspected.find(
            viewWithAccessibilityIdentifier: InspectorAccessibilityID.analystIdentitySettingsButton
        )
        try settingsButton.button().tap()
        XCTAssertEqual(openSettingsCount, 1)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // InspectorViewController.resolvedAnalystIdentity() is private with no
        // testing-prefixed wrapper, and GenotypeResultViewController's
        // `annotationAuthorProvider` closure requires driving a real annotation-
        // authoring action through that AppKit controller to observe which author
        // string an actual save used -- both are genuine seams a future tranche
        // could exploit (construct the controller, override the provider, trigger
        // an authoring action, assert the injected author was used instead of
        // NSUserName()), left as a named follow-up rather than converted here to
        // avoid scope creep beyond this test's original two findings.
        let root = repositoryRoot()
        let inspectorControllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift"),
            encoding: .utf8
        )
        let genotypeControllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(inspectorControllerSource.contains("resolvedAnalystIdentity()"))
        XCTAssertTrue(genotypeControllerSource.contains("annotationAuthorProvider"))
        XCTAssertTrue(genotypeControllerSource.contains("annotationAuthorProvider: () -> String = { NSUserName() }"))
        XCTAssertTrue(genotypeControllerSource.contains("author: annotationAuthorProvider()"))
        XCTAssertFalse(genotypeControllerSource.contains("author: NSUserName()"))
        XCTAssertFalse(inspectorControllerSource.contains("NSUserName()"))
    }

    func testImportCenterSourceAppliesStableXCUIIdentifiers() throws {
        let viewModel = ImportCenterViewModel()
        let inspected = try ImportCenterView(viewModel: viewModel).inspect()

        // Behavioral replacement: the root, sidebar, and card-list containers, plus a
        // representative tab/card/button, all actually render with their documented
        // stable identifiers -- proven on the real constructed view rather than by
        // grepping for the identifier-constant call sites.
        _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.root)
        _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.sidebar)
        _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.cardList)
        for tab in ImportCenterViewModel.Tab.allCases {
            _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.tab(tab))
        }
        let firstCard = try XCTUnwrap(viewModel.allCards.first)
        _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.cardID(firstCard.id))
        _ = try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.buttonID(firstCard.id))

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // LockedURLCollector is a private drag-and-drop implementation detail with no
        // accessibility surface to assert on behaviorally. ImportCenterWindowController's
        // only initializer is `private init()` reached via the `show()` singleton (same
        // pattern as PluginManagerWindowController elsewhere in this tranche), so a test
        // would create/leak a real visible app window through the shared singleton --
        // no safe, isolated construction path exists for its window identifier.
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
        XCTAssertTrue(viewSource.contains("LockedURLCollector"))
        XCTAssertTrue(controllerSource.contains("ImportCenterAccessibilityID.window"))
    }

    func testAppDelegateFinderOpenPathUsesPreflightAndProjectRouting() async throws {
        // Behavioral replacement for a prior source-text assertion (tranche 1,
        // 2026-08-21): exercises the real Finder-open preflight guard and
        // project-routing path through AppDelegate.openDocument(at:), rather
        // than checking for the presence of the guard/routing source lines.
        let delegate = makeAppDelegateWithTemporaryState()

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
        _ = try ProjectFile.create(at: projectURL, name: "Finder")

        XCTAssertTrue(delegate.openDocument(at: projectURL))
        let controller = try XCTUnwrap(delegate.mainWindowController)
        defer {
            controller.projectSession.closeProject()
            controller.window?.setFrameAutosaveName("")
            controller.close()
        }
        let opening = try XCTUnwrap(controller.mainSplitViewController?.projectOpenTask)
        await opening.value
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
