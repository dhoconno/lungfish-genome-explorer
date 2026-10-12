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
// the request names. A cell that builds pins the first word the dispatcher
// passes the CLI, every word of the row command, what the shipped parser
// (`LungfishCLI.parseAsRoot`, through `RecordedCLICommand`) makes of the row and
// of the argv in the dispatcher's shape (`[subcommand] + arguments`, with the
// row's `<derived>` output, because the argv of a run waits for lane S3), and
// the output kind the planner gives the request.
//
// The three classify cells hold decision D1 of Phase 2.8. The classification,
// EsViritu and TaxTriage wizards the dialog embeds start their runs through
// their own routes, so no production path hands a `.classify` request to the
// builder, and the builder throws for it. The row of such a request records no
// command, and no subcommand of several words can reach the CLI as one
// argument. Before D1 the Kraken2 row spelled `conda classify`, which the
// dispatcher passed as one argument, and the CLI refused the EsViritu and
// TaxTriage rows.

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

    private enum Outcome {
        /// The builder writes `subcommand` as the first word, the row holds `words`, and the shipped parser makes `command` of the row.
        case builds(subcommand: String, words: [String], command: any ParsableCommand.Type)
        /// The builder throws this error, and the row holds no command.
        case refuses(FASTQOperationCLIInvocationError)
    }

    private struct Cell {
        let name: String
        let request: FASTQOperationLaunchRequest
        let outcome: Outcome
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
                outcome: .builds(
                    subcommand: "fastq",
                    words: ["fastq", "qc-summary", reads, "--output", "<derived>"],
                    command: FastqQCSummarySubcommand.self
                ),
                outputKind: .jsonReport
            ),
            Cell(
                name: "derivative",
                request: .derivative(request: .subsampleProportion(0.5), inputURLs: [Self.reads], outputMode: .perInput),
                outcome: .builds(
                    subcommand: "fastq",
                    words: ["fastq", "subsample", reads, "--proportion", "0.5", "-o", "<derived>"],
                    command: FastqSubsampleSubcommand.self
                ),
                outputKind: .fastqFile
            ),
            Cell(
                name: "ontFluidigmSampleSplit",
                request: .ontFluidigmSampleSplit(inputFASTQURL: Self.reads, barcodeDefinitionsURL: Self.barcodes, threads: 2),
                outcome: .builds(
                    subcommand: "fastq",
                    words: ["fastq", "ont-fluidigm-samples", reads, "--barcodes", barcodes, "--output", "<derived>", "--threads", "2"],
                    command: FastqONTFluidigmSamplesSubcommand.self
                ),
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
                outcome: .builds(
                    subcommand: "fastq",
                    words: [
                        "fastq", "ont-pacbio-barcode-demux", reads, "--barcodes", barcodes, "--output", "<derived>",
                        "--threads", "2", "--chunk-jobs", "2", "--max-reads-per-slice", "1000",
                        "--max-bytes-per-cutadapt", "1000000",
                    ],
                    command: FastqONTPacBioBarcodeDemuxSubcommand.self
                ),
                outputKind: .directory
            ),
            Cell(
                name: "map",
                request: .map(inputURLs: [Self.reads], referenceURL: Self.reference, outputMode: .perInput),
                outcome: .builds(
                    subcommand: "map",
                    words: ["map", reads, "--reference", reference],
                    command: MapCommand.self
                ),
                outputKind: .directory
            ),
            Cell(
                name: "assemble",
                request: .assemble(request: assembly, outputMode: .perInput),
                outcome: .builds(
                    subcommand: "assemble",
                    words: [
                        "assemble", reads, "--json-events", "--assembler", "spades", "--read-type", "illumina-short-reads",
                        "--project-name", "demo", "--threads", "2", "--output", "<derived>",
                    ],
                    command: AssembleCommand.self
                ),
                outputKind: .directory
            ),
            Cell(
                name: "classify, Kraken2",
                request: .classify(tool: .kraken2, inputURLs: [Self.reads], databaseName: "kraken-db"),
                outcome: .refuses(.classifierLaunchHasNoDialogCommand(tool: .kraken2)),
                outputKind: .directory
            ),
            Cell(
                name: "classify, EsViritu",
                request: .classify(tool: .esViritu, inputURLs: [Self.reads], databaseName: "esv-db"),
                outcome: .refuses(.classifierLaunchHasNoDialogCommand(tool: .esViritu)),
                outputKind: .directory
            ),
            Cell(
                name: "classify, TaxTriage",
                request: .classify(tool: .taxTriage, inputURLs: [Self.reads], databaseName: "tax-db"),
                outcome: .refuses(.classifierLaunchHasNoDialogCommand(tool: .taxTriage)),
                outputKind: .directory
            ),
            Cell(
                name: "savont",
                request: .savont(request: savont),
                outcome: .builds(
                    subcommand: "fastq",
                    words: [
                        "fastq", "savont-cluster", reads, "--output", "<derived>", "--threads", "2",
                        "--quality-value-cutoff", "90", "--min-cluster-size", "3",
                    ],
                    command: FastqSavontClusterSubcommand.self
                ),
                outputKind: .fastqFile
            ),
            Cell(
                name: "pbaa",
                request: .pbaa(request: pbaa),
                outcome: .builds(
                    subcommand: "fastq",
                    words: [
                        "fastq", "pbaa-cluster", reads, "--guide", guide, "--output-dir", out,
                        "--output-name", "sample", "--threads", "4", "--seed", "7",
                    ],
                    command: FastqPBAAClusterSubcommand.self
                ),
                outputKind: .directory
            ),
            Cell(
                name: "ontGenotyping",
                request: .ontGenotyping(request: genotyping),
                outcome: .builds(
                    subcommand: "fastq",
                    words: [
                        "fastq", "genotype", reads, "--mode", "ont-sample-bundles", "--read-type", "ont",
                        "--reference", reference, "--output-dir", out, "--output-name", "genotype",
                        "--analysis-name", "genotype", "--threads", "2", "--sort-threads", "4", "--min-support", "1",
                    ],
                    command: FastqGenotypingSubcommand.self
                ),
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

    func testEachCellBuildsTheInvocationAndRecordsTheRowCommandItPins() throws {
        for cell in try cells() {
            let row = try rowCommand(for: cell.request)
            switch cell.outcome {
            case .builds(let subcommand, let words, _):
                let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: cell.request)
                XCTAssertEqual(invocation.subcommand, subcommand, cell.name)
                let recorded = try XCTUnwrap(row, cell.name)
                XCTAssertEqual(
                    recorded,
                    FASTQOperationCLIInvocationBuilder.commandLine(for: invocation),
                    "\(cell.name), the row is the invocation's command line"
                )
                XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), words, cell.name)
            case .refuses(let error):
                XCTAssertThrowsError(try FASTQOperationCLIInvocationBuilder().buildInvocation(for: cell.request), cell.name) {
                    XCTAssertEqual($0 as? FASTQOperationCLIInvocationError, error, cell.name)
                }
                XCTAssertNil(row, "\(cell.name), a request with no command records none")
            }
        }
    }

    func testTheShippedParserReadsEachRowAndEachDispatcherArgvAsItsCommand() throws {
        for cell in try cells() {
            guard case .builds(_, _, let commandType) = cell.outcome else { continue }
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: cell.request)
            let row = try XCTUnwrap(try rowCommand(for: cell.request), cell.name)
            let fromRow = try RecordedCLICommand.parse(row)
            XCTAssertTrue(
                Swift.type(of: fromRow) == commandType,
                "\(cell.name), parsed \(Swift.type(of: fromRow)), expected \(commandType), from: \(row)"
            )
            // The dispatcher starts the CLI with `[subcommand] + arguments`, so a
            // subcommand of several words reaches it as one argument. The
            // `conda classify` rows did, and the CLI would have refused them.
            XCTAssertFalse(
                invocation.subcommand.contains(where: \.isWhitespace),
                "\(cell.name), the subcommand \(invocation.subcommand) is one word"
            )
            let argv = [invocation.subcommand] + invocation.arguments
            let fromArgv = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(argv))
            XCTAssertTrue(
                Swift.type(of: fromArgv) == commandType,
                "\(cell.name), the dispatcher's argv parsed \(Swift.type(of: fromArgv)), expected \(commandType)"
            )
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
