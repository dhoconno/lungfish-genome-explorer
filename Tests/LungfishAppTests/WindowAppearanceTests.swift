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

        XCTAssertTrue(source.contains("label: \\.displayLabel"))
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

        XCTAssertTrue(controllerSource.contains("InspectorSubsectionGrid(selection: $viewModel.selectedReadStyleViewSubsection)"))
        XCTAssertTrue(controllerSource.contains("AlignmentViewSection(viewModel: viewModel.readStyleSectionViewModel)"))
        XCTAssertTrue(controllerSource.contains("AnalysisSection(viewModel: viewModel.readStyleSectionViewModel)"))
        XCTAssertTrue(controllerSource.contains("case .analysis: return \"Analysis\""))
        XCTAssertTrue(controllerSource.contains("case .annotations:"))
        XCTAssertTrue(readStyleSource.contains("AnalysisSubsectionGrid(selection: $selectedSubsection)"))
        XCTAssertTrue(readStyleSource.contains("return \"Filtering\""))
        XCTAssertTrue(readStyleSource.contains("return \"Consensus\""))
        XCTAssertTrue(readStyleSource.contains("return \"Variant Calling\""))
        XCTAssertTrue(readStyleSource.contains("return \"Export\""))
    }

    func testInspectorControlsFitFixedWidthSidecar() throws {
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
        let mappingSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(controllerSource.contains("InspectorTabGrid"))
        XCTAssertFalse(controllerSource.contains("Picker(\"Inspector\""))
        XCTAssertTrue(controllerSource.contains("InspectorSubsectionGrid(selection: $viewModel.selectedReadStyleViewSubsection)"))
        XCTAssertTrue(readStyleSource.contains("AnalysisSubsectionGrid(selection: $selectedSubsection)"))
        XCTAssertTrue(mappingSource.contains(".lineLimit(2)"))
        XCTAssertTrue(mappingSource.contains(".truncationMode(.middle)"))
        XCTAssertTrue(mappingSource.contains(".help(text)"))
    }

    func testInspectorControlsDoNotScaleIndividualLabelsToFitSidecar() throws {
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
        let mappingSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(controllerSource.contains(".minimumScaleFactor("))
        XCTAssertFalse(readStyleSource.contains(".minimumScaleFactor("))
        XCTAssertFalse(mappingSource.contains(".minimumScaleFactor("))
        XCTAssertTrue(controllerSource.contains("LungfishInspectorSegmentedButtonGrid"))
        XCTAssertTrue(readStyleSource.contains("LungfishInspectorSegmentedButtonGrid"))
    }

    func testMappingLayoutControlsStayAvailableAndFitFixedWidthSidecar() throws {
        let controllerSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift"),
            encoding: .utf8
        )

        let readStyleSection = try sourceSlice(
            controllerSource,
            from: "private struct InspectorReadStyleSection",
            to: "private struct InspectorSubsectionGrid"
        )
        XCTAssertTrue(readStyleSection.contains("if viewModel.contentMode == .mapping"))
        XCTAssertTrue(readStyleSection.contains("MappingViewSettingsSection(viewModel: viewModel.documentSectionViewModel)"))

        let mappingLayoutSection = try sourceSlice(
            controllerSource,
            from: "private struct MappingViewSettingsSection",
            to: "// MARK: - MetagenomicsResultSummarySection"
        )
        XCTAssertTrue(mappingLayoutSection.contains(".pickerStyle(.radioGroup)"))
        XCTAssertFalse(mappingLayoutSection.contains(".pickerStyle(.segmented)"))
    }

    func testVariantCallingReloadsEmbeddedMappingViewerAfterBundleMutation() throws {
        let controllerSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift"),
            encoding: .utf8
        )
        let variantCallingLaunch = try sourceSlice(
            controllerSource,
            from: "private func launchVariantCallingOperation",
            to: "@MainActor\n    private static func applyVariantCallingEvent"
        )

        XCTAssertTrue(variantCallingLaunch.contains("shouldReloadMappingViewer"))
        XCTAssertTrue(variantCallingLaunch.contains("reloadMappingViewerBundleIfDisplayed()"))
        XCTAssertTrue(variantCallingLaunch.contains("displayBundle(at: bundleURL)"))
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
        let dialogSheetSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Shared/DialogSheets.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(classificationSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(esvirituSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(taxtriageSource.contains("embeddedInOperationsDialog"))
        XCTAssertTrue(classificationSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(esvirituSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(taxtriageSource.contains("if !embeddedInOperationsDialog"))
        XCTAssertTrue(classificationSource.contains(#"Button("Cancel")"#))
        XCTAssertTrue(taxtriageSource.contains(#"Button("Cancel")"#))
        XCTAssertTrue(classificationSource.contains(#"Button("Run")"#))
        XCTAssertTrue(taxtriageSource.contains(#"Button("Run")"#))
        XCTAssertTrue(classificationSource.contains(".frame(width: 520, height: 520)"))
        XCTAssertTrue(taxtriageSource.contains(".frame(width: 520, height: 520)"))

        XCTAssertTrue(esvirituSource.contains("WizardSheet("))
        XCTAssertTrue(esvirituSource.contains("size: WizardSheetSize(width: 520, height: 500)"))
        XCTAssertTrue(esvirituSource.contains("onCancel: { onCancel?() }"))
        XCTAssertTrue(esvirituSource.contains("onPrimary: performRun"))
        XCTAssertTrue(dialogSheetSource.contains(#"cancelTitle: String = "Cancel""#))
        XCTAssertTrue(dialogSheetSource.contains(#"primaryTitle: String = "Run""#))
        XCTAssertTrue(dialogSheetSource.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(dialogSheetSource.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(dialogSheetSource.contains(".frame(width: width, height: height)"))
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

    func testAppKitControlsAvoidDeprecatedTexturedRoundedStyle() throws {
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources/LungfishApp")
        let offenders = try swiftSourceFiles(under: sourceRoot).filter { url in
            let source = try String(contentsOf: url, encoding: .utf8)
            return source.contains(".texturedRounded")
        }.map { url in
            url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
        }.sorted()

        XCTAssertEqual(offenders, [])
    }

    func testDestructiveAlertFirstButtonsUseDestructiveAction() throws {
        struct AlertCase {
            let path: String
            let startToken: String
            let endToken: String
            let label: String
        }

        let cases = [
            AlertCase(
                path: "Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift",
                startToken: "@objc public func deleteSelectedItems()",
                endToken: "/// Performs the actual deletion of items",
                label: "sidebar move to trash"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift",
                startToken: "@objc private func contextMenuDeleteVariantTracks",
                endToken: "private func performDeleteVariantTracks",
                label: "sidebar variant track deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift",
                startToken: "private func confirmRemoveDerivedAlignment",
                endToken: "private func runRemoveDerivedAlignmentWorkflow",
                label: "derived alignment removal"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift",
                startToken: "private func deleteSelectedWorkflowInLibrary",
                endToken: "private func promptForWorkflowName",
                label: "workflow deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift",
                startToken: "didRequestDeleteAnnotations annotations",
                endToken: "private func runAnnotationRowDeletion",
                label: "annotation row deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift",
                startToken: "didRequestDeleteAnnotationTrack trackID",
                endToken: "private func runAnnotationTrackDeletion",
                label: "annotation track deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift",
                startToken: "@objc private func deleteSelectedVariantsAction",
                endToken: "@objc private func deleteAllVariantsAction",
                label: "selected variant deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift",
                startToken: "@objc private func deleteAllVariantsAction",
                endToken: "private func performVariantDeletion",
                label: "all variants deletion"
            ),
            AlertCase(
                path: "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift",
                startToken: "@objc private func deleteSampleMetadataFieldAction",
                endToken: "alert.beginSheetModal(for: window)",
                label: "sample metadata column deletion"
            ),
        ]

        for alertCase in cases {
            let source = try String(
                contentsOf: repositoryRoot().appendingPathComponent(alertCase.path),
                encoding: .utf8
            )
            let slice = try sourceSlice(source, from: alertCase.startToken, to: alertCase.endToken)
            XCTAssertTrue(
                slice.contains("hasDestructiveAction = true"),
                "Missing destructive action marker for \(alertCase.label)"
            )
        }
    }

    private func sourceSlice(_ source: String, from startToken: String, to endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endToken, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }

    func testMapReadsWizardSheetIsNotPartOfActiveAppSources() throws {
        let root = repositoryRoot()
        let sheetURL = root.appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/MapReadsWizardSheet.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sheetURL.path))

        let sourceRoot = root.appendingPathComponent("Sources")
        let references = try swiftSourceFiles(under: sourceRoot).filter { url in
            let source = try String(contentsOf: url, encoding: .utf8)
            return source.contains("MapReadsWizardSheet")
        }.map { url in
            url.path.replacingOccurrences(of: root.path + "/", with: "")
        }.sorted()

        XCTAssertEqual(references, [])
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

    private func swiftSourceFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }
}
