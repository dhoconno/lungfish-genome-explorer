// ViewerBundleDisplayOperationTests.swift - begin() site in ViewerViewController+BundleDisplay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extracting the navigator's selected chromosomes into a new bundle registers
// its row through a static begin helper (R4). The row locks no bundle, so a
// reporter that refuses every begin proves the launch closure sits behind the
// `.started` case. The recorded command is the exact argv the run executes
// through LungfishCLIRunner, an `extract contigs --bundle` command, and it
// must parse with the values the run uses.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ViewerBundleDisplayOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish", isDirectory: true)
    private let genomeURL = URL(
        fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Reference Sequences/Genome.lungfishref/genome/sequence.fa.gz"
    )

    /// The argv the call site builds for two selected chromosomes. The call
    /// site ends it with `--quiet`.
    private func makeArguments() -> [String] {
        FASTASelectionReferenceBundleCLI.arguments(
            sourceURL: genomeURL,
            sequenceIDs: ["chr1", "chr2"],
            projectURL: projectURL,
            bundleName: "chr1 and chr2"
        ) + ["--quiet"]
    }

    func testSelectedChromosomeExtractionRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        var launchedID: UUID?

        ViewerViewController.beginSelectedChromosomeExtractionOperation(
            cliArguments: makeArguments(),
            selectedCount: 2,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extract Sequences")
        XCTAssertEqual(item.initialDetail, "Extracting 2 selected sequence(s) into a new bundle...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractContigsSubcommand.self)
        XCTAssertEqual(command.contigsPath, genomeURL.standardizedFileURL.path)
        XCTAssertEqual(command.contigs, ["chr1", "chr2"])
        XCTAssertTrue(command.bundle)
        XCTAssertEqual(command.projectRoot, projectURL.standardizedFileURL.path)
        XCTAssertEqual(command.bundleName, "chr1 and chr2")
        XCTAssertTrue(command.globalOptions.quiet)
    }

    func testSelectedChromosomeExtractionRecordsTheArgvTheRunExecutesByteForByte() throws {
        let reporter = RecordingOperationReporter()
        let arguments = makeArguments()

        ViewerViewController.beginSelectedChromosomeExtractionOperation(
            cliArguments: arguments,
            selectedCount: 2,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        // The run executes `arguments` through LungfishCLIRunner, and the row
        // recorded this string before the migration, so it must not drift.
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.cliCommand, "lungfish-cli " + arguments.map(shellEscape).joined(separator: " "))
    }

    func testSelectedChromosomeExtractionLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginSelectedChromosomeExtractionOperation(
            cliArguments: makeArguments(),
            selectedCount: 2,
            routeContext: nil,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
