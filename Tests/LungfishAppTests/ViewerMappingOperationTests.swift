// ViewerMappingOperationTests.swift - begin() sites in ViewerViewController+Mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Two launches in the mapping viewport register their rows through static
// begin helpers (R4). Neither locks a bundle. Extracting the reads that
// overlap an annotation records the `lungfish-cli extract reads --by-region`
// command for the configuration the run executes, and it must parse with the
// values the run uses. Generating an alignment consensus records the
// `lungfish-cli bam consensus` command its runner runs (Phase 2.10 lane A51),
// which must parse with the request's filters and the chosen `--output`. A
// reporter that refuses every begin proves each launch closure sits behind the
// `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ViewerMappingOperationTests: XCTestCase {
    private let resultDirectory = URL(fileURLWithPath: "/tmp/lane 1a2f/Mapping Run", isDirectory: true)

    // MARK: - Overlapping reads for an annotation

    /// The configuration the viewer builds for a two-block annotation, through
    /// the same builder the call site uses.
    private func makeOverlappingReadsConfig() throws -> BAMRegionExtractionConfig {
        let result = MappingResult(
            mapper: .minimap2,
            modeID: "short-read-default",
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 80,
            unmappedReads: 20,
            wallClockSeconds: 1.0,
            contigs: []
        )
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test gene/1",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 10, end: 25), AnnotationInterval(start: 40, end: 60)]
        )
        return try XCTUnwrap(MappingAnnotationActionCoordinator.extractionConfiguration(
            for: annotation,
            mappingResult: result,
            outputDirectory: resultDirectory.appendingPathComponent("annotation-extractions", isDirectory: true)
        ))
    }

    func testOverlappingReadsExtractionRecordsItsRowAndAParsableCommand() throws {
        let reporter = RecordingOperationReporter()
        let config = try makeOverlappingReadsConfig()
        var launchedID: UUID?

        ViewerViewController.beginOverlappingReadsExtractionOperation(
            annotationName: "test gene/1",
            config: config,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extract Overlapping Reads")
        XCTAssertEqual(item.initialDetail, "Extracting reads overlapping test gene/1…")
        XCTAssertEqual(item.operationType, .taxonomyExtraction)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.byRegion)
        XCTAssertFalse(command.byId || command.byDb || command.byClassifier)
        XCTAssertEqual(command.bamFile, config.bamURL.path)
        XCTAssertEqual(command.regions, ["chr1:11-25", "chr1:41-60"])
        // The run writes `<outputBaseName>.fastq` in the output directory.
        XCTAssertEqual(
            command.output,
            resultDirectory.appendingPathComponent("annotation-extractions/test-gene-1.fastq").path
        )
        XCTAssertFalse(command.excludeUnmapped, "the run keeps the command's default flag filter")
        XCTAssertFalse(command.createBundle)
        XCTAssertNil(command.bundleName)
    }

    func testOverlappingReadsConfigurationSetsNothingTheCommandCannotExpress() throws {
        // `extract reads --by-region` expresses the BAM, the regions and the
        // output file, and keeps its own default duplicate exclusion. A
        // configuration that sets anything else needs a command option first.
        let config = try makeOverlappingReadsConfig()

        XCTAssertNil(config.minMapQ)
        XCTAssertNil(config.excludedFlags)
        XCTAssertEqual(config.readGroups, [])
        XCTAssertNil(config.decodingReferenceURL)
        XCTAssertFalse(config.fallbackToAll)
        XCTAssertTrue(config.deduplicateReads)
    }

    func testOverlappingReadsCommandQuotesEveryPathTheRunUses() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginOverlappingReadsExtractionOperation(
            annotationName: "test gene/1",
            config: try makeOverlappingReadsConfig(),
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "lungfish-cli extract reads --by-region --bam '/tmp/lane 1a2f/Mapping Run/sample.sorted.bam'"
                + " --region chr1:11-25 --region chr1:41-60"
                + " -o '/tmp/lane 1a2f/Mapping Run/annotation-extractions/test-gene-1.fastq'"
                + " --format json",
            "the row records the argv the L3 runner runs, events on (Phase 2.10 lane A51, p48)"
        )
    }

    // MARK: - Alignment consensus, lungfish-cli bam consensus

    /// The run the viewer begins for a FASTA destination, with every filter set.
    private func consensusInvocation(
        scope: AlignmentConsensusScope = .selectedRegion,
        start: Int = 4,
        end: Int = 9,
        output: String = "/tmp/lane 1a2f/Consensus/S1 consensus.fasta"
    ) -> AlignmentConsensusInvocation {
        let filters = AlignmentConsensusFilters(
            minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12, excludedFlags: 0x904, readGroups: ["rg2", "rg1"]
        )
        return AlignmentConsensusInvocation(
            alignmentURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            indexURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            decodingReferenceURL: nil,
            region: ResolvedAlignmentRegion(scope: scope, contig: "chrSynthetic", start: start, end: end),
            consensusRequest: AlignmentConsensusRequest(
                chromosome: "chrSynthetic", start: start, end: end, filters: filters,
                mode: .simple, useAmbiguity: true, insertionPolicy: .omit, deletionPolicy: .n
            ),
            recordName: "S1 chrSynthetic:5-9 selected consensus",
            resultID: "run-1",
            output: output
        )
    }

    func testAlignmentConsensusRecordsTheBamConsensusCommandItRuns() throws {
        let reporter = RecordingOperationReporter()
        let invocation = consensusInvocation()
        var launchedID: UUID?

        ViewerViewController.beginAlignmentConsensusGenerationOperation(
            invocation: invocation,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Generate Alignment Consensus")
        XCTAssertEqual(item.initialDetail, "Calling evidence-only consensus…")
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BAMConsensusSubcommand.self)
        XCTAssertEqual(command.outputPath, "/tmp/lane 1a2f/Consensus/S1 consensus.fasta")
        XCTAssertEqual(command.alignmentPath, resultDirectory.appendingPathComponent("sample.sorted.bam").path)
        XCTAssertEqual(command.indexPath, resultDirectory.appendingPathComponent("sample.sorted.bam.bai").path)
        XCTAssertNil(command.decodingReferencePath)
        XCTAssertEqual(command.scope, "selectedRegion")
        XCTAssertEqual(command.region, "chrSynthetic:5-9", "1-based and inclusive, as samtools takes it")
        XCTAssertEqual(command.minimumDepth, 3)
        XCTAssertEqual(command.minimumMapQ, 20)
        XCTAssertEqual(command.minimumBaseQuality, 12)
        XCTAssertEqual(command.excludedFlags, 0x904)
        XCTAssertEqual(command.readGroups, ["rg1", "rg2"])
        XCTAssertEqual(command.callerMode, "simple")
        XCTAssertTrue(command.useAmbiguity)
        XCTAssertEqual(command.name, "S1 chrSynthetic:5-9 selected consensus")
        XCTAssertEqual(command.resultID, "run-1")
        XCTAssertFalse(command.allowAllLowDepth, "the user's all-N answer is added only after the leaf asks")
        // The runner runs the argv the row records.
        let arguments = ViewerViewController.alignmentConsensusCLIArguments(invocation)
        XCTAssertEqual(Array(arguments.prefix(2)), ["bam", "consensus"])
        XCTAssertEqual(Array(arguments.suffix(2)), ["--format", "json"])
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "bam consensus", args: Array(arguments.dropFirst(2)))
        )
        XCTAssertEqual(
            item.logs.map(\.message),
            ["Consensus scope selectedRegion, region chrSynthetic:4-9, reference fill never"]
        )
    }

    func testAClipboardOrShareConsensusNamesItsOutputRelativeToTheFolderItRunsIn() throws {
        let reporter = RecordingOperationReporter()
        let invocation = consensusInvocation(output: "S1-chrSynthetic-5-9-selectedRegion-consensus.fasta")

        ViewerViewController.beginAlignmentConsensusGenerationOperation(invocation: invocation, reporter: reporter) { _ in }

        let arguments = ViewerViewController.alignmentConsensusCLIArguments(invocation)
        let command = try BAMConsensusSubcommand.parse(Array(arguments.dropFirst(2)))
        XCTAssertEqual(command.outputPath, "S1-chrSynthetic-5-9-selectedRegion-consensus.fasta")
        XCTAssertTrue(reporter.items.first?.cliCommand?.hasSuffix(
            "--output S1-chrSynthetic-5-9-selectedRegion-consensus.fasta --format json"
        ) == true, reporter.items.first?.cliCommand ?? "nil")
    }

    func testAlignmentConsensusDescribesTheWholeContigScope() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginAlignmentConsensusGenerationOperation(
            invocation: consensusInvocation(scope: .wholeContig, start: 0, end: 100),
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.logs.map(\.message),
            ["Consensus scope wholeContig, region chrSynthetic:0-100, reference fill never"]
        )
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() throws {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let config = try makeOverlappingReadsConfig()
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        check("overlapping reads extraction", ViewerViewController.beginOverlappingReadsExtractionOperation(
            annotationName: "test gene/1", config: config, reporter: reporter
        ) { _ in launched.append("overlapping reads extraction") })
        check("alignment consensus", ViewerViewController.beginAlignmentConsensusGenerationOperation(
            invocation: consensusInvocation(scope: .wholeContig, start: 0, end: 100),
            reporter: reporter
        ) { _ in launched.append("alignment consensus") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 2)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
