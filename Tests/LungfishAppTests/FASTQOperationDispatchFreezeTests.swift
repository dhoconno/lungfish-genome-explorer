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
//
// The leaf pin of lane A41 (Phase 2.10) names every leaf the dialog launches,
// from one request of each kind the builder writes a command for and one of
// each derivative kind, with what the leaf's row in `CLIEventContractTable`
// says it writes for a machine reader. It was taken at program commit
// c68381a62, before the table moved to LungfishWorkflow. The dialog's runner
// decodes `CLIEvent` lines from standard error whatever the leaf, and every
// leaf the pin lists with events speaks there. A row that changes for a
// dialog leaf moves the pin, and the runner must then read the channel the
// new row names.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
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

    // MARK: - The leaf pin

    /// What a leaf writes for a machine reader, and where, as its row in
    /// `CLIEventContractTable` says. The reason of a `.text` row is left out,
    /// because nothing that reads a dialog run reads it.
    private enum LeafChannel: Equatable, Sendable {
        /// `CLIEvent` lines on `channel`, which `flag` turns on.
        case events(flag: String, channel: CLIEventContract.Channel)
        /// One JSON document on standard output, named by its schema id.
        case result(schemaID: String)
        /// A private stream shape that a later sub-phase retires.
        case legacy(schemaID: String)
        /// Human text only.
        case text

        init(_ contract: CLIEventContract) {
            switch contract {
            case let .events(flag, channel): self = .events(flag: flag, channel: channel)
            case let .result(schemaID): self = .result(schemaID: schemaID)
            case let .legacy(schemaID, _): self = .legacy(schemaID: schemaID)
            case .text: self = .text
            }
        }
    }

    /// The flag of a row whose leaf prints events on every run.
    private static let everyRun = "no switch, every run"

    /// Every leaf the dialog launches, with what its contract row said at
    /// program commit c68381a62.
    private static let leafChannels: [String: LeafChannel] = [
        "assemble": .events(flag: "--json-events", channel: .standardError),
        "fastq adapter-trim": .text,
        "fastq contaminant-filter": .text,
        "fastq deacon-ribo": .text,
        "fastq deduplicate": .text,
        "fastq demultiplex": .text,
        "fastq entropy-filter": .text,
        "fastq error-correct": .text,
        "fastq fixed-trim": .text,
        "fastq genotype": .result(schemaID: "r5-genotype-cohort-report"),
        "fastq length-filter": .text,
        "fastq merge": .text,
        "fastq ont-fluidigm-samples": .events(flag: everyRun, channel: .standardError),
        "fastq ont-pacbio-barcode-demux": .events(flag: everyRun, channel: .standardError),
        "fastq orient": .text,
        "fastq pbaa-cluster": .result(schemaID: "fastq-pbaa-cluster"),
        "fastq primer-remove": .text,
        "fastq qc-summary": .text,
        "fastq quality-trim": .text,
        "fastq repair": .text,
        "fastq reverse-complement": .text,
        "fastq savont-cluster": .result(schemaID: "fastq-savont-cluster"),
        "fastq scrub-human": .text,
        "fastq search-motif": .text,
        "fastq search-text": .text,
        "fastq sequence-filter": .text,
        "fastq subsample": .text,
        "fastq translate": .text,
        "fastq trim": .text,
        "map": .result(schemaID: "r5-map-report"),
    ]

    /// The leaf each cell of the table that builds launches.
    private static let cellLeaves: [String: String] = [
        "refreshQCSummary": "fastq qc-summary",
        "derivative": "fastq subsample",
        "ontFluidigmSampleSplit": "fastq ont-fluidigm-samples",
        "ontPacBioBarcodeDemux": "fastq ont-pacbio-barcode-demux",
        "map": "map",
        "assemble": "assemble",
        "savont": "fastq savont-cluster",
        "pbaa": "fastq pbaa-cluster",
        "ontGenotyping": "fastq genotype",
    ]

    /// One request of each derivative kind, with the leaf it launches.
    private static func derivativeLeaves() -> [(leaf: String, request: FASTQDerivativeRequest)] {
        let primers = FASTQPrimerTrimConfiguration(
            source: .reference, mode: .linked, referenceFasta: "/tmp/dispatch-freeze/primers.fasta",
            errorRate: 0.08, minimumOverlap: 9, tool: .cutadapt
        )
        return [
            ("fastq subsample", .subsampleProportion(0.25)),
            ("fastq subsample", .subsampleCount(1000)),
            ("fastq length-filter", .lengthFilter(min: 50, max: 100)),
            ("fastq search-text", .searchText(query: "virus", field: .description, regex: false)),
            ("fastq search-motif", .searchMotif(pattern: "ACGT", regex: false)),
            ("fastq deduplicate", .deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40)),
            (
                "fastq trim",
                .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil)
            ),
            ("fastq quality-trim", .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight)),
            ("fastq adapter-trim", .adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil)),
            ("fastq fixed-trim", .fixedTrim(from5Prime: 5, from3Prime: 5)),
            (
                "fastq contaminant-filter",
                .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: 31, hammingDistance: 1)
            ),
            ("fastq entropy-filter", .lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5)),
            ("fastq merge", .pairedEndMerge(strictness: .strict, minOverlap: 15)),
            ("fastq repair", .pairedEndRepair),
            ("fastq primer-remove", .primerRemoval(configuration: primers)),
            (
                "fastq sequence-filter",
                .sequencePresenceFilter(
                    sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 4,
                    errorRate: 0.1, keepMatched: true, searchReverseComplement: false
                )
            ),
            ("fastq error-correct", .errorCorrection(kmerSize: 31)),
            ("fastq reverse-complement", .reverseComplement),
            ("fastq translate", .translate(frameOffset: 0)),
            (
                "fastq demultiplex",
                .demultiplex(
                    kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                    trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
                )
            ),
            (
                "fastq orient",
                .orient(referenceURL: Self.reference, wordLength: 12, dbMask: "dust", saveUnoriented: false, extraArguments: [])
            ),
            ("fastq scrub-human", .humanReadScrub(databaseID: "deacon-panhuman", removeReads: true)),
            ("fastq deacon-ribo", .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none)),
        ]
    }

    /// The name of a derivative kind. The switch has no default, so a new kind
    /// does not compile until the pin holds a request of it.
    private static func kind(of request: FASTQDerivativeRequest) -> String {
        switch request {
        case .subsampleProportion: return "subsampleProportion"
        case .subsampleCount: return "subsampleCount"
        case .lengthFilter: return "lengthFilter"
        case .searchText: return "searchText"
        case .searchMotif: return "searchMotif"
        case .deduplicate: return "deduplicate"
        case .fastpTrim: return "fastpTrim"
        case .qualityTrim: return "qualityTrim"
        case .adapterTrim: return "adapterTrim"
        case .fixedTrim: return "fixedTrim"
        case .contaminantFilter: return "contaminantFilter"
        case .lowComplexityFilter: return "lowComplexityFilter"
        case .pairedEndMerge: return "pairedEndMerge"
        case .pairedEndRepair: return "pairedEndRepair"
        case .primerRemoval: return "primerRemoval"
        case .sequencePresenceFilter: return "sequencePresenceFilter"
        case .errorCorrection: return "errorCorrection"
        case .reverseComplement: return "reverseComplement"
        case .translate: return "translate"
        case .demultiplex: return "demultiplex"
        case .orient: return "orient"
        case .humanReadScrub: return "humanReadScrub"
        case .ribosomalRNAFilter: return "ribosomalRNAFilter"
        }
    }

    /// Every request of the pin, the cells of the table that build and one
    /// request of each derivative kind, with the leaf each launches.
    private func leafRequests() throws -> [(leaf: String, request: FASTQOperationLaunchRequest)] {
        var rows: [(leaf: String, request: FASTQOperationLaunchRequest)] = []
        for cell in try cells() {
            guard case .builds = cell.outcome else { continue }
            rows.append((try XCTUnwrap(Self.cellLeaves[cell.name], cell.name), cell.request))
        }
        for (leaf, request) in Self.derivativeLeaves() {
            rows.append((leaf, .derivative(request: request, inputURLs: [Self.reads], outputMode: .perInput)))
        }
        return rows
    }

    /// The argv in the dispatcher's shape, `[subcommand] + arguments`, with the `<derived>` output.
    private func dispatcherArgv(for request: FASTQOperationLaunchRequest) throws -> [String] {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request)
        return [invocation.subcommand] + invocation.arguments
    }

    // MARK: - The leaf pin, checked

    func testThePinHoldsOneRequestOfEachDerivativeKind() {
        let kinds = Self.derivativeLeaves().map { Self.kind(of: $0.request) }
        XCTAssertEqual(kinds.count, 23)
        XCTAssertEqual(Set(kinds).count, 23, "one request of each of the 23 derivative kinds")
    }

    func testEachRequestOfThePinLaunchesTheLeafItNames() throws {
        var launched: Set<String> = []
        for (leaf, request) in try leafRequests() {
            let argv = try dispatcherArgv(for: request)
            let words = leaf.split(separator: " ").map(String.init)
            XCTAssertEqual(Array(argv.prefix(words.count)), words, "\(request.operationDisplayTitle) launches \(leaf)")
            launched.insert(leaf)
        }
        XCTAssertEqual(launched, Set(Self.leafChannels.keys), "the pin names every leaf the dialog launches and no other")
    }

    func testEachDialogLeafWritesWhatItsContractRowSaidAtThePin() throws {
        XCTAssertEqual(Self.everyRun, CLIEventContractTable.alwaysOn)
        for (leaf, channel) in Self.leafChannels.sorted(by: { $0.key < $1.key }) {
            let contract = try XCTUnwrap(CLIEventContractTable.entries[leaf], "\(leaf) has a contract row")
            XCTAssertEqual(LeafChannel(contract), channel, leaf)
        }
    }

    func testEveryDialogLeafWithEventsSpeaksOnStandardErrorWhereTheRunnerReads() {
        let channels = Set(Self.leafChannels.values.compactMap { leafChannel -> CLIEventContract.Channel? in
            guard case let .events(_, channel) = leafChannel else { return nil }
            return channel
        })
        XCTAssertEqual(channels, [.standardError])
    }

    func testTheDialogTurnsOnTheEventsOfEachLeafWhoseRowNamesASwitch() throws {
        var switched: [String] = []
        for (leaf, request) in try leafRequests() {
            guard case let .events(flag, _)? = Self.leafChannels[leaf], flag != Self.everyRun else { continue }
            let argv = try dispatcherArgv(for: request)
            let flagWords = flag.split(separator: " ").map(String.init)
            let holdsFlag = argv.indices.contains { start in
                Array(argv[start...].prefix(flagWords.count)) == flagWords
            }
            XCTAssertTrue(holdsFlag, "\(leaf) launches with \(flag), argv \(argv)")
            switched.append(leaf)
        }
        XCTAssertEqual(switched, ["assemble"])
    }
}
