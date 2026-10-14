// InspectorTrimDuplicateWorkflowsOperationTests.swift - begin() sites in InspectorViewController+TrimDuplicateWorkflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each site registers its row through a static begin helper (R4). For every
// site there is a test that a held bundle lock refuses the row and launches
// nothing, and a test that the recorded row carries the operation type, the
// lock and a command the real CLI parser accepts with the run's values.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class InspectorTrimDuplicateWorkflowsOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a1/Sample.lungfishref", isDirectory: true)

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        return center
    }

    // MARK: - Primer trim

    private func primerTrimArguments() -> [String] {
        CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/lane 1a1/QIAseq Direct.lungfishprimers"),
            outputTrackName: "Sample 1 primer-trimmed",
            ivarMinQuality: 25,
            ivarMinLength: 40,
            ivarSlidingWindow: 4,
            ivarPrimerOffset: 2
        )
    }

    func testPrimerTrimRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginPrimerTrimOperation(
            title: "Primer-trimming with QIAseq Direct",
            bundleURL: bundleURL,
            cliArguments: primerTrimArguments(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the primer-trim row")
        }
        XCTAssertFalse(launched, "a refused row must launch no runner")
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
    }

    func testPrimerTrimRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        InspectorViewController.beginPrimerTrimOperation(
            title: "Primer-trimming with QIAseq Direct",
            bundleURL: bundleURL,
            cliArguments: primerTrimArguments(),
            routeContext: nil,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.operationType, .bamPrimerTrim)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BAMCommand.PrimerTrimSubcommand.self)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.schemePath, "/tmp/lane 1a1/QIAseq Direct.lungfishprimers")
        XCTAssertEqual(command.outputTrackName, "Sample 1 primer-trimmed")
        XCTAssertEqual(command.ivarMinQuality, 25)
        XCTAssertEqual(command.ivarMinLength, 40)
        XCTAssertEqual(command.ivarPrimerOffset, 2)
    }

    // MARK: - Filtered alignment

    private func filterRequest() -> AlignmentFilterInspectorLaunchRequest {
        AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: "aln-1",
            outputTrackName: "Exact Matches",
            filterRequest: AlignmentFilterRequest(
                mappedOnly: true,
                primaryOnly: true,
                minimumMAPQ: 30,
                duplicateMode: .remove,
                identityFilter: .minimumPercentIdentity(99.5)
            )
        )
    }

    func testFilteredAlignmentRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            request: filterRequest(),
            route: .cli,
            reporter: center
        ) { _ in launched = true }

        guard case .refused = result else {
            return XCTFail("a held bundle lock must refuse the filtered-alignment row")
        }
        XCTAssertFalse(launched, "a refused row must start no filter service")
    }

    func testFilteredAlignmentRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        InspectorViewController.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            request: filterRequest(),
            route: .cli,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Create Filtered Alignment Track")
        XCTAssertEqual(item.operationType, .bamImport)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BAMCommand.FilterSubcommand.self)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertNil(command.mappingResultPath)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.outputTrackName, "Exact Matches")
        XCTAssertNil(command.outputTrackID, "the run generates the track ID, so the command passes none")
        XCTAssertTrue(command.mappedOnly)
        XCTAssertTrue(command.primaryOnly)
        XCTAssertEqual(command.minimumMAPQ, 30)
        XCTAssertTrue(command.removeDuplicates)
        XCTAssertFalse(command.excludeMarkedDuplicates)
        XCTAssertFalse(command.exactMatch)
        XCTAssertEqual(command.minimumPercentIdentity, 99.5)
    }

    func testFilteredAlignmentFromAMappingViewerRecordsTheMappingResultTarget() throws {
        let reporter = RecordingOperationReporter()
        let mappingResultURL = URL(fileURLWithPath: "/tmp/lane 1a1/Analyses/minimap2-run", isDirectory: true)
        let request = AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: "aln-1",
            outputTrackName: "Exact Matches",
            filterRequest: AlignmentFilterRequest(duplicateMode: .exclude, identityFilter: .exactMatch)
        )

        InspectorViewController.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: .mappingResult(mappingResultURL),
            request: request,
            route: .cli,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.targetBundleURL, bundleURL, "the lock stays on the displayed bundle")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BAMCommand.FilterSubcommand.self)
        XCTAssertNil(command.bundlePath)
        XCTAssertEqual(command.mappingResultPath, mappingResultURL.path)
        XCTAssertTrue(command.excludeMarkedDuplicates)
        XCTAssertTrue(command.exactMatch)
        XCTAssertNil(command.minimumMAPQ)
    }

    // MARK: - Mapped reads to annotations

    private func annotationRequest() -> MappedReadsAnnotationRequest {
        MappedReadsAnnotationInspectorLaunchRequest(
            sourceTrackID: "aln-1",
            outputTrackName: "Mapped Reads",
            outputTrackID: "mapped_reads_1",
            primaryOnly: true,
            includeSequence: true,
            includeQualities: false,
            replaceExisting: true
        ).workflowRequest(bundleURL: bundleURL)
    }

    func testMappedReadsAnnotationRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginMappedReadsAnnotationWorkflowOperation(
            request: annotationRequest(),
            route: .cli,
            reporter: center
        ) { _ in launched = true }

        guard case .refused = result else {
            return XCTFail("a held bundle lock must refuse the annotation row")
        }
        XCTAssertFalse(launched, "a refused row must start no annotation service")
    }

    func testMappedReadsAnnotationRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        InspectorViewController.beginMappedReadsAnnotationWorkflowOperation(
            request: annotationRequest(),
            route: .cli,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Convert Mapped Reads to Annotations")
        XCTAssertEqual(item.operationType, .bamImport)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BAMCommand.AnnotateSubcommand.self)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.outputTrackName, "Mapped Reads")
        XCTAssertEqual(command.outputTrackID, "mapped_reads_1")
        XCTAssertTrue(command.primaryOnly)
        XCTAssertTrue(command.includeSequence)
        XCTAssertFalse(command.includeQualities)
        XCTAssertTrue(command.replaceExisting)
    }

    // MARK: - One builder for the bam filter and bam annotate commands (R3)

    /// The exact strings these rows record. The in-process route keeps the strings the rows recorded while
    /// the App had argv builders of its own, so building them with the Workflow builders the provenance
    /// uses changed no recorded command. The CLI route records the argv the L3 runner runs, which is the
    /// same words and `--format json` so that the leaf speaks events (Phase 2.10 lane A54). That command
    /// parses with the request's options, and it equals the argv the launch runs.
    func testFilterAndAnnotateRowsRecordTheArgvTheyRun() throws {
        let mappingResultURL = URL(fileURLWithPath: "/tmp/lane 1a1/Analyses/minimap2-run", isDirectory: true)
        let mappingRequest = AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: "aln-1",
            outputTrackName: "Exact Matches",
            filterRequest: AlignmentFilterRequest(duplicateMode: .exclude, identityFilter: .exactMatch)
        )
        let bareAnnotation = MappedReadsAnnotationRequest(
            bundleURL: bundleURL, sourceTrackID: "aln-1", outputTrackName: "Mapped Reads"
        )
        for route in InspectorDuplicateWorkflowRoute.allCases {
            let tail = route == .cli ? " --format json" : ""
            XCTAssertEqual(
                InspectorViewController.filteredAlignmentCLICommand(
                    serviceTarget: .bundle(bundleURL), request: filterRequest(), route: route
                ),
                "lungfish-cli bam filter --bundle '/tmp/lane 1a1/Sample.lungfishref' --alignment-track aln-1"
                    + " --output-track-name 'Exact Matches' --mapped-only --primary-only --min-mapq 30"
                    + " --remove-duplicates --min-percent-identity 99.5" + tail,
                "\(route)"
            )
            XCTAssertEqual(
                InspectorViewController.filteredAlignmentCLICommand(
                    serviceTarget: .mappingResult(mappingResultURL), request: mappingRequest, route: route
                ),
                "lungfish-cli bam filter --mapping-result '/tmp/lane 1a1/Analyses/minimap2-run' --alignment-track aln-1"
                    + " --output-track-name 'Exact Matches' --exclude-marked-duplicates --exact-match" + tail,
                "\(route)"
            )
            XCTAssertEqual(
                InspectorViewController.mappedReadsAnnotationCLICommand(request: annotationRequest(), route: route),
                "lungfish-cli bam annotate --bundle '/tmp/lane 1a1/Sample.lungfishref' --alignment-track aln-1"
                    + " --output-track-name 'Mapped Reads' --output-track-id mapped_reads_1 --primary-only"
                    + " --include-sequence --replace" + tail,
                "\(route)"
            )
            XCTAssertEqual(
                InspectorViewController.mappedReadsAnnotationCLICommand(request: bareAnnotation, route: route),
                "lungfish-cli bam annotate --bundle '/tmp/lane 1a1/Sample.lungfishref' --alignment-track aln-1"
                    + " --output-track-name 'Mapped Reads'" + tail,
                "\(route)"
            )
        }

        // On the CLI route the recorded command is the launched argv.
        let target = AlignmentFilterTarget.bundle(bundleURL)
        let filterCommand = InspectorViewController.filteredAlignmentCLICommand(
            serviceTarget: target, request: filterRequest(), route: .cli
        )
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: filterCommand),
            InspectorViewController.filteredAlignmentCLIArguments(serviceTarget: target, request: filterRequest())
        )
        XCTAssertEqual(Array(try RecordedCLICommand.arguments(of: filterCommand).suffix(2)), ["--format", "json"])
        let annotateCommand = InspectorViewController.mappedReadsAnnotationCLICommand(request: annotationRequest(), route: .cli)
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: annotateCommand),
            InspectorViewController.mappedReadsAnnotationCLIArguments(request: annotationRequest())
        )
        XCTAssertEqual(Array(try RecordedCLICommand.arguments(of: annotateCommand).suffix(2)), ["--format", "json"])
    }

    /// The leaf names the derived BAM first and the track's ID is that file's name, so the app reads the ID
    /// from the output path. It reads the annotation track's name as the service makes it. Neither is read
    /// from the `complete` message, which is text.
    func testTheCLIRouteReadsTheFilterTrackIDAndTheAnnotationNameFromWhatTheLeafNamed() throws {
        let completion = CLIAlignmentActionRunner.Completion(
            outputs: [
                "/tmp/lane 1a1/Sample.lungfishref/alignments/filtered/aln_1a2b3c4d.bam",
                "/tmp/lane 1a1/Sample.lungfishref/alignments/filtered/aln_1a2b3c4d.bam.bai",
                "/tmp/lane 1a1/Sample.lungfishref/alignments/filtered/aln_1a2b3c4d.stats.db",
            ],
            message: "Created filtered alignment track \"Exact Matches\"."
        )
        XCTAssertEqual(try InspectorViewController.filteredAlignmentTrackID(from: completion), "aln_1a2b3c4d")
        XCTAssertThrowsError(try InspectorViewController.filteredAlignmentTrackID(
            from: CLIAlignmentActionRunner.Completion(outputs: [], message: nil)
        ))

        let named = MappedReadsAnnotationRequest(bundleURL: bundleURL, sourceTrackID: "aln-1", outputTrackName: "  Mapped Reads 2 \n")
        let empty = MappedReadsAnnotationRequest(bundleURL: bundleURL, sourceTrackID: "aln-1", outputTrackName: "   ")
        XCTAssertEqual(InspectorViewController.annotationTrackName(for: named), "Mapped Reads 2")
        XCTAssertEqual(InspectorViewController.annotationTrackName(for: empty), "Mapped Reads")
    }

    func testFilterAndAnnotateRowsRecordTheArgvTheWorkflowBuildersBuildForTheProvenance() throws {
        let target = AlignmentFilterTarget.bundle(bundleURL)
        let request = filterRequest()
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: InspectorViewController.filteredAlignmentCLICommand(
                serviceTarget: target, request: request, route: .legacy
            )),
            Array(BundleAlignmentFilterService.cliArgv(
                target: target,
                sourceTrackID: request.sourceTrackID,
                outputTrackID: nil,
                outputTrackName: request.outputTrackName,
                filterRequest: request.filterRequest
            ).dropFirst())
        )
        let annotation = annotationRequest()
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: InspectorViewController.mappedReadsAnnotationCLICommand(
                request: annotation, route: .legacy
            )),
            Array(MappedReadsAnnotationService.cliArgv(
                request: annotation,
                bundleURL: annotation.bundleURL,
                outputTrackName: annotation.outputTrackName
            ).dropFirst())
        )
        // The argv the CLI route runs is the same builders' argv and `--format json`.
        XCTAssertEqual(
            InspectorViewController.filteredAlignmentCLIArguments(serviceTarget: target, request: request),
            Array(BundleAlignmentFilterService.cliArgv(
                target: target,
                sourceTrackID: request.sourceTrackID,
                outputTrackID: nil,
                outputTrackName: request.outputTrackName,
                filterRequest: request.filterRequest
            ).dropFirst()) + ["--format", "json"]
        )
        XCTAssertEqual(
            InspectorViewController.mappedReadsAnnotationCLIArguments(request: annotation),
            Array(MappedReadsAnnotationService.cliArgv(
                request: annotation,
                bundleURL: annotation.bundleURL,
                outputTrackName: annotation.outputTrackName
            ).dropFirst()) + ["--format", "json"]
        )
    }
}
