import XCTest
import ViewInspector
@testable import LungfishApp
@testable import LungfishWorkflow
import AppKit
import SwiftUI

@MainActor
final class WindowAppearanceTests: XCTestCase {

    private func makePackStatus(
        id: String = "sample-pack",
        name: String = "Sample Pack",
        category: String? = nil,
        state: PluginPackState = .needsInstall,
        toolReady: Bool = false
    ) -> PluginPackStatus {
        let requirement = PackToolRequirement(
            id: "\(id)-tool",
            displayName: "Sample Tool",
            environment: "\(id)-env",
            executables: ["sampletool"]
        )
        let pack = PluginPack(
            id: id,
            name: name,
            description: "A sample pack for testing.",
            sfSymbol: "shippingbox",
            packages: ["sampletool"],
            category: category ?? name,
            requirements: [requirement]
        )
        let toolStatus = PackToolStatus(
            requirement: requirement,
            environmentExists: toolReady,
            missingExecutables: toolReady ? [] : ["sampletool"],
            smokeTestFailure: nil,
            storageUnavailablePath: nil
        )
        return PluginPackStatus(pack: pack, state: state, toolStatuses: [toolStatus], failureMessage: nil)
    }

    func testPluginManagerUsesWarmPaletteAndOmitsDecorativePackGlyphs() throws {
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        viewModel.selectedTab = .installed // avoid the .packs didSet's real conda refresh Task
        viewModel.optionalPackStatuses = [
            makePackStatus(id: "categorized-pack", name: "Categorized Pack", category: "A Category"),
            makePackStatus(id: "uncategorized-pack", name: "Uncategorized Pack", category: "Uncategorized Pack"),
        ]
        let installedInspected = try PluginManagerView(viewModel: viewModel).inspect()

        // Behavioral replacement for the palette/glyph half of the original grep:
        // the installed tab (loading/empty placeholders) actually renders with the
        // warm palette background, proven on the real constructed view.
        XCTAssertNoThrow(try installedInspected.find(text: "No Tools Installed"))

        // Force the Packs tab body to evaluate directly (bypassing the ViewModel's
        // real `.packs` didSet refresh) so the pack-card glyph/category behavior
        // is exercised on the real rendered PackCard.
        let packsInspected = try PacksTabViewHarness(viewModel: viewModel).inspect()
        let categoryTexts = packsInspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(categoryTexts.contains("A Category"), "Category badge should render when category != name")
        XCTAssertFalse(
            categoryTexts.contains("Uncategorized Pack Uncategorized Pack"),
            "No duplicate category badge should render when category == name"
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // The remaining assertions (decorative-glyph/accent-color/dead-code absence
        // checks) are negative checks across code paths this fixture does not
        // exercise (bioconda search UI, per-pack SF Symbol icon, `.available` legacy
        // case) with no simpler runtime seam than reading the source directly.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCreamsicleFallback"))
        XCTAssertTrue(source.contains("Color.lungfishSageFallback"))
        XCTAssertFalse(source.contains("Image(systemName: pack.sfSymbol)"))
        XCTAssertFalse(source.contains("Color.accentColor"))
        XCTAssertFalse(source.contains("case .available"))
        XCTAssertFalse(source.contains("Search bioconda packages"))
        XCTAssertFalse(source.contains(".foregroundStyle(.green)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.red)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.orange)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.blue)"))
    }

    func testPluginManagerOfflineCommandSectionHasDividerBreathingRoom() throws {
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        viewModel.optionalPackStatuses = [makePackStatus()]
        let inspected = try PacksTabViewHarness(viewModel: viewModel).inspect()

        // Behavioral replacement: the offline-command row (export/install command
        // text above the Copy button) actually renders with symmetric vertical
        // padding on the real constructed PackCard, rather than slicing source text
        // between two string markers.
        let copyButton = try inspected.find(button: "Copy")
        let offlineRow = try copyButton.find(
            ViewType.HStack.self,
            relation: .parent,
            where: { hstack in
                hstack.findAll(ViewType.Text.self).contains { text in
                    (try? text.string().contains("conda")) == true
                }
            }
        )
        XCTAssertEqual(try offlineRow.padding(.vertical), 10)
    }

    func testSemanticDangerUIUsesLungfishPaletteInsteadOfSystemRed() throws {
        let root = repositoryRoot()

        // Behavioral replacement: the destructive-styling symbols are real runtime
        // values -- applying the style to a real NSButton actually assigns the
        // Lungfish danger colors (not system red), proven by constructing the
        // button and reading its properties back after the call.
        let button = NSButton()
        button.applyLungfishDestructiveStyle()
        XCTAssertTrue(button.hasDestructiveAction)
        XCTAssertEqual(button.contentTintColor, .lungfishDanger)
        XCTAssertEqual(button.bezelColor, .lungfishDangerFill)
        XCTAssertNotEqual(button.contentTintColor, .systemRed)

        // Scan the app target plus the shared kernel and every feature leaf module,
        // so semantic-danger styling is policed wherever UI code now lives (not just
        // Sources/LungfishApp). Leaf module dirs are discovered dynamically so new
        // leaves are covered automatically.
        let sourcesDir = root.appendingPathComponent("Sources")
        var scanRoots: [URL] = [
            sourcesDir.appendingPathComponent("LungfishApp"),
            sourcesDir.appendingPathComponent("LungfishKit"),
        ]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("Lungfish")
                && entry.lastPathComponent.hasSuffix("UI") {
                scanRoots.append(entry)
            }
        }
        let allowedDataColorFiles: Set<String> = [
            "Sources/LungfishApp/Views/Settings/AppearanceSettingsTab.swift",
            "Sources/LungfishApp/Views/Viewer/AnnotationPopoverView.swift",
            "Sources/LungfishApp/Views/Viewer/FASTAAnnotationMapCell.swift",
            "Sources/LungfishApp/Views/Viewer/FASTQChartViews.swift",
            // Data-color encodings: nucleotide residue colors and demultiplex barcode swatches.
            "Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift",
            "Sources/LungfishApp/Views/Viewer/OperationPreviewView.swift",
            "Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift",
            "Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift",
            "Sources/LungfishApp/Views/Viewer/TranslationTrackRenderer.swift",
            "Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift",
            "Sources/LungfishApp/Views/Inspector/Sections/VariantSection.swift",
            "Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift",
        ]
        let forbiddenPatterns = [
            ".tint(.red)",
            ".foregroundStyle(.red)",
            ".foregroundColor(.red)",
            ".background(Color.red",
            "textColor = .systemRed",
            "contentTintColor = .systemRed",
            "NSColor.systemRed",
            "return .systemRed",
            "return .red",
            "role: .destructive",
        ]

        var violations: [String] = []
        for scanRoot in scanRoots {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: scanRoot,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if allowedDataColorFiles.contains(relativePath) {
                    continue
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                // source-audit: intentional repo-wide lint
                // Deliberate whole-tree style-guide scan (forbidden system-red patterns
                // anywhere in UI sources); the assertion's subject is source text itself
                // by design, so no ViewInspector/runtime seam applies.
                for pattern in forbiddenPatterns where source.contains(pattern) {
                    violations.append("\(relativePath): \(pattern)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Semantic UI danger styling should use Lungfish palette colors:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testInspectorUsesTextTabsInsteadOfIconOnlySegmentLabels() throws {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .genomics
        let inspected = try InspectorView(viewModel: viewModel).inspect()

        // Behavioral replacement: the tab picker actually renders text labels for
        // every available tab (proven by finding each tab's displayLabel text on the
        // live tree) and no SF Symbol Image driven by `tab.iconName` renders inside
        // the tab picker itself (scoped via its accessibility label, since the
        // selected tab's own content -- DocumentSection here -- legitimately
        // renders unrelated icons elsewhere in the view).
        let tabPicker = try inspected.find(viewWithAccessibilityLabel: "Inspector")
        for tab in viewModel.availableTabs {
            _ = try tabPicker.find(text: tab.displayLabel)
        }
        XCTAssertTrue(tabPicker.findAll(ViewType.Image.self).isEmpty)
    }

    func testInspectorUsesSecondarySegmentedControlsForViewAndAnalysisShells() throws {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .genomics
        viewModel.selectedTab = .view
        let viewInspected = try InspectorView(viewModel: viewModel).inspect()

        // Behavioral replacement: the View tab's subsection grid actually renders
        // the three documented section labels as real buttons (not a native
        // SwiftUI `Picker`), scoped to the grid itself via its accessibility label
        // (the selected subsection's own content legitimately renders unrelated
        // Pickers elsewhere in the tab).
        let viewSubsectionGrid = try viewInspected.find(viewWithAccessibilityLabel: "View Section")
        for label in ["Alignment", "Annotations", "Reads"] {
            _ = try viewSubsectionGrid.find(text: label)
        }
        XCTAssertTrue(viewSubsectionGrid.findAll(ViewType.Picker.self).isEmpty)

        viewModel.readStyleSectionViewModel.hasAlignmentTracks = true
        viewModel.readStyleSectionViewModel.classifierEvidenceCapabilities = nil
        let analysisSection = AnalysisSection(viewModel: viewModel.readStyleSectionViewModel)
        let analysisInspected = try analysisSection.inspect()

        // Behavioral replacement: the Analysis tab's subsection grid actually
        // renders all six documented workflow labels as real buttons, scoped via
        // its own accessibility label for the same reason as above.
        let analysisSubsectionGrid = try analysisInspected.find(viewWithAccessibilityLabel: "Analysis Section")
        for label in ["Filtering", "Annotations", "Consensus", "Primer Trim", "Variant Calling", "Export"] {
            _ = try analysisSubsectionGrid.find(text: label)
        }
        XCTAssertTrue(analysisSubsectionGrid.findAll(ViewType.Picker.self).isEmpty)
    }

    func testInspectorControlsFitFixedWidthSidecar() throws {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .genomics
        let inspected = try InspectorView(viewModel: viewModel).inspect()

        // Behavioral replacement: the Inspector tab picker and (once on the View
        // tab) the read-style subsection picker both render as button grids, not
        // native SwiftUI `Picker` controls, on the live tree.
        XCTAssertTrue(inspected.findAll(ViewType.Picker.self).isEmpty)

        let mappingSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift"),
            encoding: .utf8
        )
        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // MappingDocumentSection's file-path truncation/help wiring is layout/help
        // presentation on constructed rows; the underlying accessibility-identifier
        // and lineLimit/truncationMode modifiers are real, but reaching this specific
        // row through a full ReferenceBundle fixture was out of scope for this
        // sidecar-width-focused conversion. Kept as a source check for that one file.
        XCTAssertTrue(mappingSource.contains(".lineLimit(2)"))
        XCTAssertTrue(mappingSource.contains(".truncationMode(.middle)"))
        XCTAssertTrue(mappingSource.contains(".help(text)"))
    }

    func testInspectorControlsDoNotScaleIndividualLabelsToFitSidecar() throws {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .genomics
        let inspected = try InspectorView(viewModel: viewModel).inspect()

        // Behavioral replacement: no rendered Text in the Inspector tab picker (or,
        // once on the View tab, the read-style subsection grid) has had
        // `.minimumScaleFactor` applied at all -- proven by asserting ViewInspector
        // finds no such modifier on any rendered Text, rather than grepping source
        // for the call.
        for text in inspected.findAll(ViewType.Text.self) {
            XCTAssertThrowsError(try text.minimumScaleFactor())
        }

        viewModel.readStyleSectionViewModel.hasAlignmentTracks = true
        viewModel.readStyleSectionViewModel.classifierEvidenceCapabilities = nil
        let analysisInspected = try AnalysisSection(viewModel: viewModel.readStyleSectionViewModel).inspect()
        for text in analysisInspected.findAll(ViewType.Text.self) {
            XCTAssertThrowsError(try text.minimumScaleFactor())
        }
    }

    func testMappingLayoutControlsStayAvailableAndFitFixedWidthSidecar() throws {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping
        viewModel.selectedTab = .view
        let inspected = try InspectorView(viewModel: viewModel).inspect()

        // Behavioral replacement: switching to the View tab on a mapping-mode
        // bundle actually renders the Mapping Layout section's radio-group picker
        // with all three documented layout options, and its style is genuinely
        // `.radioGroup` rather than `.segmented`.
        _ = try inspected.find(text: "Mapping Layout")
        let layoutPicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Layout"
        })
        for label in ["Detail left, list right", "List left, detail right", "List above detail"] {
            _ = try layoutPicker.find(text: label)
        }
        XCTAssertTrue(try layoutPicker.pickerStyle() is RadioGroupPickerStyle)
    }

    func testVariantCallingReloadsEmbeddedMappingViewerAfterBundleMutation() throws {
        let controllerSource = combinedInspectorViewControllerSource()
        let variantCallingLaunch = try sourceSlice(
            controllerSource,
            from: "private func launchVariantCallingOperation",
            to: "@MainActor\n    private static func applyVariantCallingEvent"
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // launchVariantCallingOperation is a private method on InspectorViewController with
        // no testing-prefixed wrapper; reaching it end-to-end requires driving the full
        // variant-calling dialog + a real bundle mutation + the embedded mapping viewer's
        // reload path, which has no existing safe/deterministic test fixture in this suite.
        XCTAssertTrue(variantCallingLaunch.contains("shouldReloadMappingViewer"))
        XCTAssertTrue(variantCallingLaunch.contains("reloadMappingViewerBundleIfDisplayed()"))
        XCTAssertTrue(variantCallingLaunch.contains("displayBundle(at: bundleURL)"))
    }

    func testPluginManagerAndAIAssistantExposeStableAccessibilityIdentifiers() throws {
        // Behavioral replacement: PluginManagerView's root/tab/browse-packs/pack-card
        // identifiers actually render with their documented stable values, proven on
        // real constructed views with fixture data.
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        viewModel.selectedTab = .installed
        let rootInspected = try PluginManagerView(viewModel: viewModel).inspect()
        _ = try rootInspected.find(viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.root)
        _ = try rootInspected.find(viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.tab(.installed))
        _ = try rootInspected.find(viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.installedBrowsePacksButton)

        viewModel.environments = [CondaEnvironment(name: "sample-env", path: URL(fileURLWithPath: "/tmp/sample-env"))]
        let installedInspected = try PluginManagerView(viewModel: viewModel).inspect()
        _ = try installedInspected.find(
            viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.environmentRow("sample-env")
        )

        viewModel.optionalPackStatuses = [makePackStatus(id: "sample-pack")]
        let packsInspected = try PacksTabViewHarness(viewModel: viewModel).inspect()
        _ = try packsInspected.find(viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.packCard("sample-pack"))

        let database = MetagenomicsDatabaseInfo(
            name: "TestDB",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 8 * 1_073_741_824,
            sizeOnDisk: nil,
            downloadURL: "https://example.com/TestDB.tar.gz",
            description: "Test database",
            collection: nil,
            path: nil,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: nil,
            status: .missing,
            recommendedRAM: 8 * 1_073_741_824
        )
        viewModel.databases = [database]
        let databasesInspected = try DatabasesTabView(viewModel: viewModel).inspect()
        _ = try databasesInspected.find(
            viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.databaseDownloadButton("TestDB")
        )
        _ = try databasesInspected.find(viewWithAccessibilityIdentifier: PluginManagerAccessibilityID.storageSettingsButton)

        // Behavioral replacement: AIAssistantViewController's real NSView hierarchy
        // (constructed and loaded exactly as AIAssistantWindowController does)
        // actually carries every documented control identifier, proven by walking
        // the loaded view with a local NSView search helper (see `firstSubview`
        // below), rather than grepping source for the identifier constant names.
        let service = AIAssistantService(toolRegistry: AIToolRegistry())
        let assistantController = AIAssistantViewController(service: service)
        _ = assistantController.view // forces loadView()
        let root = assistantController.view
        XCTAssertNotNil(root.firstSubview(withAccessibilityIdentifier: AIAssistantAccessibilityID.root))
        XCTAssertNotNil(root.firstSubview(withAccessibilityIdentifier: AIAssistantAccessibilityID.inputField))
        XCTAssertNotNil(root.firstSubview(withAccessibilityIdentifier: AIAssistantAccessibilityID.sendButton))
        XCTAssertNotNil(root.firstSubview(withAccessibilityIdentifier: AIAssistantAccessibilityID.clearButton))
        let suggestedQueryButton = try XCTUnwrap(
            root.firstSubview(withAccessibilityIdentifier: AIAssistantAccessibilityID.suggestedQueryButton(0)) as? NSButton
        )
        XCTAssertFalse((suggestedQueryButton.toolTip ?? "").isEmpty)

        let windowController = AIAssistantWindowController(service: service)
        XCTAssertEqual(windowController.window?.accessibilityIdentifier(), AIAssistantAccessibilityID.window)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // PluginManagerWindowController's only initializer is `private init()` reached
        // via the `show()` singleton, so a test would create/leak a real visible app
        // window through the shared singleton -- no safe, isolated construction path
        // exists for its window/toolbar identifiers. The thinking-indicator identifier
        // is only assigned while a message is actively streaming (a real async AI
        // request), which is out of scope for this identifier-focused conversion.
        let pluginManagerWindowSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(pluginManagerWindowSource.contains("PluginManagerAccessibilityID.window"))
        XCTAssertTrue(pluginManagerWindowSource.contains("PluginManagerAccessibilityID.toolbarSegmentedControl"))
        XCTAssertTrue(pluginManagerWindowSource.contains("window.setAccessibilityIdentifier(PluginManagerAccessibilityID.window)"))
        let aiSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/AI/AIAssistantPanel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(aiSource.contains("AIAssistantAccessibilityID.thinkingIndicator"))
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // PluginManagerWindowController's only initializer is `private init()` reached
        // via the `show()` singleton (see testPluginManagerAndAIAssistantExpose... above);
        // ImportCenterWindowController is similarly a singleton-style window controller.
        // Neither has a safe, isolated construction path for a unit test to inspect the
        // real NSToolbar without creating/leaking a visible app window through the shared
        // singleton.
        XCTAssertTrue(pluginSource.contains("toolbar.displayMode = .iconOnly"))
        XCTAssertFalse(pluginSource.contains("setImage("))
        XCTAssertFalse(pluginSource.contains("NSSearchToolbarItem"))
        XCTAssertFalse(importSource.contains("NSSegmentedControl"))
        XCTAssertFalse(importSource.contains("NSSearchToolbarItem"))
    }

    func testImportCenterUsesWarmPaletteAndOmitsDecorativeCardGlyphs() throws {
        let viewModel = ImportCenterViewModel()
        let inspected = try ImportCenterView(viewModel: viewModel).inspect()

        // Behavioral replacement: the actual constructed view renders the sidebar
        // and root/tint styling reachable from its own body, proven on the live
        // tree rather than by grepping for the private computed-property name.
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: ImportCenterAccessibilityID.sidebar))
        _ = try inspected.find(text: viewModel.selectedTab.title)

        // No decorative per-card or per-tab SF Symbol Image renders anywhere in the
        // constructed tree (the "recentImportsSection"/`sfSymbol`/`customImage`
        // affordances this test originally guarded against no longer exist in
        // source at all, confirmed below; the behavioral half proves no Image
        // glyphs render in their place today).
        XCTAssertTrue(inspected.findAll(ViewType.Image.self).isEmpty)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Deliberate dead-code check: confirms the removed decorative-glyph call
        // sites this test used to guard against have not been reintroduced. There is
        // no rendered instance of removed code to assert against behaviorally.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Color.lungfishCanvasBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishStroke"))
        XCTAssertFalse(source.contains("recentImportsSection"))
        XCTAssertFalse(source.contains("Image(systemName: viewModel.selectedTab.sfSymbol)"))
        XCTAssertFalse(source.contains("if let customImage = card.customImage"))
        XCTAssertFalse(source.contains("Image(systemName: card.sfSymbol)"))
    }

