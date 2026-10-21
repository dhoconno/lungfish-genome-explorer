// ViewerNvdOperationTests.swift - begin() site in ViewerViewController+Nvd
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The NVD viewer registers one row, the BLAST verification of a contig (R4).
// It locks no bundle. Since Phase 2.12 (lane 12.08) the row records the
// `lungfish-cli blast submit` command its search runs, and a test parses it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishNvdUI
import LungfishTestSupport

@MainActor
final class ViewerNvdOperationTests: XCTestCase {
    private let contigName = "NODE_12 (1,205 bp)"
    private let classificationName = "Severe acute respiratory syndrome coronavirus 2"
    /// What the row records in the tests that plan no search. The helper has no default since Phase 2.13.
    private let submitCommand = "lungfish-cli blast submit --label nvd-contig"

    func testContigBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            cliCommand: submitCommand,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(
            item.title,
            "BLAST NODE_12 (1,205 bp) \u{2014} Severe acute respiratory syndrome coronavirus 2"
        )
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testContigBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "nvd-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let source = project.appendingPathComponent("Analyses/nvd-run", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let hit = BlastSubmitParity.nvdHit(
            qseqid: "NODE_12", taxId: 2_697_049, name: "SARS-CoV-2", scientificName: classificationName
        )
        let plan = try ViewerViewController.nvdBlastSubmitPlan(
            hit: hit, sequence: " ACGTACGTAC\n", classificationName: classificationName, projectURL: project,
            sourceResultURL: source
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            cliCommand: plan.cliCommand,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.cliCommand, plan.cliCommand)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let stage = URL(fileURLWithPath: command.queryPath).deletingLastPathComponent()
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(stage.deletingLastPathComponent().lastPathComponent, ".tmp", "the query file sits in the project's .tmp")
        let output = URL(fileURLWithPath: command.outputPath).deletingLastPathComponent()
        XCTAssertEqual(output.lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().path, project.path, "the search sits under the project")
        XCTAssertEqual(command.label, classificationName)
        XCTAssertEqual(command.taxId, 2_697_049)
        XCTAssertEqual(command.contig, "NODE_12")
        XCTAssertEqual(command.sample, "S1")
        XCTAssertEqual(command.sourceResult, source.path)
        XCTAssertEqual(command.acceptedTaxIds, [2_697_049], "hits are judged against the adjusted tax ID")
        XCTAssertEqual(command.acceptedNames, ["SARS-CoV-2", classificationName])
        XCTAssertNil(command.subsampleCount, "one contig, no subsample")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(String(decoding: plan.queryData, as: UTF8.self), ">NODE_12\nACGTACGTAC\n", "the contig reaches BLAST as a file")
    }

    func testContigBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            cliCommand: submitCommand,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }

    /// Review 12.08 fix 1 (BIO 6). The site passes the folder of the NVD result its controller shows as the
    /// search's source result, so the record names the result the contig came from. The folder is the
    /// controller's `bundleURL`, which the controller now lets the viewer read. This has the depth of
    /// `NaoMgsBlastLineageTests`, the plan and not the closure that passes it.
    func testTheNvdPlanNamesTheResultFolderTheViewerHolds() throws {
        let scratch = try TestTempDirectory.make(prefix: "nvd-blast-lineage")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/nvd-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let controller = NvdResultViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configureWithCachedRows([], manifest: Self.manifest(), bundleURL: result)
        XCTAssertEqual(controller.bundleURL, result, "the controller holds the folder it was configured with")
        let hit = BlastSubmitParity.nvdHit(
            qseqid: "NODE_12", taxId: 2_697_049, name: "SARS-CoV-2", scientificName: classificationName
        )

        let plan = try ViewerViewController.nvdBlastSubmitPlan(
            hit: hit, sequence: "ACGTACGTAC", classificationName: classificationName, projectURL: project,
            sourceResultURL: controller.bundleURL
        )

        XCTAssertEqual(plan.request.sourceResultURL, result)
        let flag = try XCTUnwrap(plan.arguments.firstIndex(of: "--source-result"), "the leaf is told the result")
        XCTAssertEqual(plan.arguments[flag + 1], result.path)
    }

    /// A manifest of one sample, enough to configure the controller with no rows.
    private static func manifest() -> NvdManifest {
        NvdManifest(
            experiment: "exp-1", sampleCount: 1, contigCount: 1, hitCount: 1, blastDbVersion: nil,
            snakemakeRunId: nil, sourceDirectoryPath: "/tmp/nvd",
            samples: [
                NvdSampleSummary(
                    sampleId: "S1", contigCount: 1, hitCount: 1, totalReads: 100,
                    bamRelativePath: "S1.sorted.bam", fastaRelativePath: "S1.fasta"
                )
            ],
            cachedTopContigs: nil
        )
    }
}
