// ViewerTwelveSOperationTests.swift - begin() site in ViewerViewController+TwelveS
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The 12S unresolved-sequence BLAST registers its row through a static begin
// helper (R4). The row locks no bundle. The run executes
// `lungfish-cli fastq 12s-export-unresolved` first and then submits the
// exported sequences to NCBI BLAST, which no lungfish-cli command does. The
// row records no command (CLI parity gap blast-12s-unresolved) and logs the
// export command, which must parse with the values the run uses. A reporter
// that refuses every begin proves the launch closure sits behind the
// `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerTwelveSOperationTests: XCTestCase {
    private let bundleURL = URL(
        fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Analyses/12S Run/result.lungfish12s",
        isDirectory: true
    )
    private let exportURL = URL(
        fileURLWithPath: "/tmp/lane 1a2f/lungfish-12s-blast-ABC123/unresolved-min3.fasta"
    )

    /// The argv the call site builds, through the same builder.
    private func makeArguments(sequenceIDs: [String] = ["unresolved-1", "unresolved-2"]) -> [String] {
        ViewerViewController.twelveSUnresolvedExportArguments(
            bundleURL: bundleURL,
            minimumReads: 3,
            exportURL: exportURL,
            sequenceIDs: sequenceIDs
        )
    }

    /// The export command the row's log names.
    private func loggedExportCommand(_ item: RecordingOperationReporter.Item) throws -> String {
        let message = try XCTUnwrap(item.logs.first?.message)
        XCTAssertTrue(message.hasPrefix(ViewerViewController.twelveSExportLogPrefix), message)
        return String(message.dropFirst(ViewerViewController.twelveSExportLogPrefix.count))
    }

    func testTwelveSUnresolvedBlastRecordsItsRowAndLogsARunnableExportCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST 12S Unresolved")
        XCTAssertEqual(item.initialDetail, "Preparing unresolved sequence FASTA...")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        assertCLIParityGap(item.cliCommand, id: "blast-12s-unresolved")
        let command = try RecordedCLICommand.parse(
            try loggedExportCommand(item),
            as: FastqTwelveSExportUnresolvedSubcommand.self
        )
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.minimumReads, 3)
        XCTAssertEqual(command.output, exportURL.path)
        XCTAssertNil(command.metadataOutput)
        XCTAssertTrue(command.includeChimeraCandidates)
        XCTAssertEqual(command.sequenceIDs, ["unresolved-1", "unresolved-2"])
        XCTAssertTrue(command.force)
    }

    func testTwelveSUnresolvedBlastRecordsNoSequenceIDWhenNoneAreSelected() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(sequenceIDs: []),
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        let exportCommand = try loggedExportCommand(item)
        let command = try RecordedCLICommand.parse(exportCommand, as: FastqTwelveSExportUnresolvedSubcommand.self)
        XCTAssertEqual(command.sequenceIDs, [])
        XCTAssertFalse(exportCommand.contains("--sequence-id"))
    }

    func testTwelveSUnresolvedBlastRecordsNoCommandAndLogsTheExportStringByteForByte() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            reporter: reporter
        ) { _ in }

        // The export command stops at a FASTA file. The run then submits the
        // sequences to NCBI BLAST through BlastService, and no lungfish-cli
        // command does that, so the row records no command. The log keeps the
        // export string the row recorded before, byte for byte.
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "blast-12s-unresolved")
        XCTAssertEqual(
            try loggedExportCommand(item),
            "lungfish-cli fastq 12s-export-unresolved"
                + " --bundle '/tmp/lane 1a2f/Project.lungfish/Analyses/12S Run/result.lungfish12s'"
                + " --min-reads 3"
                + " --output '/tmp/lane 1a2f/lungfish-12s-blast-ABC123/unresolved-min3.fasta'"
                + " --include-chimera-candidates --force"
                + " --sequence-id unresolved-1 --sequence-id unresolved-2"
        )
    }

    func testTwelveSUnresolvedBlastLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