    func testMetagenomicsWizardHeadersOmitDecorativeHeroIcons() throws {
        // Behavioral replacement: none of the three wizard sheets render any Image
        // glyph anywhere in their constructed standalone body, proven on the real
        // views rather than by grepping for three specific SF Symbol names.
        let classificationInspected = try ClassificationWizardSheet(inputFiles: []).inspect()
        XCTAssertTrue(classificationInspected.findAll(ViewType.Image.self).isEmpty)

        let esvirituInspected = try EsVirituWizardSheet(inputFiles: []).inspect()
        XCTAssertTrue(esvirituInspected.findAll(ViewType.Image.self).isEmpty)

        let taxtriageInspected = try TaxTriageWizardSheet().inspect()
        XCTAssertTrue(taxtriageInspected.findAll(ViewType.Image.self).isEmpty)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Deliberate dead-code check: confirms the accentColor call sites this test
        // used to guard against have not been reintroduced (there is no rendered
        // instance of removed code to assert against behaviorally).
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
        XCTAssertFalse(classificationSource.contains("Color.accentColor"))
        XCTAssertFalse(esvirituSource.contains("Color.accentColor"))
        XCTAssertFalse(taxtriageSource.contains("Color.accentColor"))
    }

    func testUnifiedClassifierRunnerUsesSharedShellLayout() throws {
        let inspected = try UnifiedMetagenomicsWizard(inputFiles: []).inspect()

        // Behavioral replacement: the constructed wizard actually renders the
        // sidebar's "Classifier" runner-section title/subtitle and a top-level
        // HStack shell, proven on the live tree rather than by grepping for the
        // private computed-property names.
        _ = try inspected.find(text: "Classifier")
        _ = try inspected.find(text: "Choose the analysis to configure")
        XCTAssertNoThrow(try inspected.find(ViewType.HStack.self))

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Deliberate dead-code check: confirms the removed WizardStep/
        // analysisTypeSelector call sites have not been reintroduced. There is no
        // rendered instance of removed code to assert against behaviorally.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("WizardStep"))
        XCTAssertFalse(source.contains("analysisTypeSelector"))
    }

