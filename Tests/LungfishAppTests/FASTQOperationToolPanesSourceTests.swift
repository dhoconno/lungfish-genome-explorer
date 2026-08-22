import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
private final class AllDisabledFASTQWorkflowLibrary: WorkflowLibraryEnabling {
    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool {
        false
    }
}

private struct NoOpSavontRuntimeStatusProvider: PluginPackStatusProviding {
    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

// lungfishSoleTextFieldHStack(placeholderOrLabel:) is defined in
// Tests/LungfishAppTests/ViewInspectorSupport.swift (promoted there alongside
// the VStack-flavored lungfishSoleTextFieldGroup).

/// Batch 3 (2026-08-22) conversion of FASTQOperationToolPanes.swift source-text
/// grep assertions to behavioral ViewInspector assertions against the actual
/// rendered view hierarchy, following the established pattern (see
/// docs/reports/2026-08-21-test-suite-review.md §3, batch 1/2 reports).
final class FASTQOperationToolPanesSourceTests: XCTestCase {
    @MainActor
    private func makeState(
        initialCategory: FASTQOperationCategoryID,
        selectedInputURLs: [URL]
    ) -> FASTQOperationDialogState {
        FASTQOperationDialogState(
            initialCategory: initialCategory,
            selectedInputURLs: selectedInputURLs,
            workflowLibrary: AllDisabledFASTQWorkflowLibrary(),
            savontRuntimeStatusProvider: NoOpSavontRuntimeStatusProvider()
        )
    }

    // MARK: - Orient Reads reference picker

    @MainActor
    func testOrientReadsReferenceInputUsesProjectReferencePicker() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationToolPanesSourceTests-\(UUID().uuidString)", isDirectory: true)
        let inputURL = URL(fileURLWithPath: "/tmp/orient-input.fastq")
        let state = makeState(initialCategory: .readProcessing, selectedInputURLs: [inputURL])
        state.selectTool(.orientReads)
        state.projectURL = projectURL

        let panes = FASTQOperationToolPanes(state: state)
        let inspected = try panes.inspect()

        // The reference sequence input for .orientReads must render the real
        // shared ReferenceSequencePickerView (not a generic auxiliary-input
        // browse row), proving usesProjectReferencePicker(for:) actually
        // routes .orientReads through the project reference picker at runtime.
        XCTAssertNoThrow(try inspected.find(ViewType.View<ReferenceSequencePickerView>.self))
    }

    @MainActor
    func testPbaaAndOntGenotypingReferenceInputsAlsoUseProjectReferencePicker() throws {
        // Companion to the orient-reads case: usesProjectReferencePicker(for:)
        // also names .pbaa and .ontGenotyping, so this proves those two tools
        // render the picker too (rather than the generic auxiliary browse row).
        for toolID: FASTQOperationToolID in [.pbaa, .ontGenotyping] {
            let inputURL = URL(fileURLWithPath: "/tmp/\(toolID.rawValue)-input.fastq")
            let state = makeState(initialCategory: .clustering, selectedInputURLs: [inputURL])
            state.selectTool(toolID)

            let panes = FASTQOperationToolPanes(state: state)
            let inspected = try panes.inspect()

            XCTAssertNoThrow(
                try inspected.find(ViewType.View<ReferenceSequencePickerView>.self),
                "\(toolID.rawValue) should render ReferenceSequencePickerView for its reference input"
            )
        }
    }

    // MARK: - Shared scientific help catalog wiring

