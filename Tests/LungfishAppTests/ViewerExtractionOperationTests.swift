// ViewerExtractionOperationTests.swift - begin() site in ViewerViewController+Extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Building a bundle from an extracted sequence registers its row through a
// static begin helper on SequenceViewerView (R4). Since 2.11 A48 M2 a viewer
// with a reference bundle launches `lungfish-cli extract sequence --bundle`
// with the argv the site hands the helper, and the row records that argv, so
// a parse test replaces the gap pin of `region-bundle-extraction`.
// RegionBundleExtractionParityReplayTests replays the command. A viewer with
// no reference bundle still builds in process and records no command, the
// narrower gap `region-extraction-without-bundle`. A reporter that refuses
// every begin proves the launch closure sits behind the `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ViewerExtractionOperationTests: XCTestCase {
    private let sourceBundle = URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Ref.lungfishref", isDirectory: true)
    private let outputBundle = URL(
        fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Extractions/-Region 1.lungfishref", isDirectory: true
    )

    private func featureArguments() -> [String] {
        let annotation = SequenceAnnotation(
            type: .cds, name: "-cds, A", chromosome: "NC_045512.2",
            intervals: [AnnotationInterval(start: 99, end: 150), AnnotationInterval(start: 160, end: 200)], strand: .reverse
        )
        return SequenceExtractionPipeline.cliArguments(
            source: .annotation(annotation),
            flank5Prime: 5,
            flank3Prime: 0,
            reverseComplement: true,
            concatenateExons: true,
            sourceBundleURL: sourceBundle,
            bundleName: "-Region 1",
            sampleFilter: ["S.1 a", "b,2"],
            outputBundleURL: outputBundle
        )
    }

    func testExtractionBundleRecordsTheCommandItsLaunchRuns() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish", isDirectory: true),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?
        let arguments = featureArguments()

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "-cds, A",
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extracting -cds, A")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "extract sequence", args: Array(arguments.dropFirst(2))),
            "the row records the argv the launch runs"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.input, sourceBundle.path)
        XCTAssertEqual(command.region, "NC_045512.2:100-150,161-200", "the feature's parts, 1-based and inclusive")
        XCTAssertTrue(command.bundle)
        XCTAssertEqual(command.featureName, "-cds, A", "a hyphen-leading name stays a value")
        XCTAssertEqual(command.featureType, "CDS")
        XCTAssertEqual(command.strand, "-")
        XCTAssertTrue(command.reverseComplement)
        XCTAssertTrue(command.concatenateExons)
        XCTAssertEqual(command.flank5, 5)
        XCTAssertNil(command.flank3)
        XCTAssertEqual(command.name, "-Region 1")
        XCTAssertEqual(command.samples, ["S.1 a", "b,2"], "each sample is one word, so a name may hold a comma")
        XCTAssertFalse(command.noSamples)
        XCTAssertEqual(command.output, outputBundle.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the command's events")
    }

    func testARunThatHidesEverySampleRecordsNoSamples() throws {
        let reporter = RecordingOperationReporter()
        let arguments = SequenceExtractionPipeline.cliArguments(
            source: .region(chromosome: "chr1", start: 9, end: 40),
            flank5Prime: 0, flank3Prime: 0, reverseComplement: false, concatenateExons: false,
            sourceBundleURL: sourceBundle, bundleName: nil, sampleFilter: [], outputBundleURL: outputBundle
        )

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "chr1:10-40", arguments: arguments, routeContext: nil, reporter: reporter
        ) { _ in }

        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.region, "chr1:10-40")
        XCTAssertNil(command.featureName)
        XCTAssertNil(command.name)
        XCTAssertTrue(command.noSamples)
        XCTAssertEqual(command.samples, [])
    }

    func testAViewerWithNoReferenceBundleRecordsNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "NC_045512.2:100-200",
            arguments: nil,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Extracting NC_045512.2:100-200")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        // CLI parity gap. The viewer reads its sequence from the document it
        // shows, which `extract sequence --bundle` cannot read.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "region-extraction-without-bundle")
    }

    func testExtractionBundleLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "NC_045512.2:100-200",
            arguments: featureArguments(),
            routeContext: nil,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