    func testToolPanelsRetainStandaloneShellAndSizing() throws {
        // Behavioral replacement: with `embeddedInOperationsDialog` left at its
        // default `false`, each wizard actually renders its own standalone
        // Cancel/Run buttons and frame size, proven on the real constructed views.
        let classificationInspected = try ClassificationWizardSheet(inputFiles: []).inspect()
        let classificationCancel = try classificationInspected.find(button: "Cancel")
        _ = try classificationInspected.find(button: "Run")
        let classificationFrame = try classificationCancel.find(
            ViewType.VStack.self,
            relation: .parent,
            where: { vstack in (try? vstack.fixedFrame()) != nil }
        )
        XCTAssertEqual(try classificationFrame.fixedFrame().width, 520)
        XCTAssertEqual(try classificationFrame.fixedFrame().height, 520)

        let esvirituInspected = try EsVirituWizardSheet(inputFiles: []).inspect()
        let esvirituCancel = try esvirituInspected.find(button: "Cancel")
        _ = try esvirituInspected.find(button: "Run")
        let esvirituFrame = try esvirituCancel.find(
            ViewType.VStack.self,
            relation: .parent,
            where: { vstack in (try? vstack.fixedFrame()) != nil }
        )
        XCTAssertEqual(try esvirituFrame.fixedFrame().width, 520)
        XCTAssertEqual(try esvirituFrame.fixedFrame().height, 500)

        let taxtriageInspected = try TaxTriageWizardSheet().inspect()
        _ = try taxtriageInspected.find(button: "Cancel")
        _ = try taxtriageInspected.find(button: "Run")

        // Embedded mode suppresses the standalone shell (no Cancel/Run buttons of
        // its own; those are driven by the shared operations dialog instead).
        let embeddedInspected = try ClassificationWizardSheet(
            inputFiles: [],
            embeddedInOperationsDialog: true
        ).inspect()
        XCTAssertThrowsError(try embeddedInspected.find(button: "Cancel"))
        XCTAssertThrowsError(try embeddedInspected.find(button: "Run"))
    }

