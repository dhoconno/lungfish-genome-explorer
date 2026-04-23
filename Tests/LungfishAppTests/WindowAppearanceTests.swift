import XCTest

final class WindowAppearanceTests: XCTestCase {

    func testPluginManagerUsesWarmPaletteAndOmitsDecorativePackGlyphs() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCreamsicleFallback"))
        XCTAssertTrue(source.contains("Color.lungfishSageFallback"))
        XCTAssertTrue(source.contains("if pack.category != pack.name"))
        XCTAssertFalse(source.contains("Image(systemName: pack.sfSymbol)"))
        XCTAssertFalse(source.contains("Color.accentColor"))
        XCTAssertFalse(source.contains("case .available"))
        XCTAssertFalse(source.contains("Search bioconda packages"))
        XCTAssertFalse(source.contains(".foregroundStyle(.green)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.red)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.orange)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.blue)"))
    }

    func testInspectorUsesTextTabsInsteadOfIconOnlySegmentLabels() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Text(tab.displayLabel)"))
        XCTAssertFalse(source.contains("Image(systemName: tab.iconName)"))
    }

    func testInspectorUsesSecondarySegmentedControlsForViewAndAnalysisShells() throws {
        let controllerSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift"),
            encoding: .utf8
        )
        let readStyleSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(controllerSource.contains("Picker(\"View Section\""))
        XCTAssertTrue(controllerSource.contains("AlignmentViewSection(viewModel: viewModel.readStyleSectionViewModel)"))
        XCTAssertTrue(controllerSource.contains("AnalysisSection(viewModel: viewModel.readStyleSectionViewModel)"))
        XCTAssertTrue(controllerSource.contains("case .analysis: return \"Analysis\""))
        XCTAssertTrue(controllerSource.contains("case .annotations:"))
        XCTAssertTrue(readStyleSource.contains("Picker(\"Analysis Section\""))
        XCTAssertTrue(readStyleSource.contains("return \"Filtering\""))
        XCTAssertTrue(readStyleSource.contains("return \"Consensus\""))
        XCTAssertTrue(readStyleSource.contains("return \"Variant Calling\""))
        XCTAssertTrue(readStyleSource.contains("return \"Export\""))
    }

    func testPluginManagerAndAIAssistantExposeStableAccessibilityIdentifiers() throws {
        let pluginManagerSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift"),
            encoding: .utf8
        )
        let pluginManagerWindowSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift"),
            encoding: .utf8
        )
        let aiSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/AI/AIAssistantPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.root"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.tab(.installed)"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.installedBrowsePacksButton"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.environmentRow(environment.name)"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.packCard(pack.id)"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.databaseDownloadButton(database.name)"))
        XCTAssertTrue(pluginManagerSource.contains("PluginManagerAccessibilityID.storageSettingsButton"))
        XCTAssertTrue(pluginManagerWindowSource.contains("PluginManagerAccessibilityID.window"))
        XCTAssertTrue(pluginManagerWindowSource.contains("PluginManagerAccessibilityID.toolbarSegmentedControl"))
        XCTAssertTrue(pluginManagerWindowSource.contains("window.setAccessibilityIdentifier(PluginManagerAccessibilityID.window)"))

        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.window"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.root"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.inputField"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.sendButton"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.clearButton"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.thinkingIndicator"))
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.suggestedQueryButton(index)"))
        XCTAssertTrue(aiSource.contains("button.toolTip = query.query"))
        XCTAssertTrue(aiSource.contains("NSApp.activate()"))
    }

    func testToolWindowsUseIconOnlyToolbarsWithoutDecorativeImages() throws {
        let pluginSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift"),
            encoding: .utf8
        )
        let importSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/ImportCenter/ImportCenterWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(pluginSource.contains("toolbar.displayMode = .iconOnly"))
        XCTAssertFalse(pluginSource.contains("setImage("))
        XCTAssertFalse(pluginSource.contains("NSSearchToolbarItem"))
        XCTAssertFalse(importSource.contains("NSSegmentedControl"))
        XCTAssertFalse(importSource.contains("NSSearchToolbarItem"))
    }

    func testImportCenterUsesWarmPaletteAndOmitsDecorativeCardGlyphs() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishStroke"))
        XCTAssertTrue(source.contains("importSidebar"))
        XCTAssertFalse(source.contains("recentImportsSection"))
        XCTAssertFalse(source.contains("Image(systemName: viewModel.selectedTab.sfSymbol)"))
        XCTAssertFalse(source.contains("if let customImage = card.customImage"))
        XCTAssertFalse(source.contains("Image(systemName: card.sfSymbol)"))
    }

    func testMetagenomicsWizardHeadersOmitDecorativeHeroIcons() throws {
        let classificationSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift"),
            encoding: .utf8
        )
        let esvirituSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift"),
            encoding: .utf8
        )
        let taxtriageSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(classificationSource.contains("Image(systemName: \"k.circle\")"))
        XCTAssertFalse(esvirituSource.contains("Image(systemName: \"e.circle\")"))
        XCTAssertFalse(taxtriageSource.contains("Image(systemName: \"t.circle\")"))
        XCTAssertFalse(classificationSource.contains("Color.accentColor"))
        XCTAssertFalse(esvirituSource.contains("Color.accentColor"))
        XCTAssertFalse(taxtriageSource.contains("Color.accentColor"))
    }

    func testUnifiedClassifierRunnerUsesSharedShellLayout() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("HStack(spacing: 0)"))
        XCTAssertTrue(source.contains("runnerSidebar"))
        XCTAssertTrue(source.contains("runnerDetail"))
        XCTAssertTrue(source.contains("footerBar"))
        XCTAssertTrue(source.contains("UnifiedClassifierRunnerSection"))
        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertFalse(source.contains("WizardStep"))
        XCTAssertFalse(source.contains("analysisTypeSelector"))
    }

    func testToolPanelsRetainStandaloneShellAndSizing() throws {
        let classificationSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift"),
            encoding: .utf8
        )
        let esvirituSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift"),
            encoding: .utf8
        )
        let taxtriageSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(classificationSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(esvirituSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(taxtriageSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(classificationSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(esvirituSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(taxtriageSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(classificationSource.contains(#"Button("Cancel")"#))
        XCTAssertTrue(esvirituSource.contains(#"Button("Cancel")"#))
        XCTAssertTrue(taxtriageSource.contains(#"Button("Cancel")"#))
        XCTAssertTrue(classificationSource.contains(#"Button("Run")"#))
        XCTAssertTrue(esvirituSource.contains(#"Button("Run")"#))
        XCTAssertTrue(taxtriageSource.contains(#"Button("Run")"#))
        XCTAssertTrue(classificationSource.contains(".frame(width: 520, height: 520)"))
        XCTAssertTrue(esvirituSource.contains(".frame(width: 520, height: 500)"))
        XCTAssertTrue(taxtriageSource.contains(".frame(width: 520, height: 520)"))
    }

    func testEmbeddedClassificationPanelUsesScrollView() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(source.contains("standaloneBody"))
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains("configurationContent"))
        XCTAssertTrue(source.contains("if !embeddedInOperationsDialog"))
    }

    func testMapReadsSheetSupportsEmbeddedOperationsDialogMode() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/MapReadsWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(source.contains("embeddedRunTrigger"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange"))
        XCTAssertTrue(source.contains("if embeddedInOperationsDialog"))
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".onChange(of: embeddedRunTrigger)"))
        XCTAssertTrue(source.contains("performRun()"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange?(canRun)"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange?(newValue)"))
        XCTAssertTrue(source.contains("headerSection"))
        XCTAssertTrue(source.contains("footerSection"))
        XCTAssertTrue(source.contains("width: embeddedInOperationsDialog ? nil : 520"))
        XCTAssertTrue(source.contains("height: embeddedInOperationsDialog ? nil : 520"))
        XCTAssertFalse(source.contains("embeddedInUnifiedRunner"))
    }

    func testAssemblySheetSupportsEmbeddedOperationsDialogMode() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(source.contains("embeddedRunTrigger"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange"))
        XCTAssertTrue(source.contains("if embeddedInOperationsDialog"))
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".onChange(of: embeddedRunTrigger)"))
        XCTAssertTrue(source.contains("performRun()"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange?(canRun)"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange?(newValue)"))
        XCTAssertTrue(source.contains("headerSection"))
        XCTAssertTrue(source.contains("footerSection"))
        XCTAssertTrue(source.contains("width: embeddedInOperationsDialog ? nil : 620"))
        XCTAssertTrue(source.contains("height: embeddedInOperationsDialog ? nil : 640"))
        XCTAssertFalse(source.contains("embeddedInUnifiedRunner"))
    }

    func testDatasetOperationsDialogUsesTwoPaneSharedShell() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("HStack(spacing: 0)"))
        XCTAssertTrue(source.contains("toolSidebar"))
        XCTAssertTrue(source.contains("detailPane"))
        XCTAssertTrue(source.contains("footerBar"))
        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertTrue(source.contains("Color.lungfishSidebarBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishStroke"))
        XCTAssertTrue(source.contains("Color.lungfishCreamsicleFallback"))
        XCTAssertTrue(source.contains(".tint(.lungfishCreamsicleFallback)"))
        XCTAssertFalse(source.contains("Color.accentColor"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
