// FASTQOperationDispatchFreezeTests.swift - What each request kind of the FASTQ operations dialog becomes on its way to lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The dialog hands each `FASTQOperationLaunchRequest` to
// `FASTQOperationCLIInvocationBuilder`, shows the invocation as the command of
// its Operations row (`beginFASTQLaunchRequestOperation`), and starts the CLI
// with the invocation's subcommand and arguments. This class freezes that
// route before the dispatcher is reworked. It holds one cell for each of the
// ten request kinds, and the classify kind has three cells, one for each tool
// the request names. A cell pins the first word the dispatcher passes the CLI,
// every word of the row command, what the shipped parser
// (`LungfishCLI.parseAsRoot`, through `RecordedCLICommand`) makes of the row,
// and the output kind the planner gives the request.
//
// The EsViritu and TaxTriage cells name rows the CLI refuses today. The dialog
// writes their input paths as bare words, and `esviritu detect` and
// `taxtriage run` take them with `--input`. `taxtriage run` also needs
// `--output`. `XCTExpectFailure` holds both as known issues, so each pin fails
// when a repair makes its row parse.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class FASTQOperationDispatchFreezeTests: XCTestCase {
    // MARK: - The table

    /// What the shipped parser makes of a row.
    private enum Reading {
        /// The row parses to this command type.
        case parses(any ParsableCommand.Type)
        /// The CLI refuses the row today, for this reason.
        case refusedToday(String)
    }

    private struct Cell {
        let name: String
        let request: FASTQOperationLaunchRequest
        /// `FASTQCLIInvocation.subcommand`, the first word the dispatcher passes the CLI.
        let subcommand: String
        /// Every word of the row command after `lungfish-cli`.
        let words: [String]
        let reading: Reading
        let outputKind: FASTQOperationExecutionOutputKind
    }

    private static let reads = URL(fileURLWithPath: "/tmp/dispatch-freeze/reads.fastq")
    private static let barcodes = URL(fileURLWithPath: "/tmp/dispatch-freeze/barcodes.csv")
    private static let reference = URL(fileURLWithPath: "/tmp/dispatch-freeze/reference.fasta")
    private static let guide = URL(fileURLWithPath: "/tmp/dispatch-freeze/guide.fasta")
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/dispatch-freeze/out", isDirectory: true)

    private func cells() throws -> [Cell] {
        let reads = Self.reads.path
        let barcodes = Self.barcodes.path
        let reference = Self.reference.path
        let guide = Self.guide.path
        let out = Self.outputDirectory.path
        let savont = FASTQSavontClusteringRequest(
            inputURLs: [Self.reads],
            outputDirectoryURL: Self.outputDirectory,
            singleInputOutputName: nil,
            threads: 2,
            qualityValueCutoff: 90,
            minimumClusterSize: 3,
            minimumReadLength: nil,
            maximumReadLength: nil,
            singleStrand: false
        )
        let pbaa = try PBAAClusteringRunRequest(
            inputFASTQURL: Self.reads,
            guideSourceURL: Self.guide,
            outputDirectory: Self.outputDirectory,
            outputName: "sample",
            threads: 4,
            seed: 7
        )
        let assembly = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [Self.reads],
            projectName: "demo",
            outputDirectory: Self.outputDirectory,
            pairedEnd: false,
            threads: 2
        )
        let genotyping = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [Self.reads],
            referenceSourceURL: Self.reference,
            outputDirectory: Self.outputDirectory,
            outputName: "genotype",
            analysisName: "genotype",
            threads: 2,
            minSupport: 1,
            mode: .ontSampleBundles,
            readType: .ont
        )
        return [
            Cell(
                name: "refreshQCSummary",
                request: .refreshQCSummary(inputURLs: [Self.reads]),
                subcommand: "fastq",
                words: ["fastq", "qc-summary", reads, "--output", "<derived>"],
                reading: .parses(FastqQCSummarySubcommand.self),
                outputKind: .jsonReport
            ),
            Cell(
                name: "derivative",
                request: .derivative(request: .subsampleProportion(0.5), inputURLs: [Self.reads], outputMode: .perInput),
                subcommand: "fastq",
                words: ["fastq", "subsample", reads, "--proportion", "0.5", "-o", "<derived>"],
                reading: .parses(FastqSubsampleSubcommand.self),
                outputKind: .fastqFile
            ),
            Cell(
                name: "ontFluidigmSampleSplit",
                request: .ontFluidigmSampleSplit(inputFASTQURL: Self.reads, barcodeDefinitionsURL: Self.barcodes, threads: 2),
                subcommand: "fastq",
                words: ["fastq", "ont-fluidigm-samples", reads, "--barcodes", barcodes, "--output", "<derived>", "--threads", "2"],
                reading: .parses(FastqONTFluidigmSamplesSubcommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "ontPacBioBarcodeDemux",
                request: .ontPacBioBarcodeDemux(
                    inputFASTQURL: Self.reads,
                    barcodeDefinitionsURL: Self.barcodes,
                    threads: 2,
                    chunkJobs: 2,
                    maxReadsPerSlice: 1000,
                    maxBytesPerCutadapt: 1_000_000
                ),
                subcommand: "fastq",
                words: [
                    "fastq", "ont-pacbio-barcode-demux", reads, "--barcodes", barcodes, "--output", "<derived>",
                    "--threads", "2", "--chunk-jobs", "2", "--max-reads-per-slice", "1000",
                    "--max-bytes-per-cutadapt", "1000000",
                ],
                reading: .parses(FastqONTPacBioBarcodeDemuxSubcommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "map",
                request: .map(inputURLs: [Self.reads], referenceURL: Self.reference, outputMode: .perInput),
                subcommand: "map",
                words: ["map", reads, "--reference", reference],
                reading: .parses(MapCommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "assemble",
                request: .assemble(request: assembly, outputMode: .perInput),
                subcommand: "assemble",
                words: [
                    "assemble", reads, "--json-events", "--assembler", "spades", "--read-type", "illumina-short-reads",
                    "--project-name", "demo", "--threads", "2", "--output", "<derived>",
                ],
                reading: .parses(AssembleCommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "classify, Kraken2",
                request: .classify(tool: .kraken2, inputURLs: [Self.reads], databaseName: "kraken-db"),
                subcommand: "conda classify",
                words: ["conda", "classify", reads, "--db", "kraken-db"],
                reading: .parses(ClassifyCommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "classify, EsViritu",
                request: .classify(tool: .esViritu, inputURLs: [Self.reads], databaseName: "esv-db"),
                subcommand: "esviritu",
                words: ["esviritu", "detect", reads, "--db", "esv-db"],
                reading: .refusedToday("esviritu detect takes its reads with --input, and the dialog writes them as bare words"),
                outputKind: .directory
            ),
            Cell(
                name: "classify, TaxTriage",
                request: .classify(tool: .taxTriage, inputURLs: [Self.reads], databaseName: "tax-db"),
                subcommand: "taxtriage",
                words: ["taxtriage", "run", reads, "--db", "tax-db"],
                reading: .refusedToday("taxtriage run needs --output and takes its reads with --input, and the dialog's row has neither"),
                outputKind: .directory
            ),
            Cell(
                name: "savont",
                request: .savont(request: savont),
                subcommand: "fastq",
                words: [
                    "fastq", "savont-cluster", reads, "--output", "<derived>", "--threads", "2",
                    "--quality-value-cutoff", "90", "--min-cluster-size", "3",
                ],
                reading: .parses(FastqSavontClusterSubcommand.self),
                outputKind: .fastqFile
            ),
            Cell(
                name: "pbaa",
                request: .pbaa(request: pbaa),
                subcommand: "fastq",
                words: [
                    "fastq", "pbaa-cluster", reads, "--guide", guide, "--output-dir", out,
                    "--output-name", "sample", "--threads", "4", "--seed", "7",
                ],
                reading: .parses(FastqPBAAClusterSubcommand.self),
                outputKind: .directory
            ),
            Cell(
                name: "ontGenotyping",
                request: .ontGenotyping(request: genotyping),
                subcommand: "fastq",
                words: [
                    "fastq", "genotype", reads, "--mode", "ont-sample-bundles", "--read-type", "ont",
                    "--reference", reference, "--output-dir", out, "--output-name", "genotype",
                    "--analysis-name", "genotype", "--threads", "2", "--sort-threads", "4", "--min-support", "1",
                ],
                reading: .parses(FastqGenotypingSubcommand.self),
                outputKind: .directory
            ),
        ]
    }

    /// The command the Operations row holds once `beginFASTQLaunchRequestOperation` registers it, as the launch site does.
    private func rowCommand(for request: FASTQOperationLaunchRequest) throws -> String? {
        let reporter = RecordingOperationReporter()
        _ = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(request.operationDisplayTitle)",
            request: request,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: reporter
        ) { _ in }.requireStarted()
        return reporter.items.first?.cliCommand
    }

    // MARK: - The table, checked

    func testTheTableHoldsOneCellForEachOfTheTenRequestKinds() throws {
        let cells = try cells()
        XCTAssertEqual(cells.count, 12, "nine kinds with one cell each, and the classify kind with three")
        let kinds = Set(cells.map { cell -> String in
            switch cell.request {
            case .refreshQCSummary: return "refreshQCSummary"
            case .derivative: return "derivative"
            case .ontFluidigmSampleSplit: return "ontFluidigmSampleSplit"
            case .ontPacBioBarcodeDemux: return "ontPacBioBarcodeDemux"
            case .map: return "map"
            case .assemble: return "assemble"
            case .classify: return "classify"
            case .savont: return "savont"
            case .pbaa: return "pbaa"
            case .ontGenotyping: return "ontGenotyping"
            }
        })
        XCTAssertEqual(kinds.count, 10)
    }

    func testEachCellRecordsTheRowCommandItsInvocationSpells() throws {
        for cell in try cells() {
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: cell.request)
            XCTAssertEqual(invocation.subcommand, cell.subcommand, cell.name)
            let row = try XCTUnwrap(try rowCommand(for: cell.request), cell.name)
            XCTAssertEqual(
                row,
                FASTQOperationCLIInvocationBuilder.commandLine(for: invocation),
                "\(cell.name), the row is the invocation's command line"
            )
            XCTAssertEqual(try RecordedCLICommand.arguments(of: row), cell.words, cell.name)
        }
    }

    func testTheShippedParserReadsEachRowAsItsCommand() throws {
        for cell in try cells() {
            let row = try XCTUnwrap(try rowCommand(for: cell.request), cell.name)
            switch cell.reading {
            case .parses(let commandType):
                let parsed = try RecordedCLICommand.parse(row)
                XCTAssertTrue(
                    Swift.type(of: parsed) == commandType,
                    "\(cell.name), parsed \(Swift.type(of: parsed)), expected \(commandType), from: \(row)"
                )
            case .refusedToday(let reason):
                try XCTExpectFailure(reason) {
                    XCTAssertNoThrow(try RecordedCLICommand.parse(row), "\(cell.name), from: \(row)")
                }
            }
        }
    }

    func testThePlannerGivesEachRequestKindTheOutputKindItsCommandWrites() throws {
        let base = URL(fileURLWithPath: "/tmp/dispatch-freeze/plans", isDirectory: true)
        for cell in try cells() {
            let plans = FASTQOperationPlanner().makeExecutionPlans(
                originalRequest: cell.request,
                resolvedRequest: cell.request,
                baseOutputDirectory: base
            )
            XCTAssertEqual(plans.map(\.outputKind), [cell.outputKind], cell.name)
        }
    }
}