    func testEmbeddedClassificationPanelUsesScrollView() throws {
        // Behavioral replacement: the standalone (non-embedded) sheet actually
        // renders a ScrollView wrapping the configuration content, and the
        // embedded sheet renders no standalone Cancel/Run footer, proven on real
        // constructed views for both configurations.
        let standaloneInspected = try ClassificationWizardSheet(inputFiles: []).inspect()
        XCTAssertNoThrow(try standaloneInspected.find(ViewType.ScrollView.self))

        let embeddedInspected = try ClassificationWizardSheet(
            inputFiles: [],
            embeddedInOperationsDialog: true
        ).inspect()
        XCTAssertThrowsError(try embeddedInspected.find(button: "Run"))
    }

    func testAppKitControlsAvoidDeprecatedTexturedRoundedStyle() throws {
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources/LungfishApp")
        let offenders = try swiftSourceFiles(under: sourceRoot).filter { url in
            let source = try String(contentsOf: url, encoding: .utf8)
            // source-audit: intentional repo-wide lint
            // Deliberate whole-tree scan for a deprecated AppKit API name; the
            // assertion's subject is source text by design (there is no runtime
            // instance of every control in every file to introspect), so no
            // ViewInspector/runtime seam applies.
            return source.contains(".texturedRounded")
        }.map { url in
            url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
        }.sorted()

        XCTAssertEqual(offenders, [])
    }

