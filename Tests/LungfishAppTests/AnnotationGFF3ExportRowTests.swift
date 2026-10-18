// AnnotationGFF3ExportRowTests.swift - The Operations row of the GFF3 annotation export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling 1.5 rule 3 and the ARCH ruling on 12.39 R2. `AppDelegate.beginAnnotationGFF3ExportOperation`
// begins an export row with no lock and a cancel callback, records the `bundle export-gff3` command the runner runs,
// and launches nothing when the row is refused. An open document's annotations reach the leaf in a selection file
// written before the row begins.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishWorkflow

@MainActor
private final class GFF3FailureCalls {
    var messages: [String] = []
}

@MainActor
final class AnnotationGFF3ExportRowTests: XCTestCase {
    private let bundleInvocation = AnnotationGFF3Export.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.39/Reference, one.lungfishref", isDirectory: true),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/annotations, all.gff3"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Annotations as GFF3")
        XCTAssertEqual(item.initialDetail, "Writing annotations, all.gff3 from Reference, one")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: BundleExportGFF3Subcommand.self)
        XCTAssertEqual(command.invocation(), bundleInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.39/Reference, one.lungfishref")
        XCTAssertNil(command.selectionPath)
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// ARCH ruling 1.3. An open document's annotations, frozen at the click, go to a selection file in a new inputs
    /// folder beside the output before `begin`, and the invocation names that file and no bundle.
    func testAnOpenDocumentWritesItsSelectionBeforeTheRow() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationGFF3ExportRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let annotations = [SequenceAnnotation(type: .gene, name: "unsaved", chromosome: "chr1", start: 1, end: 9)]
        let invocation = try AppDelegate.annotationGFF3ExportInvocation(
            annotations: annotations,
            source: .init(kind: .openDocument, urls: [folder.appendingPathComponent("doc.gb")], name: "Doc"),
            outputURL: folder.appendingPathComponent("doc.gff3")
        )
        XCTAssertNil(invocation.bundle)
        let selection = try ViewerExportSelection.read(from: URL(fileURLWithPath: try XCTUnwrap(invocation.selection)))
        XCTAssertEqual(selection.documentAnnotations?.sourceName, "Doc")
        XCTAssertEqual(selection.documentAnnotations?.annotations.map(\.name), ["unsaved"])
        XCTAssertEqual(selection.schemaVersion, 2)
        XCTAssertTrue(invocation.selection?.contains("/.lungfish-export-inputs/") == true)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: BundleExportGFF3Subcommand.self)
        XCTAssertEqual(command.invocation(), bundleInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once, which the app shows under the base's
    /// "Annotation export failed" (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = GFF3FailureCalls()
        let begun = try XCTUnwrap(AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }
}
