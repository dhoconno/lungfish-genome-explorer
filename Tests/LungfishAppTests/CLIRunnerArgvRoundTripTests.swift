// CLIRunnerArgvRoundTripTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishWorkflow

/// Acceptance test: for each migrated CLI runner family, the
/// argv `buildCLIArguments` produces is both what gets executed
/// (`runner.run(arguments:)`) and what the Operations panel displays
/// (`OperationCenter.buildCLICommand(subcommand:args:)` is built from the
/// same array at each call site) -- there is one array, not two. This test
/// closes the loop by asserting that same argv also parses through the real
/// CLI subcommand parser, so the displayed/recorded command is genuinely
/// runnable, not just self-consistent within the app.
final class CLIRunnerArgvRoundTripTests: XCTestCase {
    func testVariantCallingArgvParsesThroughCallSubcommand() throws {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 \u{2022} LoFreq",
            threads: 4,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10
        )
        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)

        // arguments == ["variants", "call", ...]; VariantsCommand.CallSubcommand
        // parses only its own subcommand's arguments.
        XCTAssertEqual(Array(arguments.prefix(2)), ["variants", "call"])
        let parsed = try VariantsCommand.CallSubcommand.parse(Array(arguments.dropFirst(2)))

        XCTAssertEqual(parsed.bundlePath, "/tmp/Sample.lungfishref")
        XCTAssertEqual(parsed.alignmentTrackID, "aln-1")
        XCTAssertEqual(parsed.caller, "lofreq")
        XCTAssertEqual(parsed.outputTrackName, "Sample 1 \u{2022} LoFreq")
        XCTAssertEqual(parsed.minimumAlleleFrequency, 0.05)
        XCTAssertEqual(parsed.minimumDepth, 10)
    }

    func testVariantCallingArgvParsesThroughTopLevelCLI() throws {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .ivar,
            outputTrackName: "Sample 1",
            threads: 2
        )
        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        XCTAssertTrue(parsed is VariantsCommand.CallSubcommand)
    }

    func testPrimerTrimArgvParsesThroughPrimerTrimSubcommand() throws {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample",
            targetReferenceName: "MT192765.1"
        )

        // arguments == ["bam", "primer-trim", ...]; BAMCommand.PrimerTrimSubcommand
        // parses only its own subcommand's arguments.
        XCTAssertEqual(Array(arguments.prefix(2)), ["bam", "primer-trim"])
        let parsed = try BAMCommand.PrimerTrimSubcommand.parse(Array(arguments.dropFirst(2)))

        XCTAssertEqual(parsed.bundlePath, "/tmp/Sample.lungfishref")
        XCTAssertEqual(parsed.alignmentTrackID, "aln-1")
        XCTAssertEqual(parsed.schemePath, "/tmp/QIASeq.lungfishprimers")
        XCTAssertEqual(parsed.outputTrackName, "Primer-trimmed Sample")
        XCTAssertEqual(parsed.targetReferenceName, "MT192765.1")
    }

    func testPrimerTrimArgvParsesThroughTopLevelCLI() throws {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample"
        )
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        XCTAssertTrue(parsed is BAMCommand.PrimerTrimSubcommand)
    }

    // MARK: - import rnaseq (Phase 5.4 lane RS-GLUE)

    /// A temporary project with the inputs a card's open panel would have chosen. The sheet reads the file system to tell
    /// a salmon folder from a count table, so the inputs exist.
    private func makeRNASeqCardInputs(folders: [String], files: [String] = []) throws -> (root: URL, project: URL, folders: [URL], files: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnaseq-card-argv-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folderURLs = try folders.map { name -> URL in
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let fileURLs = try files.map { name -> URL in
            let url = root.appendingPathComponent(name)
            try "gene_id\tS1\nG1\t1\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        return (root, project, folderURLs, fileURLs)
    }

    /// The bulk card with salmon folders: the sheet's values parse through the real subcommand as the options they
    /// were, a unit left over from another input is not passed, and the argv is the one `lungfish-cli` parses at the root.
    @MainActor
    func testRNASeqBulkCardArgvParsesThroughImportRNASeqSubcommand() throws {
        let inputs = try makeRNASeqCardInputs(folders: ["SRR1", "SRR2"])
        let model = RNASeqImportSheetModel(kind: .bulk, inputs: inputs.folders, projectURL: inputs.project)
        model.name = "  SEQC pair  "
        model.sampleSheet = URL(fileURLWithPath: "/tmp/sheet.tsv")
        model.tx2gene = URL(fileURLWithPath: "/tmp/tx2gene.tsv")
        model.unit = "reads"
        let arguments = try XCTUnwrap(model.request()).arguments

        XCTAssertEqual(Array(arguments.prefix(2)), ["import", "rnaseq"])
        let parsed = try ImportCommand.RNASeqSubcommand.parse(Array(arguments.dropFirst(2)))
        XCTAssertEqual(parsed.inputPaths, inputs.folders.map(\.path))
        XCTAssertEqual(parsed.projectPath, inputs.project.path)
        XCTAssertEqual(parsed.name, "SEQC pair")
        XCTAssertEqual(parsed.samplesPath, "/tmp/sheet.tsv")
        XCTAssertEqual(parsed.tx2genePath, "/tmp/tx2gene.tsv")
        XCTAssertNil(parsed.unit, "salmon states its own unit, and the command refuses --unit with folders")
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(arguments) is ImportCommand.RNASeqSubcommand)
    }

    /// The bulk card with one count table: the unit is passed, and a transcript-to-gene table is not, since the command
    /// refuses it with a table.
    @MainActor
    func testRNASeqBulkCardArgvOfACountTableCarriesItsUnit() throws {
        let inputs = try makeRNASeqCardInputs(folders: [], files: ["counts.tsv"])
        let model = RNASeqImportSheetModel(kind: .bulk, inputs: inputs.files, projectURL: inputs.project)
        model.unit = "umis"
        model.tx2gene = URL(fileURLWithPath: "/tmp/tx2gene.tsv")
        let arguments = try XCTUnwrap(model.request()).arguments

        let parsed = try ImportCommand.RNASeqSubcommand.parse(Array(arguments.dropFirst(2)))
        XCTAssertEqual(parsed.inputPaths, inputs.files.map(\.path))
        XCTAssertEqual(parsed.name, "counts", "the sheet names the result after the table")
        XCTAssertEqual(parsed.unit, "umis")
        XCTAssertNil(parsed.tx2genePath)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(arguments) is ImportCommand.RNASeqSubcommand)
    }

    /// The single-cell card: every genome, the reference set and one `--not-host-bam <sample>=<path>` for each sample
    /// parse through the real subcommand. `outs/` takes the name of the folder above it.
    @MainActor
    func testRNASeqSingleCellCardArgvParsesThroughImportRNASeqSubcommand() throws {
        let inputs = try makeRNASeqCardInputs(folders: ["S1/outs", "S2"])
        // The single-cell sheet takes only what the command reads as a Cell Ranger or STARsolo folder (RS-GLUE-UX SF-1).
        try FileManager.default.createDirectory(
            at: inputs.folders[0].appendingPathComponent("filtered_feature_bc_matrix", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: inputs.folders[1].appendingPathComponent("Solo.out", isDirectory: true), withIntermediateDirectories: true)
        let model = RNASeqImportSheetModel(kind: .singleCell, inputs: inputs.folders, projectURL: inputs.project)
        XCTAssertEqual(model.sampleIDs, ["S1", "S2"])
        model.name = "mixed species"
        model.genomesText = "hg19, mm10"
        model.referenceSet = URL(fileURLWithPath: "/tmp/set")
        model.notHostBAMs = [0: URL(fileURLWithPath: "/tmp/a.bam"), 1: URL(fileURLWithPath: "/tmp/b.bam")]
        model.unit = "umis"
        model.tx2gene = URL(fileURLWithPath: "/tmp/tx2gene.tsv")
        let arguments = try XCTUnwrap(model.request()).arguments

        let parsed = try ImportCommand.RNASeqSubcommand.parse(Array(arguments.dropFirst(2)))
        XCTAssertEqual(parsed.inputPaths, inputs.folders.map(\.path))
        XCTAssertEqual(parsed.genomes, ["hg19", "mm10"])
        XCTAssertEqual(parsed.referenceSetPath, "/tmp/set")
        XCTAssertEqual(parsed.notHostBAMValues, ["S1=/tmp/a.bam", "S2=/tmp/b.bam"])
        XCTAssertNil(parsed.unit, "a single-cell import passes no unit")
        XCTAssertNil(parsed.tx2genePath, "a single-cell import passes no transcript-to-gene table")
        XCTAssertTrue(try LungfishCLI.parseAsRoot(arguments) is ImportCommand.RNASeqSubcommand)
    }

    // MARK: - The RNA-seq plan sheets and the adopt card (Phase 5.4 lane EX-APP)

    /// The bulk plan sheet. Its values parse through `RNASeqQuantSubcommand` as the options they were, its Check button is
    /// `--dry-run` on the same argv, and the CLI's own defaults are shown and sent.
    @MainActor
    func testTheBulkSheetsArgvParsesThroughRNASeqQuantSubcommand() throws {
        let model = RNASeqPlanSheetFixtures.bulkModel()
        model.chain = "star-2.7.11b-genecounts"
        model.requestMemoryMiB = "4096"
        model.requestDiskGiB = "20"
        model.jobRequirements = "OpSys == \"LINUX\""
        let request = try XCTUnwrap(model.request(dryRun: true))

        XCTAssertEqual(Array(request.arguments.prefix(2)), ["rnaseq", "quant"])
        let leaf = try RNASeqCommand.QuantSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(leaf.bundles, model.bundles.map(\.path))
        XCTAssertEqual(leaf.setID, "ensembl-107")
        XCTAssertNil(leaf.project, "a plan writes no result in a project")
        XCTAssertEqual(leaf.planOptions.writePlan, RNASeqPlanSheetFixtures.plans.path)
        XCTAssertEqual(leaf.planOptions.chain?.rawValue, "star-2.7.11b-genecounts")
        XCTAssertEqual(leaf.planOptions.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(leaf.planOptions.requestCPUs, 8, "the CLI's own default is shown and sent")
        XCTAssertEqual(leaf.planOptions.requestMemoryMiB, 4096)
        XCTAssertEqual(leaf.planOptions.requestDiskGiB, 20)
        XCTAssertEqual(leaf.planOptions.jobRequirements, "OpSys == \"LINUX\"")
        XCTAssertTrue(leaf.planOptions.dryRun, "Check is --dry-run")
        XCTAssertNil(leaf.planOptions.executorManifest, "the app's own executor is the command's default")
        XCTAssertEqual(leaf.globalOptions.outputFormat, .json)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqCommand.QuantSubcommand)
        XCTAssertEqual(RNASeqPlanSheetModel.chains, RNASeqQuantPlanChain.allCases.map(\.rawValue), "the sheet offers the CLI's chains")

        let written = try XCTUnwrap(model.request(dryRun: false))
        XCTAssertFalse(written.arguments.contains("--dry-run"), "Write Plan is the same argv without --dry-run")
        let wroteLeaf = try RNASeqCommand.QuantSubcommand.parse(Array(written.arguments.dropFirst(2)))
        XCTAssertFalse(wroteLeaf.planOptions.dryRun)
        XCTAssertEqual(wroteLeaf.planOptions.chain?.rawValue, "star-2.7.11b-genecounts")
    }

    @MainActor
    func testTheBulkSheetsStagedReadsGoWithTheSampleSheetAndNoBundles() throws {
        let model = RNASeqPlanSheetFixtures.bulkModel(staged: true)
        model.executorManifest = URL(fileURLWithPath: "/exec/manifest.json")
        model.image = URL(fileURLWithPath: "/exec/image.json")
        model.imageToolManifest = URL(fileURLWithPath: "/exec/image-manifest.json")
        let request = try XCTUnwrap(model.request(dryRun: false))

        let leaf = try RNASeqCommand.QuantSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertTrue(leaf.bundles.isEmpty)
        XCTAssertEqual(leaf.planOptions.stagedReads, "/data/staged-reads.tsv")
        XCTAssertEqual(leaf.planOptions.samplesheet, "/data/samples.csv")
        XCTAssertNil(leaf.planOptions.chain, "the default chain is left to the command")
        XCTAssertEqual(leaf.planOptions.executorManifest, "/exec/manifest.json")
        XCTAssertEqual(leaf.planOptions.image, "/exec/image.json")
        XCTAssertEqual(leaf.planOptions.imageToolManifest, "/exec/image-manifest.json")
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqCommand.QuantSubcommand)
    }

    /// The 10x plan sheet parses through `RNASeqSoloPlanSubcommand`, with the preset, the barcode list a person supplied and
    /// the 10x filter as the options they were.
    @MainActor
    func testTheTenXSheetsArgvParsesThroughRNASeqSoloPlanSubcommand() throws {
        let model = RNASeqPlanSheetFixtures.tenXModel()
        model.preset = .threePrimeV3Introns
        model.barcodeList = URL(fileURLWithPath: "/data/3M-february-2018.txt")
        model.tenXFilter = "gencode-2020-A"
        let request = try XCTUnwrap(model.request(dryRun: true))

        XCTAssertEqual(Array(request.arguments.prefix(2)), ["rnaseq", "solo-plan"])
        let parsed = try RNASeqSoloPlanSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(parsed.setReference, "ensembl-107")
        XCTAssertEqual(parsed.preset, "tenx-3p-v3-introns")
        XCTAssertEqual(parsed.barcodeList, "/data/3M-february-2018.txt")
        XCTAssertEqual(parsed.tenxFilter, "gencode-2020-A")
        XCTAssertEqual(parsed.stagedReads, "/data/staged-reads.tsv")
        XCTAssertEqual(parsed.samplesheet, "/data/samples.csv")
        XCTAssertEqual(parsed.outputPath, RNASeqPlanSheetFixtures.plans.path)
        XCTAssertEqual(parsed.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(parsed.expectedCells, 3000, "the CLI's own default is shown and sent")
        XCTAssertEqual(parsed.requestCPUs, 8)
        XCTAssertTrue(parsed.dryRun)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqSoloPlanSubcommand)
        XCTAssertEqual(SoloPlanPreset.allCases.map(\.rawValue), ["tenx-3p-v3", "tenx-5p-v2", "tenx-3p-v3-introns"])
    }

    /// The adopt card's argv parses through `ImportRNASeqSubcommand` with `--adopt`, and its Check button and its storage
    /// root are `--dry-run` and `--storage-root`.
    @MainActor
    func testTheAdoptCardsArgvParsesThroughImportRNASeqSubcommandWithDryRunAndStorageRoot() throws {
        let folder = URL(fileURLWithPath: "/data/returned/star-2711-genecounts", isDirectory: true)
        let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
        let model = RNASeqAdoptSheetModel(folder: folder, projectURL: project)
        XCTAssertEqual(model.name, "star-2711-genecounts")
        model.storageRoot = URL(fileURLWithPath: "/data/storage", isDirectory: true)
        let request = try XCTUnwrap(model.request(dryRun: true))

        let parsed = try ImportCommand.RNASeqSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(parsed.inputPaths, [folder.path])
        XCTAssertEqual(parsed.projectPath, project.path)
        XCTAssertEqual(parsed.name, "star-2711-genecounts")
        XCTAssertTrue(parsed.adoptOptions.adopt)
        XCTAssertTrue(parsed.adoptOptions.dryRun)
        XCTAssertEqual(parsed.adoptOptions.storageRoot, "/data/storage")
        XCTAssertNil(parsed.adoptRefusal)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is ImportCommand.RNASeqSubcommand)
        let adopt = try XCTUnwrap(model.request(dryRun: false))
        XCTAssertFalse(adopt.arguments.contains("--dry-run"))
    }
}