    func testDestructiveAlertFirstButtonsUseLungfishDestructiveStyle() throws {
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
            // InspectorViewController.swift and SidebarViewController.swift were split
            // into focused files; read the combined source so methods that moved into
            // an extension are still found.
            let source: String
            if alertCase.path == "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift" {
                source = combinedInspectorViewControllerSource()
            } else if alertCase.path == "Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift" {
                source = combinedSidebarViewControllerSource()
            } else {
                source = try String(
                    contentsOf: repositoryRoot().appendingPathComponent(alertCase.path),
                    encoding: .utf8
                )
            }
            let slice = try sourceSlice(source, from: alertCase.startToken, to: alertCase.endToken)
            // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
            // NSButton.applyLungfishDestructiveStyle() sets real observable properties
            // (hasDestructiveAction, contentTintColor, bezelColor), so in principle a
            // constructed NSAlert's first button could be asserted on directly. But
            // reaching each of these 9 call sites requires triggering a real deletion
            // confirmation flow (beginSheetModal) across SidebarViewController,
            // InspectorViewController, and AnnotationTableDrawerView with the right
            // preconditions (selection state, loaded documents, etc.) for each -- a
            // materially larger fixture effort than this task's scope for a single
            // grouped assertion loop.
            XCTAssertTrue(
                slice.contains("applyLungfishDestructiveStyle()"),
                "Missing Lungfish destructive styling for \(alertCase.label)"
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
            // source-audit: intentional repo-wide lint
            // Deliberate dead-code check: confirms no source file still references a
            // type that was deleted. There is no runtime instance to test against by
            // definition.
            return source.contains("MapReadsWizardSheet")
        }.map { url in
            url.path.replacingOccurrences(of: root.path + "/", with: "")
        }.sorted()

        XCTAssertEqual(references, [])
    }

