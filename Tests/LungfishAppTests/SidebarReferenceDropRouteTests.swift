// SidebarReferenceDropRouteTests.swift - The sidebar drop of a standalone reference on lungfish-cli import fasta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `MainSplitViewController.importDroppedReference` takes its reporter and its runner as
// parameters (2.11 A48 M4). The row is the Import Center's Reference Import row, so it records
// `lungfish-cli import fasta <source> --output-dir <project>`, and the drop runs exactly the argv
// the row records. Each end maps to the drop's notice, a cancel to U62's `cancelled` key.

import XCTest
import LungfishIO
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishKit
import LungfishKitTestSupport

@MainActor
final class SidebarReferenceDropRouteTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane a48/Project.lungfish", isDirectory: true)
    private let sourceURL = URL(fileURLWithPath: "/tmp/lane a48/Incoming/Mito Reference.fasta")

    private var bundleURL: URL {
        projectURL.appendingPathComponent("\(ReferenceSequenceFolder.folderName)/Mito_Reference.lungfishref", isDirectory: true)
    }

    func testTheDropRunsTheCommandItsRowRecordsAndCompletesWithTheBundle() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        var ran: (arguments: [String], id: UUID)?

        let outcome = await MainSplitViewController.importDroppedReference(
            sourceURL: sourceURL, projectURL: projectURL, routeContext: routeContext, reporter: reporter
        ) { arguments, id in
            ran = (arguments, id)
            return CLISubprocessTransport.Result(outputs: [self.bundleURL.path], message: "Reference import complete", artifacts: [])
        }

        XCTAssertEqual(outcome, .imported(bundleURL))
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(ran?.id, item.id)
        XCTAssertEqual(item.title, "Reference Import")
        XCTAssertEqual(item.initialDetail, "Importing Mito Reference.fasta...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.bundleURLs, [bundleURL])
        let arguments = try XCTUnwrap(ran?.arguments)
        XCTAssertEqual(arguments.prefix(2), ["import", "fasta"])
        XCTAssertEqual(arguments.suffix(2), ["--format", "json"], "the runner reads the command's events")
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "import fasta", args: Array(arguments.dropFirst(2))),
            "the row records the argv the drop runs"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.outputDir, projectURL.path, "the command adds the Reference Sequences folder itself")
        XCTAssertNil(command.name)
        XCTAssertNil(command.bundleDir)
    }

    func testARefusedRowRunsNothingAndFailsTheDropWithTheRefusal() async {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let outcome = await MainSplitViewController.importDroppedReference(
            sourceURL: sourceURL, projectURL: projectURL, routeContext: nil, reporter: reporter
        ) { _, _ in
            XCTFail("a refused row must not run the command")
            throw CancellationError()
        }

        guard case .failed(let message) = outcome else { return XCTFail("a refused row fails the drop, got \(outcome)") }
        XCTAssertTrue(message.contains("Importing BAM"), message)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    func testACancelledRunEndsTheDropAsCancelled() async {
        let reporter = RecordingOperationReporter()

        let outcome = await MainSplitViewController.importDroppedReference(
            sourceURL: sourceURL, projectURL: projectURL, routeContext: nil, reporter: reporter
        ) { _, _ in throw CancellationError() }

        XCTAssertEqual(outcome, .cancelled, "the drop posts U62's cancelled key, not a failure")
    }

    func testAFailedRunFailsTheRowAndTheDropWithTheCommandsMessage() async {
        struct Failed: LocalizedError { var errorDescription: String? { "Unsupported reference format: .txt" } }
        let reporter = RecordingOperationReporter()

        let outcome = await MainSplitViewController.importDroppedReference(
            sourceURL: sourceURL, projectURL: projectURL, routeContext: nil, reporter: reporter
        ) { _, _ in throw Failed() }

        XCTAssertEqual(outcome, .failed("Unsupported reference format: .txt"))
        XCTAssertEqual(reporter.items.map(\.state), [.failed])
    }
}
