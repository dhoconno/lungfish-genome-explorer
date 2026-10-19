// TwelveSResultExportRowTests.swift - The Operations row of the 12S viewer's result export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B3, ARCH ruling 1.5 rule 3. `TwelveSAmpliconResultViewController.beginResultExportOperation`
// begins an export row with no lock and a cancel callback, records the `fastq 12s-export` command the runner runs,
// which the leaf records as its argv, and launches nothing when the row is refused. `runResultExport` passes
// `--force` only when the output exists (ARCH 1.2). TwelveSResultExportCLIGUIParityReplayTests runs the command.

import XCTest
@testable import LungfishCLI
@testable import LungfishTwelveSUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class TwelveSExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TwelveSResultExportRowTests: XCTestCase {
    static let bundleURL = URL(fileURLWithPath: "/tmp/lane 12.35/Project/hilo 12S.lungfish12s", isDirectory: true)
    static let outputURL = URL(fileURLWithPath: "/tmp/lane 12.35/hilo 12S, reviewed.csv")
    static let everyFilter = TwelveSResultDisplayState(
        minimumExactReads: 10,
        filterText: "homo",
        includedTaxonGroups: ["Mammal", "Bird"],
        excludedTaxonGroups: ["Fish"],
        excludeHuman: true,
        requireAlternateMatches: true,
        minimumUnresolvedReads: 5,
        chimeraFilter: .candidate
    )

    static func snapshot(_ filters: TwelveSResultDisplayState) -> TwelveSAmpliconResultExportSnapshot {
        TwelveSAmpliconResultExportSnapshot(
            bundleURL: bundleURL,
            analysisName: "hilo 12S",
            sampleNames: ["SampleA"],
            filters: filters,
            rows: [],
            unresolvedRows: []
        )
    }

    static func arguments(force: Bool) -> [String] {
        TwelveSAmpliconResultViewController.resultExportArguments(
            snapshot: snapshot(everyFilter), format: .csv, outputURL: outputURL, force: force
        )
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let arguments = Self.arguments(force: true)
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TwelveSAmpliconResultViewController.beginResultExportOperation(
            arguments: arguments,
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        let outcome = await begun.task.value
        guard case .completed(let written) = outcome else { return XCTFail("a .text leaf's row completes on exit 0") }
        XCTAssertEqual(written.path, Self.outputURL.path)

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export 12S Results")
        XCTAssertEqual(item.initialDetail, "Writing hilo 12S, reviewed.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqTwelveSExportSubcommand.self)
        let configuration = command.configurationForTesting()
        XCTAssertEqual(configuration.argv, [CLICommandIdentity.executableName] + arguments, "the leaf records the row's command")
        XCTAssertEqual(configuration.bundleURL.path, Self.bundleURL.path)
        XCTAssertEqual(configuration.outputURL.path, Self.outputURL.path)
        XCTAssertEqual(configuration.format, .csv)
        XCTAssertEqual(configuration.minimumExactReads, 10)
        XCTAssertEqual(configuration.filterText, "homo")
        XCTAssertEqual(configuration.taxonGroups, ["Bird", "Mammal"])
        XCTAssertEqual(configuration.excludedTaxonGroups, ["Fish"])
        XCTAssertTrue(configuration.excludeHuman)
        XCTAssertTrue(configuration.requireAlternateMatches)
        XCTAssertEqual(configuration.minimumUnresolvedReads, 5)
        XCTAssertEqual(configuration.chimeraFilter.rawValue, "candidate")
        XCTAssertTrue(configuration.forceOverwrite)
        XCTAssertFalse(arguments.contains("--format"), "a .text leaf runs without --format json")
    }

    func testARefusedRowLaunchesNothing() throws {
        let arguments = Self.arguments(force: false)
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = TwelveSAmpliconResultViewController.beginResultExportOperation(
            arguments: arguments,
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: FastqTwelveSExportSubcommand.self)
        XCTAssertEqual(command.configurationForTesting().argv, [CLICommandIdentity.executableName] + arguments)
    }

    /// The alert of `presentExport` shows what `onFailure` gets. A leaf that fails fails the run, and `onFailure`
    /// gets its message once (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = TwelveSExportFailureCalls()
        let begun = try XCTUnwrap(TwelveSAmpliconResultViewController.beginResultExportOperation(
            arguments: Self.arguments(force: false),
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// ARCH 1.2. `--force` is passed only when the file the save panel returned exists.
    func testForceIsPassedOnlyOnReplace() async throws {
        let root = try TestTempDirectory.make(prefix: "twelve-s-export-row")
        defer { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("hilo-12s.csv")

        let first = try await runAndParse(output: output)
        XCTAssertFalse(first.forceOverwrite, "a new file is not replaced")
        XCTAssertEqual(first.outputURL.path, output.standardizedFileURL.path)

        try Data("old\n".utf8).write(to: output)
        let second = try await runAndParse(output: output)
        XCTAssertTrue(second.forceOverwrite, "the save panel's Replace replaces the file")
    }

    private func runAndParse(output: URL) async throws -> TwelveSResultExportConfiguration {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TwelveSAmpliconResultViewController.runResultExport(
            snapshot: Self.snapshot(TwelveSResultDisplayState()),
            format: .csv,
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value
        return try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: FastqTwelveSExportSubcommand.self)
            .configurationForTesting()
    }
}
