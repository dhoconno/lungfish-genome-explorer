// ViewerEsVirituOperationTests.swift - begin() site in ViewerViewController+EsViritu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The EsViritu viewer registers one row, the BLAST verification of a
// detection (R4). It locks no bundle. Since Phase 2.12 (lane 12.08) the row
// records the `lungfish-cli blast submit` command its search runs, and a test
// parses it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerEsVirituOperationTests: XCTestCase {
    func testDetectionBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Hepatitis B virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testDetectionBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "esviritu-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/esviritu-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let detection = BlastSubmitParity.esVirituDetection(
            name: "Influenza A virus", species: "Alphainfluenzavirus influenzae", genus: "Alphainfluenzavirus"
        )
        // Six reads and a count of 4, so the subsample draws four.
        let reads = (1...6).map { (id: "read_\($0)", sequence: String(repeating: "ACGT", count: $0 + 2)) }
        let plan = try ViewerViewController.esVirituBlastSubmitPlan(
            detection: detection, reads: reads, readCount: 4, accessions: ["NC_026433.1"], projectURL: project,
            sourceResultURL: result
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: detection.name,
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
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertNil(command.taxId, "EsViritu names no tax ID")
        XCTAssertEqual(command.contig, "NC_026433.1", "the accession the reads came from")
        XCTAssertEqual(command.sample, "S1")
        XCTAssertEqual(command.sourceResult, result.path)
        XCTAssertEqual(command.subsampleCount, 4)
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertEqual(command.acceptedTaxIds, [])
        XCTAssertEqual(command.acceptedNames, ["Influenza A virus", "Alphainfluenzavirus influenzae"])
        XCTAssertEqual(command.relatedNames, ["Alphainfluenzavirus"], "the genus counts as a relative")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(String(decoding: plan.queryData, as: UTF8.self).components(separatedBy: ">").count - 1, 4)
    }

    func testDetectionBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