    @MainActor
    func testFASTQOperationToolPanesUseSharedScientificHelpCatalog() throws {
        let state = makeState(
            initialCategory: .qcReporting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")]
        )
        state.selectTool(.refreshQCSummary)

        let panes = FASTQOperationToolPanes(state: state)
        let inspected = try panes.inspect()

        // Every derivative-pane section wires a real, resolvable LungfishHelpContent
        // entry via .lungfishHelp(...); read back the actual applied .help() text
        // instead of grepping the modifier call site.
        let overviewText = try inspected.find(text: state.selectedToolSummary)
        XCTAssertEqual(try overviewText.help().string(), LungfishHelpContent.fastqOverview.summary)

        let readinessText = try inspected.find(text: state.readinessText)
        XCTAssertEqual(try readinessText.help().string(), LungfishHelpContent.operationReadiness.summary)

        // fastqInputs coverage: FASTQOperationInputsSection's
        // `Label(state.datasetLabel, systemImage: "doc.text")` always renders
        // (regardless of which auxiliary input rows a tool needs) and carries
        // `.lungfishHelp(LungfishHelpContent.fastqInputs)`. Found by ViewType.Label
        // directly (not by descending into its icon content, which is an
        // unclassified-image blocker for ViewInspector, per the batch-3 report).
        let inputsLabel = try inspected.find(ViewType.Label.self, where: { label in
            (try? label.title().text().string()) == state.datasetLabel
        })
        XCTAssertEqual(try inputsLabel.help().string(), LungfishHelpContent.fastqInputs.summary)
    }