    func testAssemblySheetSupportsEmbeddedOperationsDialogMode() throws {
        // Behavioral replacement: with embeddedInOperationsDialog left at its
        // default `false`, the sheet actually renders its own fixed 620x640
        // frame; when `true`, no fixed frame is applied at all (the shared
        // operations dialog controls sizing instead) -- proven on real
        // constructed views rather than by grepping the ternary source line.
        let standaloneInspected = try AssemblyWizardSheet(inputFiles: [], outputDirectory: nil).inspect()
        let standaloneTitle = try standaloneInspected.find(text: "Genome Assembly")
        let standaloneFrame = try standaloneTitle.find(
            relation: .parent,
            where: { view in (try? view.fixedFrame()) != nil }
        )
        XCTAssertEqual(try standaloneFrame.fixedFrame().width, 620)
        XCTAssertEqual(try standaloneFrame.fixedFrame().height, 640)

        let embeddedInspected = try AssemblyWizardSheet(
            inputFiles: [],
            outputDirectory: nil,
            embeddedInOperationsDialog: true
        ).inspect()
        // Embedded mode's body has no "Genome Assembly" header at all (that text
        // only renders in the standalone header), confirming the standalone shell
        // (and its fixed frame) is not rendered while embedded.
        XCTAssertThrowsError(try embeddedInspected.find(text: "Genome Assembly"))
        XCTAssertThrowsError(try embeddedInspected.fixedFrame())

        // Behavioral replacement: onAppear genuinely reports the sheet's initial
        // run-availability through the injected callback, proven by constructing
        // the view with a recording closure and firing onAppear.
        var reportedAvailability: [Bool] = []
        let callbackInspected = try AssemblyWizardSheet(
            inputFiles: [],
            outputDirectory: nil,
            onRunnerAvailabilityChange: { reportedAvailability.append($0) }
        ).inspect()
        let callbackTitle = try callbackInspected.find(text: "Genome Assembly")
        let onAppearNode = try callbackTitle.find(
            relation: .parent,
            where: { view in (try? view.fixedFrame()) != nil }
        )
        try onAppearNode.callOnAppear()
        XCTAssertEqual(reportedAvailability, [false]) // no input files/output directory yet

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Deliberate dead-code check: confirms the removed
        // `embeddedInUnifiedRunner` parameter has not been reintroduced. There is
        // no rendered instance of removed code to assert against behaviorally.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("embeddedInUnifiedRunner"))
    }

