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
}
