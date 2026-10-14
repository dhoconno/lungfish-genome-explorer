// MainSplitGenomicsDisplayOperationTests.swift - begin() sites in MainSplitViewController+GenomicsDisplay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The genomics display launches register two kinds of Operations panel rows
// through static begin helpers (R4). The reference download locks the
// variant-only bundle it merges into, so a fresh center in which another
// operation holds that bundle refuses it. The FASTQ dialog row declares no
// lock, and a recording reporter that holds a lock stands in for its
// refusal. The reference download begins with the `fetch genome --into-bundle`
// command with `<derived>` for the accession, and refines it once the app has
// found the accession, and its tests parse both commands. The FASTQ operations
// dialog row records the `lungfish-cli fastq` command
// FASTQOperationCLIInvocationBuilder builds for the request (R3), which the
// tests parse with the real CLI parser and compare with the request's values.
// A request with a setting no lungfish-cli option expresses records no
// command, a pinned CLI parity gap.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
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
    /// A bundle a VCF import with no reference made, which the reference download merges into.
    private let variantOnlyBundle = URL(
        fileURLWithPath: "/tmp/lane 1a2h/Project.lungfish/Cohort calls.lungfishref",
        isDirectory: true
    )

    // MARK: - Reference download (site 40)

    /// The manager's ruling on note 4 of lane A44 M3. The app finds the accession during the run,
    /// an assembly's or else the VCF's GenBank record's, so the row begins with the `fetch genome`
    /// command with `<derived>` in its place, the placeholder the FASTQ rows of
    /// docs/contracts/CLI-EQUIVALENCE.md record for a value resolved after `begin`, and
    /// `setCommand` refines it (testNakedBundleReferenceCommandIsTheChildsArgvAndParses). The
    /// placeholder command parses.
    func testNakedBundleReferenceDownloadBeginsWithThePlaceholderFetchCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "Wuhan-Hu-1",
            bundleURL: variantOnlyBundle,
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
        XCTAssertEqual(item.targetBundleURL, variantOnlyBundle, "the row locks the bundle it merges into (ruling M3-3)")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: item.cliCommand),
            ["fetch", "genome", "<derived>", "--into-bundle", variantOnlyBundle.path, "--format", "json"])
        let parsed = try RecordedCLICommand.parse(item.cliCommand, as: GenomeSubcommand.self)
        XCTAssertEqual(parsed.accessions, ["<derived>"])
        XCTAssertEqual(parsed.intoBundle, variantOnlyBundle.path)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
    }

    /// Ruling M3-1 of the A44 M2d review. Once the app has found the assembly, the run records
    /// with `setCommand` the command whose words after `lungfish-cli` are the argv of the child it
    /// launches, from one builder. The command parses as `fetch genome` with the accession, the
    /// bundle and JSON events, and holds no NCBI key, which reaches the child through its
    /// environment (SWIFT 6).
    func testNakedBundleReferenceCommandIsTheChildsArgvAndParses() throws {
        let reporter = RecordingOperationReporter()
        let id = try XCTUnwrap(MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "StandInAsm1",
            bundleURL: variantOnlyBundle,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in }.startedID)
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: reporter.item(id)?.cliCommand).prefix(3), ["fetch", "genome", "<derived>"],
            "the row begins with the placeholder")

        reporter.setCommand(
            id: id,
            command: MainSplitViewController.nakedBundleReferenceCommand(
                accession: "GCF_000000001.1", bundleURL: variantOnlyBundle))

        let command = reporter.item(id)?.cliCommand
        let argv = MainSplitViewController.nakedBundleReferenceFetchArguments(
            accession: "GCF_000000001.1", bundleURL: variantOnlyBundle)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: command), argv, "the row's command is the child's argv")
        XCTAssertEqual(
            argv, ["fetch", "genome", "GCF_000000001.1", "--into-bundle", variantOnlyBundle.path, "--format", "json"])
        let parsed = try RecordedCLICommand.parse(command, as: GenomeSubcommand.self)
        XCTAssertEqual(parsed.accessions, ["GCF_000000001.1"])
        XCTAssertEqual(parsed.intoBundle, variantOnlyBundle.path)
        XCTAssertNil(parsed.apiKey, "the key reaches the child through its environment, never its argv")
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
    }

    /// The hidden key that keeps the in-process reference download for one release (panel C4).
    func testTheHiddenKeyPicksTheReferenceRoute() {
        let suite = makeTestDefaultsSuite(prefix: "naked-reference-route")
        let settings = NakedBundleReferenceRouteSettings(defaults: suite.defaults)
        XCTAssertEqual(settings.route, NakedBundleReferenceRouteSettings.defaultRoute, "an unset key")
        let cases: [(Any, NakedBundleReferenceRoute)] = [
            ("cli", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy),
            ("NO", NakedBundleReferenceRouteSettings.defaultRoute),
        ]
        for (value, route) in cases {
            suite.defaults.set(value, forKey: NakedBundleReferenceRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
    }

    func testRefusedReferenceDownloadsLaunchNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let naked = MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "Wuhan-Hu-1",
            bundleURL: variantOnlyBundle,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(naked.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    /// Ruling M3-3 of the A44 M2d review. The run replaces the variant-only bundle's genome,
    /// annotations and manifest, so the row declares the bundle as its lock target, and while
    /// another operation holds that bundle a real center refuses the row, which launches nothing.
    func testAHeldLockOnTheVariantOnlyBundleRefusesTheReferenceDownload() throws {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: variantOnlyBundle,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        var launched = false

        let result = MainSplitViewController.beginNakedBundleReferenceDownloadOperation(
            assemblyName: "StandInAsm1",
            bundleURL: variantOnlyBundle,
            routeContext: routeContext,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held lock on the variant-only bundle must refuse the reference download")
        }
        XCTAssertFalse(launched, "a refused row must launch no download")
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
    }

    // MARK: - Requests no lungfish-cli option expresses

    /// Requests that carry a setting no lungfish-cli option expresses. The
    /// invocation builder refuses them, so the dialog row records no
    /// command, and the dialog run fails with the builder's error.
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
        // error because the execution service builds the same invocation. When
        // the builder encodes one, the row records the command and its pin
        // becomes a parse test.
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
