// ReferenceBundleImportHelperLauncherOperationTests.swift - The sidebar reference import's Operations panel row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ReferenceImportOperationLifecycle.run` takes its reporter as a parameter
// (R4). The row locks no bundle, so a reporter that refuses every begin proves
// that a refused row runs no importer. The recorded command is
// `lungfish-cli import fasta`, which reproduces the run only when
// `--output-dir` names the project, because the command adds the Reference
// Sequences folder itself. The run is handed that folder, so the lifecycle
// derives the project from it, and these tests cover both shapes.

import XCTest
import LungfishIO
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ReferenceBundleImportHelperLauncherOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish", isDirectory: true)
    private let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/Mito Reference.fasta")

    private var referenceSequencesURL: URL {
        projectURL.appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
    }

    // MARK: - Recorded row

    func testRunRecordsABundleBuildRowAndACommandThatNamesTheProject() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        let bundleURL = referenceSequencesURL.appendingPathComponent("Mito Reference.lungfishref", isDirectory: true)
        var importedWith: UUID?

        let outcome = await ReferenceImportOperationLifecycle.run(
            center: reporter,
            sourceURL: sourceURL,
            outputDirectory: referenceSequencesURL,
            routeContext: routeContext
        ) { operationID in
            importedWith = operationID
            return bundleURL
        }

        XCTAssertEqual(try outcome.get(), bundleURL)
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(importedWith, item.id)
        XCTAssertEqual(item.title, "Reference Import")
        XCTAssertEqual(item.initialDetail, "Importing Mito Reference.fasta...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.bundleURLs, [bundleURL])
        // `import fasta` adds the Reference Sequences folder to `--output-dir`,
        // so the command names the project. The run has no preferred bundle
        // name, so it records no `--name`.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.outputDir, projectURL.path)
        XCTAssertNil(command.name)
    }

    func testAFolderThatIsNotReferenceSequencesIsRecordedAsGiven() async throws {
        let reporter = RecordingOperationReporter()
        let otherFolder = URL(fileURLWithPath: "/tmp/lane 1a2/Elsewhere", isDirectory: true)

        _ = await ReferenceImportOperationLifecycle.run(
            center: reporter,
            sourceURL: sourceURL,
            outputDirectory: otherFolder,
            routeContext: nil
        ) { _ in otherFolder.appendingPathComponent("Mito Reference.lungfishref", isDirectory: true) }

        let item = try XCTUnwrap(reporter.items.first)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.outputDir, otherFolder.path, "no project can be derived from another folder")
    }

    func testProjectURLIsTheParentOfTheReferenceSequencesFolderOnly() {
        // The shape the sidebar passes, from `ReferenceSequenceFolder.ensureFolder`.
        XCTAssertEqual(
            ReferenceImportOperationLifecycle.projectURL(forReferenceSequencesFolder: referenceSequencesURL).path,
            projectURL.path
        )
        XCTAssertEqual(
            ReferenceImportOperationLifecycle.projectURL(
                forReferenceSequencesFolder: URL(fileURLWithPath: referenceSequencesURL.path)
            ).path,
            projectURL.path,
            "a folder URL without a trailing slash names the same project"
        )
        let other = URL(fileURLWithPath: "/tmp/lane 1a2/Elsewhere/Reference Sequences Archive", isDirectory: true)
        XCTAssertEqual(
            ReferenceImportOperationLifecycle.projectURL(forReferenceSequencesFolder: other).path,
            other.path,
            "only the exact folder name marks a Reference Sequences folder"
        )
    }

    // MARK: - Refused row

    func testRefusedRowRunsNoImporterAndReturnsTheRefusal() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let outcome = await ReferenceImportOperationLifecycle.run(
            center: reporter,
            sourceURL: sourceURL,
            outputDirectory: referenceSequencesURL,
            routeContext: nil
        ) { _ in
            XCTFail("a refused row must not run the importer")
            return self.referenceSequencesURL
        }

        guard case .failure(let error) = outcome, let refused = error as? OperationRefusedError else {
            return XCTFail("a refused begin must return OperationRefusedError, got \(outcome)")
        }
        XCTAssertEqual(refused.refusal.blockingOperationTitle, "Importing BAM")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items[0].logs.isEmpty, "a refused import reports nothing further")
    }
}
