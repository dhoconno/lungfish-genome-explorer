// ViewerMappingOperationTests.swift - begin() sites in ViewerViewController+Mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Two launches in the mapping viewport register their rows through static
// begin helpers (R4). Neither locks a bundle. Extracting the reads that
// overlap an annotation records the `lungfish-cli extract reads --by-region`
// command for the configuration the run executes, and it must parse with the
// values the run uses. Generating an alignment consensus has no lungfish-cli
// command, so its test pins today's description as a parity gap. A command
// added later fails the pin and prompts a parse test in its place. A reporter
// that refuses every begin proves each launch closure sits behind the
// `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
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
        )
    }

    // MARK: - Alignment consensus, a CLI parity gap

    func testAlignmentConsensusRecordsTodaysDescriptionAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9)
        var launchedID: UUID?

        ViewerViewController.beginAlignmentConsensusGenerationOperation(
            region: region,
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
        // CLI parity gap. No lungfish-cli command calls a consensus from a BAM
        // or CRAM alignment. The closest is `msa consensus`, which reads a
        // `.lungfishmsa` bundle. When a command that reads an alignment
        // exists, record it and replace this pin with a parse test.
        XCTAssertEqual(
            item.cliCommand,
            "Lungfish.app alignment consensus --scope selectedRegion --region chrSynthetic:4-9 --reference-fill never"
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand)) { error in
            guard case RecordedCLICommand.ParseError.notALungfishCLICommand = error else {
                return XCTFail("The pin must fail because the text is not a lungfish-cli command, got \(error)")
            }
        }
    }

    func testAlignmentConsensusDescribesTheWholeContigScope() throws {
        let reporter = RecordingOperationReporter()
        let region = ResolvedAlignmentRegion(scope: .wholeContig, contig: "chrSynthetic", start: 0, end: 100)

        ViewerViewController.beginAlignmentConsensusGenerationOperation(
            region: region,
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "Lungfish.app alignment consensus --scope wholeContig --region chrSynthetic:0-100 --reference-fill never"
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
            region: ResolvedAlignmentRegion(scope: .wholeContig, contig: "chrSynthetic", start: 0, end: 100),
            reporter: reporter
        ) { _ in launched.append("alignment consensus") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 2)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
