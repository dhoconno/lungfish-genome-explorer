// AlignmentScientificActionCoordinatorOperationTests.swift - begin() site of the viewer's alignment read rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extracting the reads of a selected alignment region, or of selected reads,
// registers one Operations panel row through
// `ViewerViewController.beginAlignmentReadExtractionOperation` (R4), which the
// coordinator's reporter did before Phase 2.10 lane A51. A recording reporter
// shows the row and the `lungfish-cli extract reads` command it records, which
// the L3 runner runs, without touching `OperationCenter.shared`. The rows lock
// no bundle. A reporter that refuses every begin proves a row launches nothing
// behind a refused row.

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

    private func makeRead() -> AlignedRead {
        AlignedRead(
            name: "qname", flag: 0, chromosome: "chrSynthetic", position: 4, mapq: 60,
            cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30]
        )
    }

    private let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9)

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

    /// The rows the viewer begins before `extract reads` runs. A reporter that refuses every begin
    /// proves each row launches nothing and logs no evidence behind a refused row.
    func testARefusedReadExtractionRowLaunchesNothing() throws {
        let context = try makeContext()
        let invocations = [
            ViewerViewController.alignmentRegionExtractionInvocation(
                context: context, region: region, destination: .bundle(finalURL), outputBaseName: "selected-region"
            ),
            ViewerViewController.selectedReadsExtractionInvocation(
                context: context, records: [makeRead()], namesFile: URL(fileURLWithPath: "/out/final.read-names.txt"),
                destination: .bundle(finalURL), outputBaseName: "evidence_selected_1reads"
            ),
        ]
        let recorder = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        for invocation in invocations {
            let result = ViewerViewController.beginAlignmentReadExtractionOperation(
                title: "Extract", detail: "Preparing…", invocation: invocation, evidence: context.identity,
                routeContext: routeContext, reporter: recorder
            ) { _ in launched = true }
            guard case .refused = result else { return XCTFail("the row was not refused: \(result)") }
        }

        XCTAssertFalse(launched, "a refused row launches nothing")
        XCTAssertEqual(recorder.items.map(\.state), [.refused, .refused])
        XCTAssertTrue(recorder.items.allSatisfy { $0.logs.isEmpty && !$0.hasCancelCallback })
    }
}
