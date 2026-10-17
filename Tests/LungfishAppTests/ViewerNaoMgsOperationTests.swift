// ViewerNaoMgsOperationTests.swift - begin() site in ViewerViewController+NaoMgs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The NAO-MGS viewer registers one row, the BLAST verification of a taxon
// (R4). It locks no bundle. Since 2.11 A65 M2 the row records the
// `lungfish-cli blast submit` command its run executes, with the taxon, the
// subsample and the samples of the drawn reads, and the test parses it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerNaoMgsOperationTests: XCTestCase {
    func testTaxonBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus",
            taxId: 11320,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Influenza A virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testTaxonBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Three reads and a count of 4 draw every read, so the samples are fixed.
        let reads = [("read_1", "S2"), ("read_2", "S1"), ("read_3", "S1")].map { Self.hit(id: $0.0, sample: $0.1) }
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Influenza A virus", taxId: 11320, readCount: 4, reads: reads, projectURL: project
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus", taxId: 11320, cliCommand: plan.cliCommand, reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), plan.arguments)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let query = URL(fileURLWithPath: command.queryPath)
        XCTAssertEqual(query.lastPathComponent, "query.fasta")
        XCTAssertTrue(query.deletingLastPathComponent().lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(query.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".tmp")
        let output = URL(fileURLWithPath: command.outputPath)
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Project.lungfish")
        XCTAssertTrue(output.lastPathComponent.hasPrefix("Influenza-A-virus-"), command.outputPath)
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.sample, "S1,S2")
        XCTAssertEqual(command.subsampleCount, 3)
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertEqual(command.entrezQuery, "txid11320[Organism:exp]")
        XCTAssertNil(command.sourceResult, "the NAO-MGS result folder is private to its view")
        XCTAssertNil(command.contig)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    /// A NAO-MGS read of `id` from `sample`, 20 bases long.
    private static func hit(id: String, sample: String) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: id, taxId: 11320, bestAlignmentScore: 40,
            cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
            readSequence: "ACGTACGTACGTACGTACGT", readQuality: String(repeating: "I", count: 20),
            subjectSeqId: "NC_026438.1", subjectTitle: "Influenza A virus", bitScore: 40, eValue: 1e-5,
            percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
            pairStatus: "CP", queryLength: 20
        )
    }

    func testTaxonBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus",
            taxId: 11320,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
