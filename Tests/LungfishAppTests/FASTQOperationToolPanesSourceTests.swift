import XCTest

final class FASTQOperationToolPanesSourceTests: XCTestCase {
    private var toolPanesSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
    }

    func testOrientReadsReferenceInputUsesProjectReferencePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // FASTQOperationToolPanes.body is a pure SwiftUI switch-on-tool View; no
        // ViewInspector/snapshot harness exists in this repo to observe which
        // sub-view/picker actually rendered for a given selectedToolID.
        XCTAssertTrue(source.contains("usesProjectReferencePicker(for: kind)"))
        XCTAssertTrue(source.contains("state.selectedToolID == .orientReads"))
        XCTAssertTrue(source.contains("ReferenceSequencePickerView("))
        XCTAssertTrue(source.contains("selectedReferenceURL: referenceSelectionBinding(for: kind)"))
    }

    func testFASTQOperationToolPanesUseSharedScientificHelpCatalog() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Same SwiftUI-body limitation as above: `.lungfishHelp(...)` view-modifier wiring
        // is not observable at runtime without a rendering/inspection harness.
        XCTAssertTrue(source.contains("import LungfishKit"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqOverview)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqInputs)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqOutputStrategy)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationReadiness)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqAdvancedArguments)"))
    }

    func testFASTQOperationTextFieldsAcceptFieldLevelHelpItems() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("help: LungfishHelpContent.HelpItem"))
        XCTAssertTrue(source.contains("TextField(\"\", text: text)"))
        XCTAssertTrue(source.contains(".lungfishHelpIfPresent(help)"))
    }

    func testFASTQOperationFieldsUseSpecificHelpInventory() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)
        let requiredHelpItems = [
            "fastqQualityThreshold",
            "fastqWindowSize",
            "fastqAdapterSequence",
            "fastqPrimerSequence",
            "fastqKmerSize",
            "fastqHammingDistance",
            "fastqMinLength",
            "fastqMaxLength",
            "fastqThreads",
            "fastqSeed",
            "fastqQuery",
            "fastqPattern",
            "fastqRegex",
            "fastqSequenceOrFasta",
            "fastqErrorRate",
            "fastqDemultiplexDistance",
        ]

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        for item in requiredHelpItems {
            XCTAssertTrue(source.contains("LungfishHelpContent.\(item)"), "\(item) is not wired into FASTQ operation panes")
        }
    }

    func testMAFFTPaneRendersCombineLockedMultiBundleRunModePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // mafftMultiBundleRunPolicy is a static let on `private struct
        // FASTQOperationPrimarySettingsSection` -- Swift's `private` is file-scoped, so
        // this is unreachable even via @testable import without widening its access,
        // which is a production change out of scope for this task.
        XCTAssertTrue(source.contains("mafftMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("allowedModes: [.combined]"))
        XCTAssertTrue(source.contains("defaultMode: .combined"))
        XCTAssertTrue(source.contains("lockReason: \"Alignment requires all sequences in one run\""))
        XCTAssertTrue(source.contains("MultiBundleRunModePicker(\n                    bundleCount: state.selectedInputURLs.count,\n                    policy: Self.mafftMultiBundleRunPolicy,\n                    selection: $mafftMultiBundleRunMode\n                )"))
    }

    func testSavontAndPbaaPanesRenderPerBundleLockedMultiBundleRunModePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Same file-private static-let issue as MAFFT above (private struct
        // FASTQOperationPrimarySettingsSection).
        XCTAssertTrue(source.contains("clusteringMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("allowedModes: [.perBundle]"))
        XCTAssertTrue(source.contains("lockReason: \"Runs once per bundle\""))
        XCTAssertTrue(source.contains("policy: Self.clusteringMultiBundleRunPolicy,\n                    selection: $pbaaMultiBundleRunMode"))
        XCTAssertTrue(source.contains("policy: Self.clusteringMultiBundleRunPolicy,\n                    selection: $savontMultiBundleRunMode"))
    }

    func testONTGenotypingPaneRendersCombineLockedMultiBundleRunModePickerReflectingActualPooledBatchExecution() throws {
        // MB-5 review fix round 1: the runtime pools every selected bundle
        // into ONE .ontSampleBundles batch run (merged BAM, one report),
        // so the picker must be combine-locked, not per-bundle-locked --
        // showing an enabled "Run separately per bundle" row would
        // over-promise separate runs the execution path doesn't perform.
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Same file-private static-let issue as MAFFT/Savont above.
        XCTAssertTrue(source.contains("ontGenotypingMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("allowedModes: [.combined],\n        defaultMode: .combined,\n        lockReason: \"Selections run as one genotyping batch producing a merged report. Run bundles individually for separate per-sample reports.\""))
        XCTAssertTrue(source.contains("policy: Self.ontGenotypingMultiBundleRunPolicy,\n                    selection: $ontGenotypingMultiBundleRunMode"))
        XCTAssertFalse(source.contains("ontGenotypingMultiBundleRunMode: MultiBundleRunMode = .perBundle"))
    }

    func testSavontPaneExposesCuratedPrimaryAndAdvancedControlsWithoutRawArguments() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // SwiftUI-body switch content; no rendering/inspection harness available.
        XCTAssertTrue(source.contains("case .savont:"))
        XCTAssertTrue(source.contains("\\.savontSingleInputOutputName"))
        XCTAssertTrue(source.contains("\\.savontThreads"))
        XCTAssertTrue(source.contains("\\.savontQualityValueCutoff"))
        XCTAssertTrue(source.contains("\\.savontMinimumClusterSize"))
        XCTAssertTrue(source.contains("\\.savontMinimumReadLength"))
        XCTAssertTrue(source.contains("\\.savontMaximumReadLength"))
        XCTAssertTrue(source.contains("$state.savontSingleStrand"))
        XCTAssertFalse(source.contains("savontExtraArguments"))
    }

    func testFASTQImportSheetUsesSpecificHelpInventory() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift"),
            encoding: .utf8
        )
        let requiredHelpItems = [
            "fastqImportPlatform",
            "fastqImportPairing",
            "fastqImportQualityBinning",
            "fastqImportClumpify",
            "fastqImportCompression",
            "fastqImportRecipe",
            "fastqImportBarcodeSheet",
            "fastqImportDemuxFolder",
            "operationRun",
        ]

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // FASTQImportConfigSheet is a pure SwiftUI View; help-modifier wiring is not
        // runtime-observable without a rendering/inspection harness.
        XCTAssertTrue(source.contains("import LungfishKit"))
        for item in requiredHelpItems {
            XCTAssertTrue(source.contains("LungfishHelpContent.\(item)"), "\(item) is not wired into FASTQ import sheet")
        }
    }

    func testDatasetOperationsDialogUsesSharedScientificHelpCatalog() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("import LungfishKit"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationToolSidebar)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationReadiness)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationRun)"))
    }
}
