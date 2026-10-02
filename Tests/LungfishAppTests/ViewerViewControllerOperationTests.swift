// ViewerViewControllerOperationTests.swift - begin() sites in ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Three launches in ViewerViewController.swift register their rows through
// static begin helpers (R4). None of them locks a bundle, so a reporter that
// refuses every begin proves each launch closure sits behind the `.started`
// case. The reference bundle created straight from a FASTA selection records
// the exact lungfish-cli argv it runs, and the annotated reference import
// records the `import fasta` command that covers its first step. Both must
// parse with the values the run uses. The FASTA collection BLAST records a
// command no lungfish-cli command reproduces, and its test pins that, so a
// command added later fails here and prompts a deliberate test change.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ViewerViewControllerOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish", isDirectory: true)
    private let durableSourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Imports/savont clusters.fasta")
    private let stagedFASTAURL = URL(fileURLWithPath: "/tmp/lane 1a2/Staging/selection.fasta")

    private func makeRouteContext() -> OperationRouteContext {
        OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
    }

    // MARK: - FASTA collection BLAST, a CLI parity gap

    func testGenericBlastVerificationRecordsTodaysCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginGenericBlastVerificationOperation(
            sourceLabel: "3 FASTA sequences",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST 3 FASTA sequences")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        // CLI parity gap. `lungfish-cli blast verify` verifies one Kraken2
        // taxon and needs the Kraken2 report, the per-read output, the source
        // FASTQ and a taxon ID, so no command submits selected FASTA sequences
        // to BLAST. The closest is `blast verify`. When a command that takes
        // FASTA sequences exists, record it and replace this pin with a parse
        // test.
        XCTAssertEqual(item.cliCommand, "lungfish-cli blast verify")
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    // MARK: - Reference bundle created straight from selected FASTA sequences

    private func durableFASTAArguments() -> [String] {
        FASTASelectionReferenceBundleCLI.arguments(
            sourceURL: durableSourceURL,
            sequenceIDs: ["cluster-1", "cluster-2"],
            projectURL: projectURL,
            bundleName: "Reviewed clusters"
        ) + ["--quiet"]
    }

    func testDurableFASTAReferenceBundleRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        var launchedID: UUID?

        ViewerViewController.beginDurableFASTAReferenceBundleOperation(
            cliArguments: durableFASTAArguments(),
            selectedCount: 2,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Create Reference Bundle")
        XCTAssertEqual(item.initialDetail, "Creating a reference bundle from 2 selected FASTA sequence(s)...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractContigsSubcommand.self)
        XCTAssertEqual(command.contigsPath, durableSourceURL.standardizedFileURL.path)
        XCTAssertEqual(command.contigs, ["cluster-1", "cluster-2"])
        XCTAssertTrue(command.bundle)
        XCTAssertEqual(command.projectRoot, projectURL.standardizedFileURL.path)
        XCTAssertEqual(command.bundleName, "Reviewed clusters")
        XCTAssertTrue(command.globalOptions.quiet)
    }

    func testDurableFASTAReferenceBundleRecordsTheArgvTheRunExecutesByteForByte() throws {
        let reporter = RecordingOperationReporter()
        let arguments = durableFASTAArguments()

        ViewerViewController.beginDurableFASTAReferenceBundleOperation(
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

    // MARK: - Annotated reference import, a partial CLI parity gap

    func testAnnotatedReferenceImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        var launchedID: UUID?

        ViewerViewController.beginAnnotatedReferenceImportOperation(
            sourceURL: stagedFASTAURL,
            projectURL: projectURL,
            preferredBundleName: "Reviewed clusters",
            bundleStem: "Reviewed-clusters",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Annotated Reference Import")
        XCTAssertEqual(item.initialDetail, "Creating Reviewed-clusters.lungfishref...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // The command writes under the project it names, because `import fasta`
        // adds the Reference Sequences folder itself, where the run writes.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, stagedFASTAURL.path)
        XCTAssertEqual(command.outputDir, projectURL.path)
        XCTAssertEqual(command.name, "Reviewed clusters")
        // Partial CLI parity gap. After the import the run attaches the
        // selected annotations to the new bundle as a BED track and writes the
        // extraction provenance. No command covers either step, so this
        // command rebuilds the bundle without its annotations. When commands
        // for them exist, record the full sequence and replace this pin.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli import fasta '/tmp/lane 1a2/Staging/selection.fasta'"
                + " --output-dir '/tmp/lane 1a2/Project.lungfish' --name 'Reviewed clusters'"
        )
    }

    func testAnnotatedReferenceImportRecordsNoNameWhenTheRunHasNone() throws {
        for preferredBundleName in ["", "  \n "] {
            let reporter = RecordingOperationReporter()

            ViewerViewController.beginAnnotatedReferenceImportOperation(
                sourceURL: stagedFASTAURL,
                projectURL: projectURL,
                preferredBundleName: preferredBundleName,
                bundleStem: "selected-sequences",
                routeContext: nil,
                reporter: reporter
            ) { _ in }

            let item = try XCTUnwrap(reporter.items.first)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
            XCTAssertNil(command.name, "a run without a preferred name records no --name (\(preferredBundleName.debugDescription))")
            XCTAssertFalse(try XCTUnwrap(item.cliCommand).contains("--name"))
        }
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() throws {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        check("FASTA collection BLAST", ViewerViewController.beginGenericBlastVerificationOperation(
            sourceLabel: "seq1", reporter: reporter
        ) { _ in launched.append("FASTA collection BLAST") })
        check("reference bundle from a FASTA selection", ViewerViewController.beginDurableFASTAReferenceBundleOperation(
            cliArguments: durableFASTAArguments(), selectedCount: 2, routeContext: nil, reporter: reporter
        ) { _ in launched.append("reference bundle from a FASTA selection") })
        check("annotated reference import", ViewerViewController.beginAnnotatedReferenceImportOperation(
            sourceURL: stagedFASTAURL, projectURL: projectURL, preferredBundleName: "Reviewed clusters",
            bundleStem: "Reviewed-clusters", routeContext: nil, reporter: reporter
        ) { _ in launched.append("annotated reference import") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 3)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
