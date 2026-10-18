// GenotypeManualDefinitionsExportRowTests.swift - The Operations row of the manual haplotype definitions export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 M2, ARCH ruling 1.5 rule 3. `GenotypeResultViewController.beginManualDefinitionsExportOperation`
// begins an export row with no lock and a cancel callback, records the `genotype export-manual-definitions` command
// the runner runs, and launches nothing when the row is refused. `runManualDefinitionsExport` writes the selection
// file beside the output before the row begins and passes `--force` only when the output exists (ARCH 1.2).
// GenotypeManualDefinitionsExportCLIGUIParityReplayTests runs the command.

import XCTest
@testable import LungfishCLI
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class ManualDefinitionsFailureCalls {
    var messages: [String] = []
}

@MainActor
final class GenotypeManualDefinitionsExportRowTests: XCTestCase {
    private let exportInvocation = GenotypeManualDefinitionsExport.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.35/Project/Analyses/run/manual.lungfishgenotype", isDirectory: true),
        selectionURL: URL(fileURLWithPath: "/tmp/lane 12.35/.lungfish-export-inputs/A/selection.json"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.35/manual definitions, all.json"),
        force: true
    )

    private static let assignments = [
        ManualHaplotypeAssignment(
            sample: "AnimalA", locus: "MHC-A", slot: .h1, label: "M1A", colorTokenIndex: 0,
            diagnosticAlleles: ["01_Mafa_A1_001_01"], notes: "Pedigree confirmed"
        ),
        ManualHaplotypeAssignment(
            sample: "AnimalB", locus: "MHC-A", slot: .h1, label: "M3A", colorTokenIndex: 3,
            diagnosticAlleles: [], notes: "Provisional"
        ),
    ]

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(GenotypeResultViewController.beginManualDefinitionsExportOperation(
            invocation: exportInvocation,
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
        XCTAssertEqual(item.title, "Export Manual Haplotype Definitions")
        XCTAssertEqual(item.initialDetail, "Writing manual definitions, all.json")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: GenotypeExportManualDefinitionsSubcommand.self)
        XCTAssertEqual(command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.35/Project/Analyses/run/manual.lungfishgenotype")
        XCTAssertEqual(command.selection.path, "/tmp/lane 12.35/.lungfish-export-inputs/A/selection.json")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.35/manual definitions, all.json")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = GenotypeResultViewController.beginManualDefinitionsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: GenotypeExportManualDefinitionsSubcommand.self
        )
        XCTAssertEqual(command.invocation(), exportInvocation)
    }

    /// The alert of `exportManualDefinitions` shows what `onFailure` gets. A leaf that fails fails the run, and
    /// `onFailure` gets its message once (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = ManualDefinitionsFailureCalls()
        let begun = try XCTUnwrap(GenotypeResultViewController.beginManualDefinitionsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// ARCH 1.2 and 1.3. The selection file holds the store's assignments in their order and sits in a new
    /// `.lungfish-export-inputs/<UUID>/` beside the output, and `--force` is passed only when the output exists.
    func testTheSelectionIsWrittenBesideTheOutputAndForceOnlyOnReplace() async throws {
        let root = try TestTempDirectory.make(prefix: "manual-definitions-row")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("manual.lungfishgenotype", isDirectory: true)
        let output = root.appendingPathComponent("manual-haplotype-definitions.json")

        let first = try await runAndParse(bundle: bundle, output: output)
        XCTAssertFalse(first.output.force, "a new file is not replaced")
        let selectionURL = URL(fileURLWithPath: first.selection.path)
        XCTAssertEqual(selectionURL.lastPathComponent, "selection.json")
        XCTAssertEqual(
            selectionURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
            root.appendingPathComponent(ViewerExportSelection.inputsFolderName).standardizedFileURL.path
        )
        let selection = try ViewerExportSelection.read(from: selectionURL)
        XCTAssertEqual(selection.identities, ["1", "2"])
        XCTAssertEqual(try GenotypeManualDefinitionsExport.assignments(from: selection), Self.assignments)
        XCTAssertEqual(first.bundlePath, bundle.standardizedFileURL.path)

        try Data("[]".utf8).write(to: output)
        let second = try await runAndParse(bundle: bundle, output: output)
        XCTAssertTrue(second.output.force, "the save panel's Replace replaces the file")
        XCTAssertNotEqual(second.selection.path, first.selection.path, "each export writes its own selection folder")
    }

    private func runAndParse(bundle: URL, output: URL) async throws -> GenotypeExportManualDefinitionsSubcommand {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(try GenotypeResultViewController.runManualDefinitionsExport(
            assignments: Self.assignments,
            bundleURL: bundle,
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value
        return try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: GenotypeExportManualDefinitionsSubcommand.self
        )
    }
}
