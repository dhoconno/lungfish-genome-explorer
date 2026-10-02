// MainSplitGenomicsDisplayOperationTests.swift - begin() sites in MainSplitViewController+GenomicsDisplay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The genomics display launches register four kinds of Operations panel rows
// through static begin helpers (R4). None of them declares a bundle lock, so a
// real center never refuses them, and a recording reporter that holds a lock
// stands in for the refusal. The two reference downloads have no lungfish-cli
// equivalent, so their tests pin the missing command. The FASTQ derivative
// row and the FASTQ operations dialog row record the `lungfish-cli fastq`
// command FASTQOperationCLIInvocationBuilder builds for the same request
// (R3), which the tests parse with the real CLI parser and compare with the
// request's values. A request with a setting no lungfish-cli option
// expresses records no command at either site, a pinned CLI parity gap.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class MainSplitGenomicsDisplayOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2h/Project.lungfish"),
        windowStateScopeID: UUID()
    )
    private let inputBundle = URL(
        fileURLWithPath: "/tmp/lane 1a2h/Project.lungfish/Imports/Sample 1.lungfishfastq",
        isDirectory: true
    )

    // MARK: - Reference downloads (sites 40 and 41)

    func testNakedBundleReferenceDownloadRecordsADownloadRowWithNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "Wuhan-Hu-1",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Wuhan-Hu-1 Reference")
        XCTAssertEqual(item.initialDetail, "Searching NCBI\u{2026}")
        XCTAssertEqual(item.operationType, .download)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. No lungfish-cli command adds a downloaded reference to
        // an existing bundle. The closest is `fetch genome`, which builds a new
        // bundle from one accession. When a merge command exists, record it and
        // replace this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testRefusedReferenceDownloadsLaunchNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let naked = MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "Wuhan-Hu-1",
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(naked.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    // MARK: - FASTQ derivative from the dataset viewport (site 42)

    /// Registers the derivative row on a recording reporter and checks what
    /// every derivative row shares.
    private func recordedDerivativeRow(
        _ request: FASTQDerivativeRequest,
        inputURL: URL? = nil
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        let operationID = try MainSplitViewController.beginFASTQDerivativeOperation(
            request: request,
            inputURL: inputURL ?? inputBundle,
            routeContext: routeContext,
            reporter: reporter
        ).requireStarted()
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.id, operationID)
        XCTAssertEqual(item.title, "FASTQ: \(request.operationLabel)")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    func testFASTQDerivativeRowRecordsTheCommandForTheInputBundle() throws {
        let item = try recordedDerivativeRow(.lengthFilter(min: 100, max: 5000))

        XCTAssertEqual(item.title, "FASTQ: Length Filter")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqLengthFilterSubcommand.self)
        XCTAssertEqual(command.input, inputBundle.path)
        XCTAssertEqual(command.minLength, 100)
        XCTAssertEqual(command.maxLength, 5000)
        XCTAssertEqual(command.output.output, "<derived>")
    }

    func testFASTQDerivativeRowCarriesTheInputBundlesRecordedPairing() throws {
        let directory = try TestTempDirectory.make(prefix: "genomics-display-operation")
        defer { TestTempDirectory.cleanup(directory) }
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002", in: directory, pairCount: 2, naming: .identical, pairingMode: .interleaved
        )

        let item = try recordedDerivativeRow(.subsampleCount(10), inputURL: bundle.bundleURL)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqSubsampleSubcommand.self)
        XCTAssertEqual(command.input, bundle.bundleURL.path)
        XCTAssertEqual(command.pairing.pairing, .interleaved, "the row passes the pairing the bundle recorded")
        XCTAssertEqual(command.count, 10)
    }

    func testFASTQDerivativeCommandsParseWithTheRequestsValues() throws {
        for testCase in GenomicsDisplayDerivativeCases.bothSitesRecord() {
            let item = try recordedDerivativeRow(testCase.request)
            let parsed: any ParsableCommand
            do {
                parsed = try RecordedCLICommand.parse(item.cliCommand)
            } catch {
                XCTFail("\(testCase.name) recorded a command that does not parse: \(item.cliCommand ?? "nil") (\(error))")
                continue
            }
            do {
                try testCase.verify(parsed, inputBundle.path)
            } catch {
                XCTFail("\(testCase.name): \(error)")
            }
        }
    }

    func testFASTQDerivativeRowRecordsTheInvocationTheDialogRowRecordsForTheSameRequest() throws {
        // One builder (R3). The dataset viewport row used to build its own
        // string, which recorded seqkit, cutadapt, vsearch and deacon commands
        // for five kinds and left values out of three more.
        let requests = GenomicsDisplayDerivativeCases.bothSitesRecord().map(\.request)
            + Self.requestsNoCLIOptionExpresses.map(\.1)
        for request in requests {
            let derivativeRow = try recordedDerivativeRow(request)
            let dialogRow = try recordedLaunchRow(.derivative(
                request: request, inputURLs: [inputBundle], outputMode: .perInput
            ))
            XCTAssertEqual(derivativeRow.cliCommand, dialogRow.cliCommand, request.operationLabel)
        }
    }

    func testFASTQDerivativeRowCarriesTheInputBundlesPairingForTheLengthFilter() throws {
        // The length filter row used to record no `--pairing`, unlike every
        // other kind with the option, so the CLI fell back to its own detection.
        let directory = try TestTempDirectory.make(prefix: "genomics-display-operation")
        defer { TestTempDirectory.cleanup(directory) }
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002", in: directory, pairCount: 2, naming: .identical, pairingMode: .interleaved
        )

        let item = try recordedDerivativeRow(.lengthFilter(min: 50, max: 300), inputURL: bundle.bundleURL)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqLengthFilterSubcommand.self)
        XCTAssertEqual(command.input, bundle.bundleURL.path)
        XCTAssertEqual(command.minLength, 50)
        XCTAssertEqual(command.maxLength, 300)
        XCTAssertEqual(command.pairing.pairing, .interleaved, "the run passes the bundle's interleaved pairing")
    }

    /// Requests that carry a setting no lungfish-cli option expresses. The
    /// invocation builder refuses them, so neither FASTQ row records a
    /// command, and the dialog run fails with the builder's error. The
    /// dataset viewport runs them in process.
    static let requestsNoCLIOptionExpresses: [(String, FASTQDerivativeRequest)] = [
        (
            "adapter trim from an adapter FASTA",
            .adapterTrim(mode: .fastaFile, sequence: nil, sequenceR2: nil, fastaFilename: "adapters.fasta")
        ),
        (
            "adapter trim with a read 2 adapter",
            .adapterTrim(mode: .specified, sequence: "ACGTACGT", sequenceR2: "TTGGCCAA", fastaFilename: nil)
        ),
        (
            "fastp trim with an adapter FASTA",
            .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .fastaFile, adapterSequence: nil)
        ),
        (
            "orient keeping unoriented reads",
            .orient(
                referenceURL: URL(fileURLWithPath: "/tmp/lane 1a2h/ref.fasta"),
                wordLength: 12, dbMask: "dust", saveUnoriented: true, extraArguments: []
            )
        ),
        (
            "demultiplex with a symmetry mode",
            .demultiplex(
                kitID: "custom-kit", customCSVPath: nil, location: "bothends", symmetryMode: .symmetric,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            )
        ),
        (
            "demultiplex with sample assignments",
            .demultiplex(
                kitID: "custom-kit", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true,
                sampleAssignments: [FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: "bc01")],
                kitOverride: nil
            )
        ),
        (
            "demultiplex with a kit override",
            .demultiplex(
                kitID: "custom-kit", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil,
                kitOverride: BarcodeKitDefinition(id: "custom-kit", displayName: "Custom kit", barcodes: [])
            )
        ),
        (
            "literal primers with cutadapt",
            .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                source: .literal, forwardSequence: "ACGTACGTAC", tool: .cutadapt
            ))
        ),
        (
            "bbduk primers keeping untrimmed reads",
            .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                source: .literal, forwardSequence: "ACGTACGTAC", keepUntrimmed: true, tool: .bbduk
            ))
        ),
    ]

    func testFASTQDerivativeRequestsNoCLIOptionExpressesRecordNoCommandAsParityGaps() throws {
        // CLI parity gap. `fastq adapter-trim` and `fastq trim` take no adapter
        // FASTA or read 2 adapter, `fastq orient` cannot keep unoriented reads,
        // `fastq demultiplex` has no symmetry mode, sample assignment or kit
        // override option, and `fastq primer-remove` encodes only reference
        // cutadapt-linked trimming and literal or reference bbduk trimming
        // with the default read-mode flags. The adapter FASTA row used to
        // record an `adapter-trim` command that auto-detected adapters. When
        // the CLI gains an option, the builder encodes it and this pin becomes
        // a parse test.
        for (name, request) in Self.requestsNoCLIOptionExpresses {
            let item = try recordedDerivativeRow(request)
            XCTAssertNil(item.cliCommand, name)
            XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand), name)
        }
    }

    /// `runFASTQOperation` ends its begin call with `requireStarted()`, so a
    /// refusal throws before the derivative service is called.
    func testRefusedFASTQDerivativeBeginThrowsOperationRefusedErrorFromRequireStarted() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let result = MainSplitViewController.beginFASTQDerivativeOperation(
            request: .lengthFilter(min: 100, max: nil),
            inputURL: inputBundle,
            routeContext: routeContext,
            reporter: reporter
        )

        XCTAssertNil(result.startedID)
        XCTAssertThrowsError(try result.requireStarted()) { error in
            XCTAssertEqual((error as? OperationRefusedError)?.refusal.blockingOperationTitle, "Importing BAM")
        }
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items[0].logs.isEmpty, "a refused run reports nothing further")
    }

    // MARK: - FASTQ operations dialog launch (site 43)

    /// Registers the launch row on a recording reporter and checks what every
    /// launch row shares.
    private func recordedLaunchRow(
        _ request: FASTQOperationLaunchRequest,
        title: String = "FASTQ: Test run"
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: title,
            request: request,
            executionService: FASTQOperationExecutionService(),
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    /// Registers the launch row and parses its recorded command as `type`.
    private func recordedLaunchCommand<Command: ParsableCommand>(
        _ request: FASTQOperationLaunchRequest,
        as type: Command.Type
    ) throws -> Command {
        let item = try recordedLaunchRow(request)
        return try RecordedCLICommand.parse(item.cliCommand, as: type)
    }

    func testFASTQLaunchRequestRowRecordsTheInvocationTheExecutionServiceBuilds() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 100, max: 5000),
            inputURLs: [inputBundle],
            outputMode: .perInput
        )

        let item = try recordedLaunchRow(request, title: "FASTQ: Length Filter")

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: invocation.subcommand, args: invocation.arguments)
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqLengthFilterSubcommand.self)
        XCTAssertEqual(command.input, inputBundle.path)
        XCTAssertEqual(command.minLength, 100)
        XCTAssertEqual(command.maxLength, 5000)
        XCTAssertEqual(command.output.output, "<derived>")
    }

    func testFASTQLaunchRequestRowCarriesTheInputBundlesRecordedPairing() throws {
        let directory = try TestTempDirectory.make(prefix: "genomics-display-operation")
        defer { TestTempDirectory.cleanup(directory) }
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002", in: directory, pairCount: 2, naming: .identical, pairingMode: .interleaved
        )

        let item = try recordedLaunchRow(.derivative(
            request: .subsampleCount(10), inputURLs: [bundle.bundleURL], outputMode: .perInput
        ))

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqSubsampleSubcommand.self)
        XCTAssertEqual(command.input, bundle.bundleURL.path)
        XCTAssertEqual(command.pairing.pairing, .interleaved, "the row passes the pairing the bundle recorded")
        XCTAssertEqual(command.count, 10)
    }

    func testFASTQLaunchRequestDerivativeCommandsParseWithTheRequestsValues() throws {
        for testCase in GenomicsDisplayDerivativeCases.bothSitesRecord() {
            let item = try recordedLaunchRow(.derivative(
                request: testCase.request, inputURLs: [inputBundle], outputMode: .perInput
            ))
            let parsed: any ParsableCommand
            do {
                parsed = try RecordedCLICommand.parse(item.cliCommand)
            } catch {
                XCTFail("\(testCase.name) recorded a command that does not parse: \(item.cliCommand ?? "nil") (\(error))")
                continue
            }
            do {
                try testCase.verify(parsed, inputBundle.path)
            } catch {
                XCTFail("\(testCase.name): \(error)")
            }
        }
    }

    func testFASTQLaunchRequestsTheBuilderCannotEncodeRecordNoCommandAsParityGaps() throws {
        // CLI parity gap. The invocation builder throws for these requests, so
        // the row records no command, and the run fails with the builder's
        // error because the execution service builds the same invocation. The
        // dataset viewport runs the same settings in process. When the builder
        // encodes one, the row records the command and its pin becomes a parse test.
        for (name, request) in Self.requestsNoCLIOptionExpresses {
            let item = try recordedLaunchRow(.derivative(
                request: request, inputURLs: [inputBundle], outputMode: .perInput
            ))
            XCTAssertNil(item.cliCommand, name)
            XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand), name)
        }
    }

    /// Asserts that the recorded command carries `--threads count`.
    ///
    /// The commands that declare their own `--threads` option (savont-cluster,
    /// pbaa-cluster and ont-fluidigm-samples) never receive the value through the
    /// real parser. The root command's global `--threads` option consumes the flag
    /// wherever it appears, so the subcommand keeps its default. The recorded
    /// string is right and the CLI drops the value, a defect for the CLI parity lane.
    private func assertRecordsThreads(
        _ command: String?,
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let words = try RecordedCLICommand.arguments(of: command)
        let index = try XCTUnwrap(words.firstIndex(of: "--threads"), "no --threads in \(words)", file: file, line: line)
        XCTAssertEqual(words[index + 1], String(count), file: file, line: line)
    }

    func testFASTQLaunchRequestRowsForTheOtherRequestKindsParseWithTheRequestsValues() throws {
        let second = inputBundle.deletingLastPathComponent().appendingPathComponent("Sample 2.lungfishfastq")
        let reads = inputBundle.appendingPathComponent("reads.fastq")
        let sheet = URL(fileURLWithPath: "/tmp/lane 1a2h/barcodes.csv")
        let reference = URL(fileURLWithPath: "/tmp/lane 1a2h/ref.fasta")
        let analyses = URL(fileURLWithPath: "/tmp/lane 1a2h/Project.lungfish/Analyses", isDirectory: true)

        let qc = try recordedLaunchCommand(
            .refreshQCSummary(inputURLs: [inputBundle, second]),
            as: FastqQCSummarySubcommand.self
        )
        XCTAssertEqual(qc.inputs, [inputBundle.path, second.path])
        XCTAssertEqual(qc.output.output, "<derived>")

        let fluidigmItem = try recordedLaunchRow(.ontFluidigmSampleSplit(
            inputFASTQURL: reads, barcodeDefinitionsURL: sheet, threads: 4
        ))
        let fluidigm = try RecordedCLICommand.parse(
            fluidigmItem.cliCommand, as: FastqONTFluidigmSamplesSubcommand.self
        )
        XCTAssertEqual(fluidigm.input, reads.path)
        XCTAssertEqual(fluidigm.barcodes, sheet.path)
        XCTAssertEqual(fluidigm.output, "<derived>")
        try assertRecordsThreads(fluidigmItem.cliCommand, 4)

        let savontItem = try recordedLaunchRow(.savont(request: FASTQSavontClusteringRequest(
            inputURLs: [inputBundle], outputDirectoryURL: analyses, singleInputOutputName: "sample.fasta",
            threads: 4, qualityValueCutoff: 90, minimumClusterSize: 3,
            minimumReadLength: 1000, maximumReadLength: 2000, singleStrand: true
        )))
        let savont = try RecordedCLICommand.parse(savontItem.cliCommand, as: FastqSavontClusterSubcommand.self)
        XCTAssertEqual(savont.input, inputBundle.path)
        XCTAssertEqual(savont.output, "<derived>")
        try assertRecordsThreads(savontItem.cliCommand, 4)
        XCTAssertEqual(savont.qualityValueCutoff, 90)
        XCTAssertEqual(savont.minimumClusterSize, 3)
        XCTAssertEqual(savont.minimumReadLength, 1000)
        XCTAssertEqual(savont.maximumReadLength, 2000)
        XCTAssertTrue(savont.singleStrand)

        let pbaaRequest = try PBAAClusteringRunRequest(
            inputFASTQURL: reads, guideSourceURL: reference, outputDirectory: analyses, outputName: "pbaa run",
            threads: 4, seed: 7, extraArgumentsText: "--min-cluster-read-count 3"
        )
        let pbaaItem = try recordedLaunchRow(.pbaa(request: pbaaRequest))
        let pbaa = try RecordedCLICommand.parse(pbaaItem.cliCommand, as: FastqPBAAClusterSubcommand.self)
        XCTAssertEqual(pbaa.input, reads.path)
        XCTAssertEqual(pbaa.guide, reference.path)
        XCTAssertEqual(pbaa.outputDir, analyses.path, "the row shows the request's output folder in place of <derived>")
        XCTAssertEqual(pbaa.outputName, "pbaa-run")
        try assertRecordsThreads(pbaaItem.cliCommand, 4)
        XCTAssertEqual(pbaa.seed, 7)
        XCTAssertEqual(pbaa.extraArgs, "--min-cluster-read-count 3")

        let project = URL(fileURLWithPath: "/tmp/lane 1a2h/Project.lungfish")
        let genotypingRequest = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [reads], referenceSourceURL: reference, barcodeDefinitionsURL: sheet,
            outputDirectory: analyses, outputName: "genotype", analysisName: "MHC", projectURL: project,
            threads: 4, minSupport: 2, extraArguments: [], mode: .ontBarcodeDemux, readType: .ont
        )
        let genotype = try recordedLaunchCommand(
            .ontGenotyping(request: genotypingRequest),
            as: FastqGenotypingSubcommand.self
        )
        XCTAssertEqual(genotype.inputs, [reads.path])
        XCTAssertEqual(genotype.mode, "ont-barcode-demux")
        XCTAssertEqual(genotype.readType, "ont")
        XCTAssertEqual(genotype.reference, reference.path)
        XCTAssertEqual(genotype.barcodes, sheet.path)
        XCTAssertEqual(genotype.outputDir, analyses.path)
        XCTAssertEqual(genotype.outputName, "genotype")
        XCTAssertEqual(genotype.analysisName, "MHC")
        XCTAssertEqual(genotype.project, project.path)
        XCTAssertEqual(genotype.sortThreads, 4)
        XCTAssertEqual(genotype.minSupport, 2)

        let assemblyRequest = AssemblyRunRequest(
            tool: .spades, readType: .illuminaShortReads,
            inputURLs: [inputBundle.appendingPathComponent("R1.fastq"), inputBundle.appendingPathComponent("R2.fastq")],
            projectName: "asm", outputDirectory: analyses, pairedEnd: true, threads: 4, memoryGB: 8, minContigLength: 500
        )
        let assemble = try recordedLaunchCommand(
            .assemble(request: assemblyRequest, outputMode: .perInput),
            as: AssembleCommand.self
        )
        XCTAssertEqual(assemble.fastqFiles, assemblyRequest.inputURLs.map(\.path))
        XCTAssertTrue(assemble.pairedEnd)
        XCTAssertEqual(assemble.assembler, "spades")
        XCTAssertEqual(assemble.readType, "illumina-short-reads")
        XCTAssertEqual(assemble.projectName, "asm")
        XCTAssertEqual(assemble.outputDir, "<derived>")
        XCTAssertEqual(assemble.memoryGB, 8)
        XCTAssertEqual(assemble.minContigLength, 500)
        XCTAssertTrue(assemble.jsonEvents)
    }

    func testRefusedFASTQLaunchRequestBeginLaunchesNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: Length Filter",
            request: .derivative(request: .lengthFilter(min: 100, max: nil), inputURLs: [inputBundle], outputMode: .perInput),
            executionService: FASTQOperationExecutionService(),
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
