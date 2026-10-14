// AlignmentScientificActionCoordinatorOperationTests.swift - begin() site in AlignmentScientificActionCoordinator
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extracting the reads of a selected alignment region, or of selected reads,
// registers one Operations panel row through the reporter's `begin` (R4). The
// reporter sends every report to any OperationReporting, so a recording
// reporter shows the row the launch registered and how it finished, without
// touching `OperationCenter.shared`. The rows lock no bundle and record no
// command, because no lungfish-cli command reproduces either run, so the tests
// pin that gap. A command added later fails the pin and prompts a parse test
// in its place. A reporter that refuses every begin proves the launch starts
// nothing behind a refused row.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class AlignmentScientificActionCoordinatorOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish"),
        windowStateScopeID: UUID()
    )
    private let finalURL = URL(fileURLWithPath: "/out/final.lungfishfastq")

    // MARK: - Fixtures

    private func makeContext() throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/evidence/a.bam")
        let index = URL(fileURLWithPath: "/evidence/a.bam.bai")
        return try .init(
            identity: .init(workflow: "map", resultID: "r", sampleID: "s", evidenceID: "e"),
            alignmentURL: bam,
            indexURL: index,
            decodingReferenceURL: nil,
            contig: "chrSynthetic",
            contigLength: 100,
            alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "a"),
            indexSnapshot: .init(url: index, byteCount: 1, sha256: "i"),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 1, minimumMapQ: 30, minimumBaseQuality: 20, excludedFlags: 0x904, readGroups: ["rg"]),
            outputCapability: .projectDerivedRoot(URL(fileURLWithPath: "/output")),
            sourceReads: .bamFallback,
            presentationLabel: "evidence"
        )
    }

    private func makeTransaction() throws -> AlignmentReadExtractionTransaction {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("reads.fastq")
        try "@read\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
        return try .init(
            stagingDirectoryURL: directory,
            stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "reads.fastq", format: .fastq)],
            readCount: 1,
            pairedEnd: false
        )
    }

    private func publicationResult(for transaction: AlignmentReadExtractionTransaction) -> AlignmentReadExtractionPublicationResult {
        .init(
            finalURL: finalURL,
            outputURLs: [finalURL.appendingPathComponent("reads.fastq")],
            provenanceURL: finalURL.appendingPathComponent("provenance.json"),
            readCount: transaction.readCount,
            pairedEnd: transaction.pairedEnd,
            executionRecords: transaction.executionRecords
        )
    }

    private func makeRead() -> AlignedRead {
        AlignedRead(
            name: "qname", flag: 0, chromosome: "chrSynthetic", position: 4, mapq: 60,
            cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30]
        )
    }

    private let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9)

    // MARK: - Rows

    func testRegionExtractionRegistersItsRowAndCompletesIt() async throws {
        let recorder = RecordingOperationReporter()
        let transaction = try makeTransaction()
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { _ in transaction },
            publisher: { request in self.publicationResult(for: request.transaction) }
        )
        let reporter = AlignmentScientificActionReporter.operationCenter(routeContext: routeContext, center: recorder)

        let task = try XCTUnwrap(coordinator.launchRegion(
            context: try makeContext(),
            region: region,
            destination: .bundle(finalURL),
            outputBaseName: "selected-region",
            reporter: reporter
        ))

        // The launch registers its row before any work finishes.
        let item = try XCTUnwrap(recorder.items.first)
        XCTAssertEqual(recorder.items.count, 1)
        XCTAssertEqual(item.title, "Extract Reads in Selected Region")
        XCTAssertEqual(item.initialDetail, "Preparing alignment read extraction…")
        XCTAssertEqual(item.operationType, .taxonomyExtraction)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback)

        _ = await task.result

        let finished = try XCTUnwrap(recorder.item(item.id))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.detail, "Alignment read extraction published")
        XCTAssertEqual(finished.bundleURLs, [finalURL])
        XCTAssertTrue(finished.logs.contains { $0.message.contains("workflow=map;resultID=r;sampleID=s;evidenceID=e") })
    }

    func testSelectedReadsExtractionRegistersItsRowAndCompletesIt() async throws {
        let recorder = RecordingOperationReporter()
        let transaction = try makeTransaction()
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            bamStager: { _, _, _ in transaction },
            publisher: { request in self.publicationResult(for: request.transaction) }
        )
        let reporter = AlignmentScientificActionReporter.operationCenter(routeContext: routeContext, center: recorder)

        let task = try XCTUnwrap(coordinator.launchSelectedReads(
            context: try makeContext(),
            records: [makeRead()],
            destination: .bundle(finalURL),
            outputBaseName: "evidence_selected_1reads",
            reporter: reporter
        ))

        let item = try XCTUnwrap(recorder.items.first)
        XCTAssertEqual(recorder.items.count, 1)
        XCTAssertEqual(item.title, "Extract Selected Reads")
        XCTAssertEqual(item.initialDetail, "Preparing selected-read extraction…")
        XCTAssertEqual(item.operationType, .taxonomyExtraction)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback)

        _ = await task.result

        let finished = try XCTUnwrap(recorder.item(item.id))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.bundleURLs, [finalURL])
    }

    // MARK: - The recorded command (Phase 2.10 A51, gaps alignment-region-reads and alignment-selected-reads closed)

    /// Each row records the `extract reads` command the L3 runner runs, with the evidence's index and
    /// filters for a region and the durable names file for selected reads.
    func testExtractionRowsRecordTheExtractReadsCommandTheRunnerRuns() throws {
        let context = try makeContext()
        let names = URL(fileURLWithPath: "/out/final.read-names.txt")
        let invocations = [
            ViewerViewController.alignmentRegionExtractionInvocation(
                context: context, region: region, destination: .bundle(finalURL), outputBaseName: "selected-region"
            ),
            ViewerViewController.selectedReadsExtractionInvocation(
                context: context, records: [makeRead()], namesFile: names, destination: .bundle(finalURL),
                outputBaseName: "evidence_selected_1reads"
            ),
        ]
        for invocation in invocations {
            let recorder = RecordingOperationReporter()
            var launched: UUID?
            ViewerViewController.beginAlignmentReadExtractionOperation(
                title: "Extract", detail: "Preparing…", invocation: invocation, evidence: context.identity,
                routeContext: routeContext, reporter: recorder
            ) { launched = $0 }
            let item = try XCTUnwrap(recorder.items.first)
            XCTAssertEqual(launched, item.id)
            XCTAssertEqual(item.operationType, .taxonomyExtraction)
            XCTAssertNil(item.targetBundleURL)
            XCTAssertEqual(item.routeContext, routeContext)
            XCTAssertTrue(item.logs.contains { $0.message.contains("workflow=map;resultID=r;sampleID=s;evidenceID=e") })
            XCTAssertEqual(
                try RecordedCLICommand.arguments(of: item.cliCommand),
                ViewerViewController.alignmentReadExtractionCLIArguments(invocation),
                "the row records the argv the runner runs"
            )
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
            XCTAssertEqual(command.bamFile, "/evidence/a.bam")
            XCTAssertEqual(command.indexFile, "/evidence/a.bam.bai")
            XCTAssertEqual(command.output, finalURL.path)
        }
        let region = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "extract reads", args: Array(ViewerViewController.alignmentReadExtractionCLIArguments(invocations[0]).dropFirst(2))),
            as: ExtractReadsSubcommand.self
        )
        XCTAssertEqual(region.regions, ["chrSynthetic:5-9"])
        XCTAssertEqual(region.minimumMapQ, 30)
        XCTAssertEqual(region.excludedFlags, 0x904)
        XCTAssertEqual(region.readGroups, ["rg"])
        let selected = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "extract reads", args: Array(ViewerViewController.alignmentReadExtractionCLIArguments(invocations[1]).dropFirst(2))),
            as: ExtractReadsSubcommand.self
        )
        XCTAssertEqual(selected.idsFile, names.path)
        XCTAssertEqual(selected.recordsWithoutSequence, 0)
    }

    // MARK: - Refused begin

    func testRefusedBeginLaunchesNothing() throws {
        // The rows request no lock, so no real center refuses them. A reporter
        // that refuses every begin proves each launch starts nothing behind a
        // refused row.
        let recorder = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var stagedOrPublished = false
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { _ in stagedOrPublished = true; throw AlignmentScientificActionError.contextUnavailable },
            bamStager: { _, _, _ in stagedOrPublished = true; throw AlignmentScientificActionError.contextUnavailable },
            publisher: { _ in stagedOrPublished = true; throw AlignmentScientificActionError.contextUnavailable }
        )
        let reporter = AlignmentScientificActionReporter.operationCenter(routeContext: routeContext, center: recorder)

        let regionTask = coordinator.launchRegion(
            context: try makeContext(), region: region, destination: .bundle(finalURL),
            outputBaseName: "selected-region", reporter: reporter
        )
        let readsTask = coordinator.launchSelectedReads(
            context: try makeContext(), records: [makeRead()], destination: .bundle(finalURL),
            outputBaseName: "evidence_selected_1reads", reporter: reporter
        )

        XCTAssertNil(regionTask, "a refused region extraction must return no task")
        XCTAssertNil(readsTask, "a refused selected-read extraction must return no task")
        XCTAssertFalse(stagedOrPublished)
        XCTAssertEqual(recorder.items.map(\.state), [.refused, .refused])
        XCTAssertTrue(recorder.items.allSatisfy { $0.logs.isEmpty && !$0.hasCancelCallback })
    }
}
