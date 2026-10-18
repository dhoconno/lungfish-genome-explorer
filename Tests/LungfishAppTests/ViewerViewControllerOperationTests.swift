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
// parse with the values the run uses. Since 2.11 A65 M2 the FASTA collection
// BLAST records the `lungfish-cli blast submit` command its run executes.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerViewControllerOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish", isDirectory: true)
    private let durableSourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Imports/savont clusters.fasta")
    private let stagedFASTAURL = URL(fileURLWithPath: "/tmp/lane 1a2/Staging/selection.fasta")

    private func makeRouteContext() -> OperationRouteContext {
        OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
    }

    // MARK: - FASTA collection BLAST on blast submit, the gap closed by 2.11 A65 M2

    func testFASTASelectionBlastRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "fasta-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("Imports/savont clusters.fasta")
        let plan = try ViewerViewController.fastaSelectionBlastSubmitPlan(
            sourceLabel: "3 FASTA sequences",
            sequences: [(id: "cluster-1", sequence: "ACGTACGTAC"), (id: "cluster-2", sequence: "GGCCTTAAGG")],
            sourceURL: source, projectURL: project
        )
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginGenericBlastVerificationOperation(
            sourceLabel: "3 FASTA sequences", cliCommand: plan.cliCommand, reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST 3 FASTA sequences")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), plan.arguments)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let query = URL(fileURLWithPath: command.queryPath)
        XCTAssertEqual(query.lastPathComponent, "query.fasta")
        XCTAssertTrue(query.deletingLastPathComponent().lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(query.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".tmp")
        // The result goes under the project, never into the file's folder or a bundle.
        let output = URL(fileURLWithPath: command.outputPath)
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().path, project.path)
        XCTAssertTrue(output.lastPathComponent.hasPrefix("3-FASTA-sequences-"), command.outputPath)
        XCTAssertEqual(command.sourceResult, source.path)
        XCTAssertEqual(command.label, "3 FASTA sequences")
        XCTAssertNil(command.taxId)
        XCTAssertNil(command.contig)
        XCTAssertNil(command.sample)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
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

    // MARK: - Annotated reference import, the gap closed by 2.11 A48 M3

    func testAnnotatedReferenceImportRecordsItsRowAndTheCommandItRuns() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        var launchedID: UUID?
        let staging = stagedFASTAURL.deletingLastPathComponent()
        let alignment = URL(fileURLWithPath: "/tmp/lane 1a2/Aligned.lungfishmsa", isDirectory: true)
        let arguments = AppDelegate.referenceImportArguments(
            sourceURL: stagedFASTAURL,
            projectURL: projectURL,
            preferredBundleName: "Reviewed clusters",
            provenanceInputFiles: [alignment],
            annotationsURL: staging.appendingPathComponent("selected-annotations.bed"),
            annotationSelectionURL: staging.appendingPathComponent("selected-annotations.json"),
            sourceAlignmentBundleURL: alignment
        )

        ViewerViewController.beginAnnotatedReferenceImportOperation(
            arguments: arguments,
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
        // The run is `import fasta` with the annotations, the selection and the
        // durable sources, which attaches the track and writes the extraction
        // record itself, so the row records the argv the runner gets.
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), arguments)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, stagedFASTAURL.path)
        XCTAssertEqual(command.outputDir, projectURL.path)
        XCTAssertEqual(command.annotationSelection, staging.appendingPathComponent("selected-annotations.json").path)
        XCTAssertEqual(command.sourceAlignmentBundle, alignment.path)
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
            arguments: AppDelegate.referenceImportArguments(
                sourceURL: stagedFASTAURL, projectURL: projectURL, preferredBundleName: "Reviewed clusters"
            ),
            bundleStem: "Reviewed-clusters", routeContext: nil, reporter: reporter
        ) { _ in launched.append("annotated reference import") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 3)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
