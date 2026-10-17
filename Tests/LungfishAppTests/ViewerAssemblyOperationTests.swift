// ViewerAssemblyOperationTests.swift - begin() site in ViewerViewController+Assembly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The assembly viewer registers one row, the BLAST verification of the
// selected contigs (R4). It locks no bundle. Since 2.11 A65 M2 the row
// records the `lungfish-cli blast submit` command its run executes, with the
// assembly folder and the contigs, and the test parses it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerAssemblyOperationTests: XCTestCase {
    func testContigBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST contig contig_7")
        XCTAssertEqual(item.initialDetail, "Preparing contig BLAST\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testContigBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "assembly-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let assembly = project.appendingPathComponent("Analyses/spades-2026-10-17", isDirectory: true)
        try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: true)
        let plan = try ViewerViewController.assemblyBlastSubmitPlan(
            sourceLabel: "contig contig_7", taxId: 11320,
            fastaRecords: [">contig_7 length=20\nACGTACGTAC\nGTACGTACGT", ">contig_9\nTTGGCCAATT"], resultURL: assembly
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7", cliCommand: plan.cliCommand, reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), plan.arguments)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let query = URL(fileURLWithPath: command.queryPath)
        XCTAssertEqual(query.lastPathComponent, "query.fasta")
        XCTAssertTrue(query.deletingLastPathComponent().lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(query.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".tmp")
        XCTAssertEqual(
            query.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Project.lungfish", "the query goes to the project's .tmp"
        )
        let output = URL(fileURLWithPath: command.outputPath)
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().path, assembly.path)
        XCTAssertEqual(command.sourceResult, assembly.path)
        XCTAssertEqual(command.contig, "contig_7,contig_9")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.label, "contig contig_7")
        XCTAssertNil(command.sample)
        XCTAssertNil(command.subsampleCount)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testContigBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
