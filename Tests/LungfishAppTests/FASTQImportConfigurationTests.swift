// FASTQImportConfigurationTests.swift - Tests for FASTQ import configuration and pair grouping
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import Testing
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

@Suite("FASTQ Import Configuration")
struct FASTQImportConfigurationTests {

    // MARK: - Pair Grouping

    @Test("Groups R1/R2 paired files with _R1_001/_R2_001 suffix")
    func groupIlluminaPairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].r1 == r1)
        #expect(pairs[0].r2 == r2)
        #expect(pairs[0].isPaired)
    }

    @Test("Groups R1/R2 paired files with _R1/_R2 suffix")
    func groupSimplePairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    @Test("Groups R1/R2 paired files with _1/_2 suffix (SRA convention)")
    func groupSRAPairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/SRR12345_1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/SRR12345_2.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    @Test("Single file without mate is unpaired")
    func singleFileUnpaired() {
        let url = URL(fileURLWithPath: "/data/Sample.fastq.gz")
        let pairs = groupFASTQByPairs([url])
        #expect(pairs.count == 1)
        #expect(pairs[0].r1 == url)
        #expect(pairs[0].r2 == nil)
        #expect(!pairs[0].isPaired)
    }

    @Test("A BAM read source remains a single-end sample")
    func bamFileUnpaired() {
        let url = URL(fileURLWithPath: "/data/NanoporeSample.bam")
        let pairs = groupFASTQByPairs([url])
        #expect(pairs.count == 1)
        #expect(pairs[0].r1 == url)
        #expect(pairs[0].r2 == nil)
        #expect(pairs[0].sampleName == "NanoporeSample")
        #expect(MainSplitViewController.detectedImportPlatform(for: pairs) == .oxfordNanopore)
    }

    @Test("R1 without matching R2 is unpaired")
    func r1WithoutR2() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let pairs = groupFASTQByPairs([r1])
        #expect(pairs.count == 1)
        #expect(!pairs[0].isPaired)
    }

    @Test("Multiple pairs grouped correctly")
    func multiplePairs() {
        let files = [
            URL(fileURLWithPath: "/data/SampleA_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleA_R2_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleB_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleB_R2_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleC.fastq.gz"),
        ]
        let pairs = groupFASTQByPairs(files)
        #expect(pairs.count == 3)
        let pairedCount = pairs.filter(\.isPaired).count
        let singleCount = pairs.filter { !$0.isPaired }.count
        #expect(pairedCount == 2)
        #expect(singleCount == 1)
    }

    @Test("Order is preserved — R2 dropped before R1 still pairs correctly")
    func reverseOrderPairing() {
        let r2 = URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let pairs = groupFASTQByPairs([r2, r1])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
        #expect(pairs[0].r1 == r1)
        #expect(pairs[0].r2 == r2)
    }

    @Test("Handles .fq extension")
    func fqExtension() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1.fq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2.fq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    // MARK: - Sample Name Derivation

    @Test("Sample name strips _R1_001 suffix")
    func sampleNameIllumina() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/School030_S33_L004_R1_001.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/School030_S33_L004_R2_001.fastq.gz")
        )
        #expect(pair.sampleName == "School030_S33_L004")
    }

    @Test("Sample name strips _R1 suffix")
    func sampleNameSimple() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/MySample_R1.fastq.gz"),
            r2: nil
        )
        #expect(pair.sampleName == "MySample")
    }

    @Test("Sample name preserves name when no read suffix")
    func sampleNameNoSuffix() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/MySample.fastq.gz"),
            r2: nil
        )
        #expect(pair.sampleName == "MySample")
    }

    @Test("ONT demux folder default comes from run folder for fastq_pass")
    func ontDemuxFolderDefaultUsesRunFolderForFastqPass() {
        let sourceURL = URL(fileURLWithPath: "/data/Run 42/fastq_pass", isDirectory: true)

        #expect(FASTQImportConfigSheet.defaultDemultiplexFolderName(for: sourceURL) == "Run 42")
    }

    @Test("ONT demux folder default sanitizes path separators and punctuation")
    func ontDemuxFolderDefaultSanitizesNames() {
        #expect(FASTQImportConfigSheet.sanitizedDemultiplexFolderName(" Plate:A/Run#42 ") == "Plate-A-Run-42")
        #expect(FASTQImportConfigSheet.sanitizedDemultiplexFolderName("   ") == "ONT Demultiplexed FASTQs")
    }

    @MainActor
    @Test("ONT import sheet hides paired-end choices and imports as single-end")
    func ontImportSheetHidesPairedEndChoices() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/barcode01_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/barcode01_R2.fastq.gz")
        )
        var capturedConfig: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(
            pairs: [pair],
            detectedPlatform: .oxfordNanopore,
            onImport: { configuration in
                capturedConfig = configuration
            }
        )

        sheet.loadViewIfNeeded()

        let pairingLabel = sheet.view.fastqImportDescendants(of: NSTextField.self)
            .first { $0.stringValue == "Pairing:" }
        let pairingPopup = sheet.view.fastqImportDescendants(of: NSPopUpButton.self)
            .first { popup in
                (0..<popup.numberOfItems).contains { popup.item(at: $0)?.title == "Paired-end" }
            }

        #expect(pairingLabel?.isHidden == true)
        #expect(pairingPopup?.isHidden == true)
        #expect(pairingPopup?.selectedItem?.title == "Single-end")

        let importButton = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Import" }
        importButton?.performClick(nil)

        #expect(capturedConfig?.pairingMode == .singleEnd)
    }

    @MainActor
    @Test("FASTQ import sheet defaults storage tool from file size and memory")
    func importSheetDefaultsStorageToolFromInputSize() throws {
        let smallURL = try Self.temporaryFASTQ(named: "small.fastq.gz", byteCount: 1_048_576)
        let largeURL = try Self.temporaryFASTQ(named: "large.fastq.gz", byteCount: 40 * Self.gib)
        defer {
            try? FileManager.default.removeItem(at: smallURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: largeURL.deletingLastPathComponent())
        }

        let smallSheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: smallURL, r2: nil)],
            detectedPlatform: .illumina
        )
        smallSheet.loadViewIfNeeded()

        let largeSheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: largeURL, r2: nil)],
            detectedPlatform: .illumina
        )
        largeSheet.loadViewIfNeeded()

        #expect(smallSheet.view.fastqImportStorageToolPopup()?.selectedClumpingTool == .bbtools)
        #expect(largeSheet.view.fastqImportStorageToolPopup()?.selectedClumpingTool == .trimGalore)
        let largeOptimizeCheckbox = largeSheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Optimize storage (reorder reads for better compression)" }
        #expect(largeOptimizeCheckbox?.state == .on)
    }

    @MainActor
    @Test("FASTQ import sheet submits selected storage tool")
    func importSheetSubmitsSelectedStorageTool() throws {
        let sourceURL = try Self.temporaryFASTQ(named: "sample.fastq.gz", byteCount: 1_048_576)
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }
        var capturedConfig: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: sourceURL, r2: nil)],
            detectedPlatform: .illumina,
            onImport: { configuration in
                capturedConfig = configuration
            }
        )

        sheet.loadViewIfNeeded()

        let storageToolPopup = try #require(sheet.view.fastqImportStorageToolPopup())
        storageToolPopup.selectClumpingTool(.trimGalore)

        let importButton = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Import" }
        importButton?.performClick(nil)

        #expect(capturedConfig?.skipClumpify == false)
        #expect(capturedConfig?.clumpingTool == .trimGalore)
    }

    @MainActor
    @Test("FASTQ import sheet updates the Trim Galore disclosure when the selection changes")
    func importSheetUpdatesTrimGaloreDisclosure() throws {
        let sourceURL = try Self.temporaryFASTQ(named: "sample.fastq.gz", byteCount: 1_048_576)
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: sourceURL, r2: nil)],
            detectedPlatform: .illumina
        )
        sheet.loadViewIfNeeded()

        let disclosure = sheet.view.fastqImportDescendants(of: NSTextField.self)
            .first { $0.accessibilityIdentifier() == "fastq-import-trim-galore-disclosure" }
        #expect(disclosure != nil)
        #expect(disclosure?.cell?.wraps == true)

        let popup = try #require(sheet.view.fastqImportStorageToolPopup())
        popup.selectClumpingTool(.bbtools)
        #expect(disclosure?.isHidden == true)
        popup.selectClumpingTool(.trimGalore)
        #expect(disclosure?.isHidden == false)
    }

    @Test("Inspector combined fastp presentation uses the approved message exclusively")
    func inspectorUsesCombinedFastpPresentation() throws {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                RecipeStepResult(
                    stepName: "Remove PCR duplicates + Adapter + quality trim",
                    tool: "fastp",
                    inputReadCount: 1_000_000,
                    outputReadCount: 720_000,
                    durationSeconds: 1,
                    logicalComponents: [
                        RecipeLogicalComponent(typeID: "fastp-dedup", displayName: "Remove PCR duplicates"),
                        RecipeLogicalComponent(typeID: "fastp-trim", displayName: "Adapter + quality trim"),
                    ]
                ),
                RecipeStepResult(
                    stepName: "Remove PCR duplicates",
                    tool: "fastp",
                    inputReadCount: 720_000,
                    outputReadCount: 700_000,
                    durationSeconds: 1
                ),
            ]
        )
        #expect(info.deduplicationPerformedInCombinedPass)
        #expect(info.deduplicationSummary != nil)

        let presentation = try #require(RecipeDeduplicationPresentation.presentation(for: info))

        #expect(presentation == .combinedPass)
        #expect(presentation.value == "Performed in combined fastp pass; an exact dedup-only removed count is unavailable.")
        if case .standaloneReadDelta = presentation {
            Issue.record("Combined and standalone deduplication branches must be exclusive")
        }
    }

    @Test("Inspector standalone deduplication presentation retains its read delta")
    func inspectorUsesStandaloneDeduplicationReadDelta() throws {
        let info = RecipeAppliedInfo(
            recipeID: "legacy-recipe",
            recipeName: "Legacy Recipe",
            stepResults: [
                RecipeStepResult(
                    stepName: "Remove PCR duplicates",
                    tool: "fastp",
                    inputReadCount: 1_000_000,
                    outputReadCount: 720_000,
                    durationSeconds: 1
                ),
            ]
        )

        let presentation = try #require(RecipeDeduplicationPresentation.presentation(for: info))

        #expect(presentation == .standaloneReadDelta("280,000 removed (28.0%)"))
        #expect(presentation.value == "280,000 removed (28.0%)")
        if case .combinedPass = presentation {
            Issue.record("Standalone and combined deduplication branches must be exclusive")
        }
    }

    @MainActor
    @Test("ONT demux recipe import captures user folder override")
    func ontDemuxRecipeImportCapturesUserFolderOverride() {
        let sourceURL = URL(fileURLWithPath: "/data/Run42/fastq_pass", isDirectory: true)
        let barcodeURL = URL(fileURLWithPath: "/data/Run42/barcodes.csv")
        let pair = FASTQFilePair(r1: sourceURL, r2: nil)
        var capturedConfig: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(
            pairs: [pair],
            detectedPlatform: .oxfordNanopore,
            recipeOptions: [.ontPacBioBarcodeDemux],
            projectURL: URL(fileURLWithPath: "/project", isDirectory: true),
            barcodeDefinitionCandidates: [barcodeURL],
            onImport: { configuration in
                capturedConfig = configuration
            }
        )

        sheet.loadViewIfNeeded()

        let recipeCheckbox = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Apply processing recipe after import" }
        recipeCheckbox?.performClick(nil)

        let demuxFolderField = sheet.view.fastqImportDescendants(of: NSTextField.self)
            .first { $0.isEditable }
        #expect(demuxFolderField?.stringValue == "Run42")
        demuxFolderField?.stringValue = "Custom Batch 7"

        let importButton = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Import" }
        importButton?.performClick(nil)

        #expect(capturedConfig?.recipeName == FASTQImportSheetRecipeOption.ontPacBioBarcodeDemux.id)
        #expect(capturedConfig?.resolvedPlaceholders["barcodeDefinition"] == barcodeURL.path)
        #expect(capturedConfig?.demultiplexOutputFolderName == "Custom Batch 7")
    }

    @MainActor
    @Test("ONT barcode recipe sheet exposes compact format help")
    func ontBarcodeRecipeSheetExposesCompactFormatHelp() throws {
        let sourceURL = URL(fileURLWithPath: "/data/Run42/fastq_pass", isDirectory: true)
        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: sourceURL, r2: nil)],
            detectedPlatform: .oxfordNanopore,
            recipeOptions: [.ontFluidigmSampleSplit, .ontPacBioBarcodeDemux]
        )

        sheet.loadViewIfNeeded()

        let recipeCheckbox = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Apply processing recipe after import" }
        recipeCheckbox?.performClick(nil)
        sheet.view.layoutSubtreeIfNeeded()

        let helpButton = try #require(sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.toolTip == "Show barcode sheet format" })
        #expect(helpButton.toolTip == "Show barcode sheet format")
        #expect(helpButton.isBordered == false)
        #expect(helpButton.isHidden == false)
        #expect(helpButton.frame.width <= 24)

        let fluidigmHelp = FASTQImportConfigSheet.barcodeSheetHelpText(for: .ontFluidigmSampleSplit)
        #expect(fluidigmHelp.contains("sample, barcode"))
        #expect(fluidigmHelp.contains("DW472, FLD0001"))

        let pacBioHelp = FASTQImportConfigSheet.barcodeSheetHelpText(for: .ontPacBioBarcodeDemux)
        #expect(pacBioHelp.contains("sample_id, barcode_1, barcode_2"))
        #expect(pacBioHelp.contains("LN94, bc1001, bc1021"))
        #expect(pacBioHelp.contains("Built-in PacBio Sequel 16 v3, Sequel 96 v2, and Sequel 384 v1 barcode IDs"))
    }

    @MainActor
    @Test("ONT demux working directory uses requested subfolder and unique suffix")
    func ontDemuxWorkingDirectoryUsesRequestedSubfolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-folder-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("Run 42", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let controller = MainSplitViewController()
        let request = FASTQOperationLaunchRequest.ontPacBioBarcodeDemux(
            inputFASTQURL: URL(fileURLWithPath: "/data/Run42/fastq_pass", isDirectory: true),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/Run42/barcodes.csv"),
            threads: 1,
            chunkJobs: 2,
            maxReadsPerSlice: 100_000,
            maxBytesPerCutadapt: 536_870_912
        )

        let outputURL = controller.uniqueFASTQOperationOutputDirectory(
            in: root,
            request: request,
            preferredFolderName: "Run 42"
        )

        #expect(outputURL.lastPathComponent == "Run 42-2")
    }

    private static let gib: Int64 = 1_073_741_824

    private static func temporaryFASTQ(named name: String, byteCount: Int64) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-import-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        return url
    }
}

private extension NSView {
    func fastqImportDescendants<T: NSView>(of type: T.Type) -> [T] {
        var matches: [T] = []
        for subview in subviews {
            if let match = subview as? T {
                matches.append(match)
            }
            matches.append(contentsOf: subview.fastqImportDescendants(of: type))
        }
        return matches
    }

    func fastqImportStorageToolPopup() -> NSPopUpButton? {
        fastqImportDescendants(of: NSPopUpButton.self)
            .first { popup in
                (0..<popup.numberOfItems).contains { index in
                    popup.item(at: index)?.representedObject as? ClumpingTool == .bbtools
                }
            }
    }
}

private extension NSPopUpButton {
    var selectedClumpingTool: ClumpingTool? {
        selectedItem?.representedObject as? ClumpingTool
    }

    func selectClumpingTool(_ tool: ClumpingTool) {
        for index in 0..<numberOfItems {
            guard item(at: index)?.representedObject as? ClumpingTool == tool else { continue }
            selectItem(at: index)
            if let action, let target {
                _ = sendAction(action, to: target)
            }
            return
        }
    }
}