    @MainActor
    func testFASTQOperationOutputStrategyPickerUsesSharedScientificHelpCatalog() throws {
        // .removeContaminants renders the .output section (visibleSections
        // includes .output for most derivative tools), giving a real Picker
        // to find and read .help() from.
        let state = makeState(
            initialCategory: .decontamination,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")]
        )
        state.selectTool(.removeContaminants)

        let panes = FASTQOperationToolPanes(state: state)
        let inspected = try panes.inspect()

        let outputPicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Output Strategy"
        })
        XCTAssertEqual(try outputPicker.help().string(), LungfishHelpContent.fastqOutputStrategy.summary)
    }

    // MARK: - Field-level help items

    @MainActor
    func testFASTQOperationTextFieldsAcceptFieldLevelHelpItems() throws {
        // .fastpTrim's "Threshold" field is rendered via labeledTextField(...,
        // help: LungfishHelpContent.fastqQualityThreshold), proving the
        // TextField()/`.lungfishHelpIfPresent(help)` wiring actually attaches
        // real, resolvable help text to a real rendered control.
        let state = makeState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")]
        )
        state.selectTool(.fastpTrim)

        // Rendered via the FASTQOperationPrimarySettingsSectionHarness (not
        // the full FASTQOperationToolPanes): the sibling inputs section
        // renders a `Label(_, systemImage:)`, and ViewInspector's generic
        // VStack search aborts on that unclassified image node before
        // reaching the primary-settings text fields it's actually looking
        // for. Scoping to just the primary-settings section avoids the
        // blocker entirely.
        let harness = FASTQOperationPrimarySettingsSectionHarness(state: state)
        let inspected = try harness.inspect()

        let thresholdGroup = try inspected.lungfishSoleTextFieldHStack(placeholderOrLabel: "Threshold")
        XCTAssertEqual(try thresholdGroup.help().string(), LungfishHelpContent.fastqQualityThreshold.summary)
    }

    // MARK: - Specific help inventory across operation fields

    @MainActor
    func testFASTQOperationFieldsUseSpecificHelpInventory() throws {
        // Table of (tool, field label, expected help item) covering every
        // help item named in the original source-text inventory. Each row
        // constructs the real state for that tool, renders the real pane,
        // and reads back the actual applied .help() text for that field.
        struct Case {
            let toolID: FASTQOperationToolID
            let category: FASTQOperationCategoryID
            let fieldLabel: String
            let expected: LungfishHelpContent.HelpItem
            let configure: (FASTQOperationDialogState) -> Void
        }

        let cases: [Case] = [
            Case(toolID: .fastpTrim, category: .trimmingFiltering, fieldLabel: "Threshold", expected: LungfishHelpContent.fastqQualityThreshold, configure: { _ in }),
            Case(toolID: .fastpTrim, category: .trimmingFiltering, fieldLabel: "Window Size", expected: LungfishHelpContent.fastqWindowSize, configure: { _ in }),
            Case(toolID: .fastpTrim, category: .trimmingFiltering, fieldLabel: "Adapter Sequence", expected: LungfishHelpContent.fastqAdapterSequence, configure: { $0.adapterRemovalMode = .specified }),
            Case(toolID: .primerTrimming, category: .trimmingFiltering, fieldLabel: "Primer Sequence", expected: LungfishHelpContent.fastqPrimerSequence, configure: { _ in }),
            Case(toolID: .primerTrimming, category: .trimmingFiltering, fieldLabel: "k", expected: LungfishHelpContent.fastqKmerSize, configure: { _ in }),
            Case(toolID: .primerTrimming, category: .trimmingFiltering, fieldLabel: "hdist", expected: LungfishHelpContent.fastqHammingDistance, configure: { _ in }),
            Case(toolID: .filterByReadLength, category: .trimmingFiltering, fieldLabel: "Min Length", expected: LungfishHelpContent.fastqMinLength, configure: { _ in }),
            Case(toolID: .filterByReadLength, category: .trimmingFiltering, fieldLabel: "Max Length", expected: LungfishHelpContent.fastqMaxLength, configure: { _ in }),
            Case(toolID: .pbaa, category: .clustering, fieldLabel: "Threads", expected: LungfishHelpContent.fastqThreads, configure: { _ in }),
            Case(toolID: .pbaa, category: .clustering, fieldLabel: "Seed", expected: LungfishHelpContent.fastqSeed, configure: { _ in }),
            Case(toolID: .extractReadsByID, category: .searchSubsetting, fieldLabel: "Query", expected: LungfishHelpContent.fastqQuery, configure: { _ in }),
            Case(toolID: .extractReadsByMotif, category: .searchSubsetting, fieldLabel: "Pattern", expected: LungfishHelpContent.fastqPattern, configure: { _ in }),
            Case(toolID: .selectReadsBySequence, category: .searchSubsetting, fieldLabel: "Sequence or FASTA Path", expected: LungfishHelpContent.fastqSequenceOrFasta, configure: { _ in }),
            Case(toolID: .selectReadsBySequence, category: .searchSubsetting, fieldLabel: "Error Rate", expected: LungfishHelpContent.fastqErrorRate, configure: { _ in }),
            Case(toolID: .demultiplexBarcodes, category: .demultiplexing, fieldLabel: "5' Distance", expected: LungfishHelpContent.fastqDemultiplexDistance, configure: { $0.demultiplexEngine = .cutadapt }),
        ]

        for testCase in cases {
            let state = makeState(
                initialCategory: testCase.category,
                selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")]
            )
            state.selectTool(testCase.toolID)
            testCase.configure(state)

            // Rendered via the harness (not the full FASTQOperationToolPanes):
            // the sibling inputs section's `Label(_, systemImage:)` is an
            // unclassified-image blocker for ViewInspector's generic VStack
            // search, so this scopes to just the primary-settings section.
            let harness = FASTQOperationPrimarySettingsSectionHarness(state: state)
            let inspected = try harness.inspect()

            let group = try inspected.lungfishSoleTextFieldHStack(placeholderOrLabel: testCase.fieldLabel)
            XCTAssertEqual(
                try group.help().string(),
                testCase.expected.summary,
                "\(testCase.toolID.rawValue): \(testCase.fieldLabel)"
            )
        }

        // fastqRegex is applied to a Toggle (not a TextField), so it needs
        // its own lookup rather than the TextField-group helper above.
        let regexToolState = makeState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")]
        )
        regexToolState.selectTool(.extractReadsByID)
        let regexInspected = try FASTQOperationPrimarySettingsSectionHarness(state: regexToolState).inspect()
        let regexToggle = try regexInspected.find(ViewType.Toggle.self, where: { toggle in
            (try? toggle.labelView().text().string()) == "Use Regular Expression"
        })
        XCTAssertEqual(try regexToggle.help().string(), LungfishHelpContent.fastqRegex.summary)
    }

    // MARK: - Multi-bundle run-mode pickers

    @MainActor
    func testMAFFTPaneRendersCombineLockedMultiBundleRunModePicker() throws {
        // Batch 3 (2026-08-22): reaches the file-private
        // FASTQOperationPrimarySettingsSection via the disclosed test-only
        // FASTQOperationPrimarySettingsSectionHarness wrapper (same pattern as
        // batch 1's PacksTabViewHarness). MAFFT pools every selected sequence
        // into one alignment run, so the picker must render combine-locked.
        let state = makeState(
            initialCategory: .alignment,
            selectedInputURLs: [
                URL(fileURLWithPath: "/tmp/seq1.fasta"),
                URL(fileURLWithPath: "/tmp/seq2.fasta"),
            ]
        )
        state.selectTool(.mafft)

        let harness = FASTQOperationPrimarySettingsSectionHarness(state: state)
        let inspected = try harness.inspect()

        let picker = try inspected.find(ViewType.View<MultiBundleRunModePicker>.self)
        let rowStates = MultiBundleRunModePicker.rowStates(
            bundleCount: state.selectedInputURLs.count,
            policy: .init(allowedModes: [.combined], defaultMode: .combined, lockReason: "Alignment requires all sequences in one run")
        )
        XCTAssertEqual(rowStates.first(where: { $0.mode == .combined })?.isEnabled, true)
        XCTAssertEqual(rowStates.first(where: { $0.mode == .perBundle })?.isEnabled, false)
        XCTAssertEqual(
            rowStates.first(where: { $0.mode == .perBundle })?.caption,
            "Alignment requires all sequences in one run"
        )

        // The rendered picker's accessibility identifiers prove both rows
        // actually appear in the view tree with the expected enabled state.
        XCTAssertNoThrow(try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-combined"))
        let perBundleRow = try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-perBundle")
        XCTAssertTrue(perBundleRow.isDisabled())
    }

    @MainActor
    func testSavontAndPbaaPanesRenderPerBundleLockedMultiBundleRunModePicker() throws {
        // Savont and pbaa already iterate one clustering run per selected
        // bundle -- this proves the picker actually renders that as a locked
        // "per bundle" choice for both tools.
        for toolID: FASTQOperationToolID in [.savont, .pbaa] {
            let state = makeState(
                initialCategory: .clustering,
                selectedInputURLs: [
                    URL(fileURLWithPath: "/tmp/bundle1.lungfishfastq"),
                    URL(fileURLWithPath: "/tmp/bundle2.lungfishfastq"),
                ]
            )
            state.selectTool(toolID)

            let harness = FASTQOperationPrimarySettingsSectionHarness(state: state)
            let inspected = try harness.inspect()

            let picker = try inspected.find(ViewType.View<MultiBundleRunModePicker>.self)
            let perBundleRow = try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-perBundle")
            XCTAssertFalse(perBundleRow.isDisabled(), "\(toolID.rawValue)")

            let combinedRow = try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-combined")
            XCTAssertTrue(combinedRow.isDisabled(), "\(toolID.rawValue)")

            let rowStates = MultiBundleRunModePicker.rowStates(
                bundleCount: state.selectedInputURLs.count,
                policy: .init(allowedModes: [.perBundle], defaultMode: .perBundle, lockReason: "Runs once per bundle")
            )
            XCTAssertEqual(
                rowStates.first(where: { $0.mode == .combined })?.caption,
                "Runs once per bundle",
                "\(toolID.rawValue)"
            )
        }
    }

    @MainActor
    func testONTGenotypingPaneRendersCombineLockedMultiBundleRunModePickerReflectingActualPooledBatchExecution() throws {
        // MB-5 review fix round 1: the runtime pools every selected bundle
        // into ONE .ontSampleBundles batch run (merged BAM, one report), so
        // the picker must be combine-locked, not per-bundle-locked -- showing
        // an enabled "Run separately per bundle" row would over-promise
        // separate runs the execution path doesn't perform.
        let state = makeState(
            initialCategory: .genotyping,
            selectedInputURLs: [
                URL(fileURLWithPath: "/tmp/sample1.lungfishfastq"),
                URL(fileURLWithPath: "/tmp/sample2.lungfishfastq"),
            ]
        )
        state.selectTool(.ontGenotyping)

        let harness = FASTQOperationPrimarySettingsSectionHarness(state: state)
        let inspected = try harness.inspect()

        let picker = try inspected.find(ViewType.View<MultiBundleRunModePicker>.self)
        let combinedRow = try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-combined")
        XCTAssertFalse(combinedRow.isDisabled())

        let perBundleRow = try picker.find(viewWithAccessibilityIdentifier: "multi-bundle-run-mode-perBundle")
        XCTAssertTrue(perBundleRow.isDisabled())

        let rowStates = MultiBundleRunModePicker.rowStates(
            bundleCount: state.selectedInputURLs.count,
            policy: .init(
                allowedModes: [.combined],
                defaultMode: .combined,
                lockReason: "Selections run as one genotyping batch producing a merged report. Run bundles individually for separate per-sample reports."
            )
        )
        XCTAssertEqual(
            rowStates.first(where: { $0.mode == .perBundle })?.caption,
            "Selections run as one genotyping batch producing a merged report. Run bundles individually for separate per-sample reports."
        )
    }

    // MARK: - Savont curated controls

    @MainActor
    func testSavontPaneExposesCuratedPrimaryAndAdvancedControlsWithoutRawArguments() throws {
        // Behavioral replacement: constructs the real .savont primary +
        // advanced-settings sections and asserts every curated control
        // actually renders, and that no raw "extra arguments" free-text
        // field exists anywhere in either section (there is no
        // savontExtraArguments state property to bind one to).
        let state = makeState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/single.lungfishfastq")]
        )
        state.selectTool(.savont)

        let primaryHarness = FASTQOperationPrimarySettingsSectionHarness(state: state)
        let primaryInspected = try primaryHarness.inspect()

        // .savont's MultiBundleRunModePicker renders an Image(systemName:)
        // circle glyph, which is an unclassified-image blocker for
        // ViewInspector's `find` (throws on the first unclassifiable node it
        // walks past). `findAll` swallows classification failures instead of
        // throwing, so it is used here to enumerate every labeledTextField/
        // labeledCompactTextField HStack (label Text + TextField pair, per
        // FASTQOperationToolPanes.swift) and read back each one's label text.
        func fieldLabels(in inspected: InspectableView<ViewType.ClassifiedView>) -> [String] {
            inspected.findAll(ViewType.HStack.self, where: { group in
                group.findAll(ViewType.TextField.self).count == 1
            }).compactMap { group in
                group.findAll(ViewType.Text.self).first.flatMap { try? $0.string() }
            }
        }

        let primaryLabels = fieldLabels(in: primaryInspected)
        XCTAssertTrue(primaryLabels.contains("Output Name"))
        XCTAssertTrue(primaryLabels.contains("Threads"))
        XCTAssertTrue(primaryLabels.contains("Quality Cutoff"))
        XCTAssertTrue(primaryLabels.contains("Min Cluster"))

        let advancedHarness = FASTQOperationAdvancedSettingsSectionHarness(state: state)
        let advancedInspected = try advancedHarness.inspect()
        let advancedLabels = fieldLabels(in: advancedInspected)
        XCTAssertTrue(advancedLabels.contains("Min Read Length"))
        XCTAssertTrue(advancedLabels.contains("Max Read Length"))
        XCTAssertFalse(advancedInspected.findAll(ViewType.Toggle.self).isEmpty)

        // No raw arguments text field exists anywhere: assert the only
        // TextFields present across both sections are the curated ones
        // enumerated above (4 in primary: Output Name, Threads, Quality
        // Cutoff, Min Cluster; 2 in advanced: Min/Max Read Length -- the
        // advanced section is inside a collapsed DisclosureGroup, so
        // findAll must still reach it since ViewInspector evaluates the
        // full view tree regardless of expansion state).
        let primaryFieldCount = primaryInspected.findAll(ViewType.TextField.self).count
        let advancedFieldCount = advancedInspected.findAll(ViewType.TextField.self).count
        XCTAssertEqual(primaryFieldCount, 4)
        XCTAssertEqual(advancedFieldCount, 2)
    }

    // MARK: - Import sheet / dataset operations dialog help wiring

    @MainActor
    func testFASTQImportSheetUsesSpecificHelpInventory() throws {
        // FASTQImportConfigSheet is a real NSViewController (AppKit, not
        // SwiftUI) constructed directly, matching the GUIRegressionTests
        // pattern (testFASTQImportSheetSupportsBarcodeGatedRecipes).
        //
        // Fix wave (2026-08-22): restores the full 9-item help inventory via
        // toolTip readback -- NSControl.applyLungfishHelp(_:) (LungfishHelpContent.swift)
        // sets `toolTip = item.summary`, so finding a real control whose toolTip
        // equals a specific item's summary proves that exact help item is wired
        // to a real rendered control, not merely that some control with a
        // plausible label exists. The sheet's controls (platformPopup,
        // recipeCheckbox, etc.) are all `private`, so they are located by
        // toolTip content via `firstControl(withToolTip:)` (LungfishTestSupport)
        // rather than by name.
        let inputURL = URL(fileURLWithPath: "/data/Run1/sample.fastq", isDirectory: false)
        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: inputURL, r2: nil)],
            detectedPlatform: .oxfordNanopore,
            recipeOptions: [.ontPacBioBarcodeDemux],
            onImport: { _ in }
        )
        sheet.loadViewIfNeeded()
        sheet.view.layoutSubtreeIfNeeded()

        // One-to-one items: platform/pairing/quality-binning/clumpify/
        // compression popups each have a unique summary.
        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportPlatform.summary),
            "platformPopup should carry fastqImportPlatform's help"
        )
        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportPairing.summary),
            "pairingPopup should carry fastqImportPairing's help"
        )
        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportQualityBinning.summary),
            "binningPopup should carry fastqImportQualityBinning's help"
        )
        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportClumpify.summary),
            "clumpifyCheckbox/clumpingToolPopup should carry fastqImportClumpify's help"
        )
        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportCompression.summary),
            "compressionPopup should carry fastqImportCompression's help"
        )

        // recipeCheckbox and recipePopup both wire fastqImportRecipe: prove the
        // checkbox specifically (identifiable by its title), then prove the
        // item's help text is applied to at least one control overall.
        let recipeCheckbox = try XCTUnwrap(
            sheet.view.firstButtonMatching(title: "Apply processing recipe after import")
        )
        XCTAssertEqual(recipeCheckbox.toolTip, LungfishHelpContent.fastqImportRecipe.summary)

        // barcodeDefinitionHelpButton/barcodeDefinitionPopup/chooseBarcodeDefinitionButton
        // all wire fastqImportBarcodeSheet: prove chooseBarcodeDefinitionButton
        // specifically (identifiable by its title), then prove the item's help
        // text is applied to at least one control overall.
        let chooseBarcodeButton = try XCTUnwrap(sheet.view.firstButtonMatching(title: "Choose..."))
        XCTAssertEqual(chooseBarcodeButton.toolTip, LungfishHelpContent.fastqImportBarcodeSheet.summary)

        XCTAssertNotNil(
            sheet.view.firstControl(withToolTip: LungfishHelpContent.fastqImportDemuxFolder.summary),
            "demultiplexFolderField should carry fastqImportDemuxFolder's help"
        )

        let importButton = try XCTUnwrap(sheet.view.firstButtonMatching(title: "Import"))
        XCTAssertEqual(importButton.toolTip, LungfishHelpContent.operationRun.summary)
    }

    @MainActor
    func testDatasetOperationsDialogUsesSharedScientificHelpCatalog() throws {
        // Constructs DatasetOperationsDialog directly with minimal fixture
        // sidebar data (same shape as batch 1's converted
        // testDatasetOperationsDialogUsesTwoPaneSharedShell), proving the
        // sidebar tool row and readiness/run-button footer wire real,
        // resolvable LungfishHelpContent entries.
        let dialog = DatasetOperationsDialog(
            title: "FASTQ Operations",
            subtitle: "sample.fastq",
            datasetLabel: "1 file selected",
            tools: [
                DatasetOperationToolSidebarItem(
                    id: "refresh-qc",
                    title: "Compute Quality Report",
                    subtitle: "QC & Reporting",
                    availability: .available
                ),
            ],
            selectedToolID: "refresh-qc",
            statusText: "Ready to run",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            Text("Detail")
        }
        let inspected = try dialog.inspect()

        let sidebarButton = try inspected.find(button: "Compute Quality Report")
        XCTAssertEqual(try sidebarButton.help().string(), LungfishHelpContent.operationToolSidebar.summary)

        let statusText = try inspected.find(text: "Ready to run")
        XCTAssertEqual(try statusText.help().string(), LungfishHelpContent.operationReadiness.summary)

        let runButton = try inspected.find(button: "Run")
        XCTAssertEqual(try runButton.help().string(), LungfishHelpContent.operationRun.summary)
    }
}

// firstButtonMatching(title:)/containsLabelText(_:) are defined in the shared
// LungfishTestSupport module
// (Tests/Support/LungfishTestSupport/NSViewSearchSupport.swift).