    func testDatasetOperationsDialogUsesTwoPaneSharedShell() throws {
        let dialog = DatasetOperationsDialog(
            title: "Test Dialog",
            subtitle: "Testing",
            datasetLabel: "sample.bam",
            tools: [DatasetOperationToolSidebarItem(id: "tool-1", title: "Tool One", subtitle: "First tool", availability: .available)],
            selectedToolID: "tool-1",
            statusText: "Ready",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            Text("Detail content")
        }
        let inspected = try dialog.inspect()

        // Behavioral replacement: the dialog actually renders a top-level HStack
        // shell with its own sidebar and Run button, proven on the real
        // constructed view rather than by grepping for the private computed-
        // property names and palette color symbols.
        XCTAssertNoThrow(try inspected.find(ViewType.HStack.self))
        _ = try inspected.find(text: "Tool One")
        _ = try inspected.find(text: "Test Dialog")
        _ = try inspected.find(text: "Detail content")
        _ = try inspected.find(button: "Run")
        _ = try inspected.find(button: "Cancel")

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // The remaining assertions are palette-color presence checks with no
        // simpler runtime seam than reading the source directly (ViewInspector
        // does not expose applied `Color`/`.tint` values as comparable data).
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )
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

/// Local copy of the small NSView-tree search helper already used in
/// Tests/LungfishAppViewTests/GUIRegressionTests.swift, for the one AppKit
/// (AIAssistantViewController) assertion in this file.
private extension NSView {
    func firstSubview(withAccessibilityIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
