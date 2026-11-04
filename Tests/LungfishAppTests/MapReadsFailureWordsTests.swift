// MapReadsFailureWordsTests.swift - A failed Map Reads run shows words where a person looks (MAP-FAILURE-NO-ALERT, Phase 3.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// The words of a failed Map Reads run sat on its row of the Operations window, which this route never opens. Each
/// failed sample now adds to the batch's tally and the batch shows one alert when its loop ends. The stand-in
/// `lungfish-cli` fails the real route, and the tally and its report are checked by meaning, with no alert opened.
@MainActor
final class MapReadsFailureWordsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "map-failure-words")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
    }

    private final class RowIDBox {
        var id: UUID?
    }

    private func standInCLI(_ body: String) throws -> URL {
        let script = root.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func makeRequest(sample: String) throws -> MappingRunRequest {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let folder = try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: project)
        let reference = root.appendingPathComponent("genome.fasta")
        try ">chr1\nACGTACGTAC\n".write(to: reference, atomically: true, encoding: .utf8)
        return MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [root.appendingPathComponent("\(sample).fastq")],
            referenceFASTAURL: reference,
            projectURL: project,
            outputDirectory: folder,
            sampleName: sample,
            threads: 1
        )
    }

    /// Runs the real route on the stand-in and returns what it returned and the state its row ended in.
    private func runRoute(
        _ request: MappingRunRequest,
        cli: URL
    ) async -> (outcome: ManagedMappingOutcome, state: OperationCenter.Item.State?) {
        let row = RowIDBox()
        let outcome = await AppDelegate().runSingleManagedMappingThroughCLI(
            request: request,
            warning: nil,
            routeContext: nil,
            preassignedAnalysisDirectory: request.outputDirectory,
            runner: CLIReadsRunner(cliURLOverride: cli),
            cancelBatch: {},
            registerCancel: { row.id = $0 }
        )
        let state = row.id.flatMap { id in OperationCenter.shared.items.first { $0.id == id }?.state }
        if let id = row.id { OperationCenter.shared.clearItem(id: id) }
        return (outcome, state)
    }

    func testFailedMapRunReportsItsSampleAndWordsOnce() async throws {
        let cli = try standInCLI(#"echo '{"event":"failed","error":"The reference has no sequences","schemaVersion":2}'; exit 1"#)

        let ran = await runRoute(try makeRequest(sample: "sampleA"), cli: cli)

        XCTAssertEqual(ran.state, .failed, "the row is Failed")
        XCTAssertEqual(ran.outcome, .failed("The reference has no sequences"), "the route returns the failed line's words")
        var failures = MappingBatchFailures()
        failures.record(ran.outcome, sample: "sampleA")
        let report = try XCTUnwrap(failures.report(totalSamples: 1), "a failed run shows an alert")
        XCTAssertEqual(report.title, "Could not run Map Reads for sampleA")
        XCTAssertTrue(report.whatHappened.contains("The reference has no sequences"), "the alert holds the failed line's words: \(report.whatHappened)")
        XCTAssertTrue(report.nextStep.contains("Check the reads and the reference"), report.nextStep)
        XCTAssertTrue(report.nextStep.contains("Operations panel"), "the alert says where the log is: \(report.nextStep)")
    }

    func testResultThatCannotBeReadReportsItsWords() async throws {
        let cli = try standInCLI(#"echo '{"event":"complete","outputs":[],"progress":1,"schemaVersion":2}'; exit 0"#)

        let ran = await runRoute(try makeRequest(sample: "sampleB"), cli: cli)

        XCTAssertEqual(ran.state, .failed, "a result that cannot be read fails the row")
        guard case .failed(let words) = ran.outcome else {
            return XCTFail("an unreadable result is a failure, not \(ran.outcome)")
        }
        XCTAssertFalse(words.isEmpty, "the failure carries words")
        var failures = MappingBatchFailures()
        failures.record(ran.outcome, sample: "sampleB")
        let report = try XCTUnwrap(failures.report(totalSamples: 1), "an unreadable result shows an alert")
        XCTAssertTrue(report.title.contains("sampleB"), report.title)
        XCTAssertTrue(report.whatHappened.contains(words), "the alert holds the row's words: \(report.whatHappened)")
    }

    func testCancelledMapRunReportsNothing() {
        var failures = MappingBatchFailures()
        failures.record(.stopped, sample: "sampleA")
        failures.record(.succeeded, sample: "sampleB")
        XCTAssertTrue(failures.entries.isEmpty, "a cancel and a success are not failures")
        XCTAssertNil(failures.report(totalSamples: 2), "a cancelled run shows no alert")
    }

    func testBatchWithTwoFailuresShowsOneAlertNamingBoth() throws {
        var failures = MappingBatchFailures()
        failures.record(.failed("The reads are empty."), sample: "S1")
        failures.record(.succeeded, sample: "S2")
        failures.record(.failed("The reference could not be indexed"), sample: "S3")
        failures.record(.stopped, sample: "S4")

        let report = try XCTUnwrap(failures.report(totalSamples: 4), "two failures show an alert")

        XCTAssertEqual(report.title, "Could not run Map Reads for 2 of 4 samples")
        XCTAssertTrue(report.whatHappened.contains("S1") && report.whatHappened.contains("S3"), report.whatHappened)
        XCTAssertFalse(report.whatHappened.contains("S2"), "a sample that finished is not named: \(report.whatHappened)")
        XCTAssertTrue(report.nextStep.contains("Operations panel"), "each sample's reason and log are in the panel: \(report.nextStep)")
        let details = try XCTUnwrap(report.details, "each sample's reason is behind Show Details")
        XCTAssertTrue(details.contains("S1") && details.contains("The reads are empty."), details)
        XCTAssertTrue(details.contains("S3") && details.contains("The reference could not be indexed"), details)
        XCTAssertFalse(details.contains("S2"), "a sample that finished is not listed: \(details)")
    }

    func testLongBatchNamesTheFirstFiveAndCountsTheRest() throws {
        var failures = MappingBatchFailures()
        for index in 1...8 { failures.record(.failed("It failed."), sample: "S\(index)") }

        let report = try XCTUnwrap(failures.report(totalSamples: 8))

        XCTAssertEqual(report.title, "Could not run Map Reads for 8 of 8 samples")
        XCTAssertTrue(report.whatHappened.contains("S5"), report.whatHappened)
        XCTAssertFalse(report.whatHappened.contains("S6"), "the list stays short: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains("and 3 more"), report.whatHappened)
    }
}
