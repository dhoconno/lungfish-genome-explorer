import XCTest

final class FASTQOperationToolPanesSourceTests: XCTestCase {
    private var toolPanesSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
    }

    func testOrientReadsReferenceInputUsesProjectReferencePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("usesProjectReferencePicker(for: kind)"))
        XCTAssertTrue(source.contains("state.selectedToolID == .orientReads"))
        XCTAssertTrue(source.contains("ReferenceSequencePickerView("))
        XCTAssertTrue(source.contains("selectedReferenceURL: referenceSelectionBinding(for: kind)"))
    }

    func testFASTQOperationToolPanesUseSharedScientificHelpCatalog() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import LungfishKit"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqOverview)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqInputs)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqOutputStrategy)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationReadiness)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.fastqAdvancedArguments)"))
    }

    func testFASTQOperationTextFieldsAcceptFieldLevelHelpItems() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

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

        for item in requiredHelpItems {
            XCTAssertTrue(source.contains("LungfishHelpContent.\(item)"), "\(item) is not wired into FASTQ operation panes")
        }
    }

    func testMAFFTPaneRendersCombineLockedMultiBundleRunModePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("mafftMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("allowedModes: [.combined]"))
        XCTAssertTrue(source.contains("defaultMode: .combined"))
        XCTAssertTrue(source.contains("lockReason: \"Alignment requires all sequences in one run\""))
        XCTAssertTrue(source.contains("MultiBundleRunModePicker(\n                    bundleCount: state.selectedInputURLs.count,\n                    policy: Self.mafftMultiBundleRunPolicy,\n                    selection: $mafftMultiBundleRunMode\n                )"))
    }

    func testSavontAndPbaaPanesRenderPerBundleLockedMultiBundleRunModePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("clusteringMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("allowedModes: [.perBundle]"))
        XCTAssertTrue(source.contains("lockReason: \"Runs once per bundle\""))
        XCTAssertTrue(source.contains("policy: Self.clusteringMultiBundleRunPolicy,\n                    selection: $pbaaMultiBundleRunMode"))
        XCTAssertTrue(source.contains("policy: Self.clusteringMultiBundleRunPolicy,\n                    selection: $savontMultiBundleRunMode"))
    }

    func testONTGenotypingPaneRendersPerBundleLockedMultiBundleRunModePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ontGenotypingMultiBundleRunPolicy = MultiBundleRunPolicy("))
        XCTAssertTrue(source.contains("lockReason: \"Genotyping is per-sample; use a cohort after per-sample calls\""))
        XCTAssertTrue(source.contains("policy: Self.ontGenotypingMultiBundleRunPolicy,\n                    selection: $ontGenotypingMultiBundleRunMode"))
    }

    func testSavontPaneExposesCuratedPrimaryAndAdvancedControlsWithoutRawArguments() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

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

        XCTAssertTrue(source.contains("import LungfishKit"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationToolSidebar)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationReadiness)"))
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.operationRun)"))
    }
}
