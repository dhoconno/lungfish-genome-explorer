// InspectorDuplicateWorkflowTests.swift - Mark Duplicates / Create Deduplicated Bundle via OperationCenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both duplicate workflows used to run as a bare Task with only the activity indicator:
// no Operations Panel row, no progress, no Cancel, and no check of the bundle lock the
// rest of the app respects, so they could run alongside another mutation of the same
// bundle. They now pass the same gate as the filtered-alignment workflow and register
// a lock-holding row through `OperationCenter.begin`.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

@MainActor
final class InspectorDuplicateWorkflowTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfishref", isDirectory: true)

    func testStartOutcomeIsBlockedWhileAnotherOperationHoldsTheBundle() {
        let blocked = InspectorViewController.makeDuplicateWorkflowStartOutcome(
            bundleURL: bundleURL,
            canStartBundleMutation: { _ in false },
            activeBundleMutationTitle: { _ in "Importing BAM" }
        )
        XCTAssertEqual(
            blocked,
            .blocked(InspectorWorkflowAlert(
                title: "Operation in Progress",
                message: "\"Importing BAM\" is currently running on this bundle. Please wait for it to finish."
            ))
        )

        let blockedWithoutTitle = InspectorViewController.makeDuplicateWorkflowStartOutcome(
            bundleURL: bundleURL,
            canStartBundleMutation: { _ in false },
            activeBundleMutationTitle: { _ in nil }
        )
        guard case .blocked(let alert) = blockedWithoutTitle else {
            return XCTFail("expected a blocked outcome")
        }
        XCTAssertEqual(alert.message, "Another operation is currently running on this bundle. Please wait for it to finish.")

        XCTAssertEqual(
            InspectorViewController.makeDuplicateWorkflowStartOutcome(
                bundleURL: bundleURL,
                canStartBundleMutation: { _ in true },
                activeBundleMutationTitle: { _ in nil }
            ),
            .launch
        )
    }

    func testStartRegistersALockHoldingRowWithProgressAndCancel() {
        let center = OperationCenter()
        // OperationCenter.cancel(id:) hands onCancel to a global queue, so the
        // worker is reached asynchronously; wait for it rather than asserting
        // a flag on the next line (a race the parallel gate loses under load).
        let cancelReachedWorker = expectation(description: "onCancel reaches the worker")

        let start = InspectorViewController.startDuplicateWorkflowOperation(
            kind: .markDuplicates,
            bundleURL: bundleURL,
            routeContext: nil,
            center: center,
            onCancel: { cancelReachedWorker.fulfill() }
        )
        guard case .started(let id) = start else {
            return XCTFail("expected the row to start")
        }
        let row = try? XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(row?.title, "Mark Duplicates in Bundle Tracks")
        XCTAssertEqual(row?.detail, "Marking duplicates...")
        XCTAssertEqual(row?.state, .running)
        XCTAssertEqual(row?.cliCommand?.contains("bundle mark-duplicates"), true)

        // The row holds the bundle's write lock, so a second mutation is refused.
        XCTAssertFalse(center.canStartOperation(on: bundleURL))
        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, id)
        let second = InspectorViewController.startDuplicateWorkflowOperation(
            kind: .createDeduplicatedBundle,
            bundleURL: bundleURL,
            routeContext: nil,
            center: center
        )
        guard case .refused(let refusal) = second else {
            return XCTFail("a second duplicate workflow on the same bundle must be refused")
        }
        XCTAssertEqual(refusal.blockingOperationTitle, "Mark Duplicates in Bundle Tracks")

        // Progress reaches the row, and Cancel reaches the worker.
        XCTAssertTrue(center.updateWithLog(id: id, progress: 0.4, detail: "Sample: Sorting..."))
        XCTAssertEqual(center.items.first { $0.id == id }?.detail, "Sample: Sorting...")
        center.cancel(id: id)
        wait(for: [cancelReachedWorker], timeout: 5)
        XCTAssertTrue(center.acknowledgeCancellation(id: id))
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertTrue(center.canStartOperation(on: bundleURL), "the lock is released once the run ends")
    }

    func testDeduplicatedBundleRowNamesTheCLICommand() {
        let center = OperationCenter()
        guard case .started(let id) = InspectorViewController.startDuplicateWorkflowOperation(
            kind: .createDeduplicatedBundle,
            bundleURL: bundleURL,
            routeContext: nil,
            center: center
        ) else {
            return XCTFail("expected the row to start")
        }
        let row = center.items.first { $0.id == id }
        XCTAssertEqual(row?.title, "Create Deduplicated Bundle")
        XCTAssertEqual(row?.cliCommand?.contains("bundle deduplicate-alignments"), true)
        XCTAssertTrue(center.complete(id: id, detail: "done", bundleURLs: [bundleURL]))
    }

    // MARK: - The recorded commands (Phase 2.10 lane A54, census row p38)
    //
    // `startDuplicateWorkflowOperation` is the begin site of both duplicate workflows. It records
    // `bundle mark-duplicates` or `bundle deduplicate-alignments` (decision C14, not `bam markdup`,
    // which takes BAM files and no bundle), so each recorded string is pinned here and read back
    // with the real CLI parser.

    private let spacedBundleURL = URL(fileURLWithPath: "/tmp/duplicate lane/Sample.lungfishref", isDirectory: true)

    private func recordedCommand(
        of kind: InspectorViewController.DuplicateWorkflowKind,
        bundle: URL
    ) throws -> String {
        let center = OperationCenter()
        guard case .started(let id) = InspectorViewController.startDuplicateWorkflowOperation(
            kind: kind,
            bundleURL: bundle,
            routeContext: nil,
            center: center
        ) else {
            throw XCTSkip("the row did not start")
        }
        let row = try XCTUnwrap(center.items.first { $0.id == id })
        return try XCTUnwrap(row.cliCommand)
    }

    // MARK: - The launch (Phase 2.10 lane A54 M3)

    /// The launch is the part of `launchDuplicateWorkflow` that decides. It counts the tracks before the row
    /// begins and begins the row, and the window code runs what `plan.launch` says. The CLI route is the only
    /// route since Phase 2.11 (K3), so each kind is tried through the same call the Inspector makes.
    func testTheLaunchCountsTheTracksAndBeginsTheCLIRowForEachKind() throws {
        let root = try TestTempDirectory.make(prefix: "duplicate-launch")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try DerivedAlignmentTrackFixture.make(in: root).bundleURL
        for kind in [InspectorViewController.DuplicateWorkflowKind.markDuplicates, .createDeduplicatedBundle] {
            let center = OperationCenter()
            guard case .started(let plan) = InspectorViewController.beginDuplicateWorkflow(
                kind: kind, bundleURL: bundle, routeContext: nil, center: center
            ) else {
                return XCTFail("the row did not start for \(kind)")
            }
            XCTAssertEqual(plan.trackCount, 2, "\(kind) reads the count before the row begins")
            let row = try XCTUnwrap(center.items.first { $0.id == plan.operationID })
            XCTAssertEqual(row.cliCommand, kind.cliCommand(bundleURL: bundle), "\(kind)")
            XCTAssertEqual(row.detail, kind.startingDetail, "\(kind)")
            XCTAssertEqual(plan.launch, .leaf(arguments: kind.cliArguments(bundleURL: bundle)), "\(kind) runs the leaf")
        }
    }

    /// A bundle another operation holds is refused at the launch.
    func testTheLaunchRefusesABundleAnotherOperationHolds() throws {
        let center = OperationCenter()
        guard case .started = center.begin(
            title: "Holder", detail: "Running", operationType: .bamImport, targetBundleURL: bundleURL, cliCommand: nil
        ) else {
            return XCTFail("the holder did not start")
        }
        let begun = InspectorViewController.beginDuplicateWorkflow(
            kind: .markDuplicates, bundleURL: bundleURL, routeContext: nil, center: center
        )
        guard case .refused = begun else { return XCTFail("a held bundle is refused, got \(begun)") }
    }

    func testTheCLIRouteRecordsTheArgvItRunsForEachKind() throws {
        let mark = try recordedCommand(of: .markDuplicates, bundle: spacedBundleURL)
        XCTAssertEqual(mark, "lungfish-cli bundle mark-duplicates '/tmp/duplicate lane/Sample.lungfishref' --format json")
        let parsedMark = try RecordedCLICommand.parse(mark, as: BundleMarkDuplicatesSubcommand.self)
        XCTAssertEqual(parsedMark.bundlePath, spacedBundleURL.path)
        // The same string, parsed as a script, is the one command the row ran.
        XCTAssertEqual(try RecordedCLICommand.parseScript(mark).count, 1)
        // The parsed options do not hold the format (the root command consumes `--format`, and the leaf reads
        // it from the process arguments), so the argv is what shows the leaf speaks events.
        XCTAssertEqual(Array(try RecordedCLICommand.arguments(of: mark).suffix(2)), ["--format", "json"])

        let dedupe = try recordedCommand(of: .createDeduplicatedBundle, bundle: spacedBundleURL)
        XCTAssertEqual(dedupe, "lungfish-cli bundle deduplicate-alignments '/tmp/duplicate lane/Sample.lungfishref' --format json")
        let parsedDedupe = try RecordedCLICommand.parse(dedupe, as: BundleDeduplicateAlignmentsSubcommand.self)
        XCTAssertEqual(parsedDedupe.bundlePath, spacedBundleURL.path)
        XCTAssertNil(parsedDedupe.output, "the run names no output, so the leaf makes the sibling bundle the service makes")
        XCTAssertEqual(Array(try RecordedCLICommand.arguments(of: dedupe).suffix(2)), ["--format", "json"])
    }

    /// Ruling on deviation 2 (condition 1). The app parses no number from `complete.message`, which is text.
    /// It reads the count from the bundle before the row begins, and the service processes every one of
    /// those tracks or throws, so the final detail is the words the in-process route gives. The stand-in
    /// CLI's `complete` holds no number.
    func testTheCLIRouteShowsTheTrackCountItReadBeforeBegin() async throws {
        let root = try TestTempDirectory.make(prefix: "duplicate-track-count")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try DerivedAlignmentTrackFixture.make(in: root).bundleURL
        let kind = InspectorViewController.DuplicateWorkflowKind.markDuplicates
        let trackCount = InspectorViewController.duplicateWorkflowTrackCount(kind: kind, bundleURL: bundle)
        XCTAssertEqual(trackCount, 2, "the bundle holds two alignment tracks, neither marked")
        let stand = try StandInAlignmentCLI.make(in: root, body: [
            StandInAlignmentCLI.line(#"{"event":"start","message":"Marking duplicates...","progress":0}"#),
            StandInAlignmentCLI.line(#"{"event":"progress","progress":0.5,"message":"Sample 1: marking duplicates..."}"#),
            StandInAlignmentCLI.line("{\"event\":\"complete\",\"output\":\"\(bundle.path)\",\"outputs\":[\"\(bundle.path)\"],\"message\":\"Marked duplicates.\"}"),
        ].joined(separator: "\n"))

        guard case .started(let id) = InspectorViewController.startDuplicateWorkflowOperation(
            kind: kind, bundleURL: bundle, routeContext: nil, center: .shared
        ) else {
            return XCTFail("the row did not start")
        }
        defer { OperationCenter.shared.clearItem(id: id) }
        guard case .leaf(let arguments) = InspectorViewController.duplicateWorkflowLaunch(kind: kind, bundleURL: bundle) else {
            return XCTFail("the CLI route runs a leaf")
        }

        let outcome = await withCheckedContinuation { continuation in
            InspectorViewController.runAlignmentLeafThroughCLI(
                arguments: arguments,
                operationID: id,
                runner: CLIAlignmentActionRunner(cliURLOverride: stand.cli),
                finish: { continuation.resume(returning: $0) }
            )
        }
        let completion = try outcome.get()
        XCTAssertEqual(completion.message, "Marked duplicates.", "the stand-in's complete holds no number")
        XCTAssertEqual(stand.arguments(), try RecordedCLICommand.arguments(of: OperationCenter.shared.items.first { $0.id == id }?.cliCommand))

        let result = try InspectorViewController.duplicateWorkflowResult(
            kind: kind, bundleURL: bundle, trackCount: trackCount, completion: completion
        )
        XCTAssertTrue(InspectorViewController.completeDuplicateWorkflowRow(kind: kind, operationID: id, result: result, center: .shared))
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(row.detail, "Marked duplicates in 2 alignment tracks.")
        XCTAssertEqual(row.state, .completed)
    }

    func testTheDeduplicatedBundleIsTheOneTheLeafNamedAndAMissingNameFailsTheRun() throws {
        let completion = CLIAlignmentActionRunner.Completion(outputs: ["/tmp/Sample-deduplicated.lungfishref"], message: nil)
        let result = try InspectorViewController.duplicateWorkflowResult(
            kind: .createDeduplicatedBundle, bundleURL: bundleURL, trackCount: 1, completion: completion
        )
        XCTAssertEqual(result.bundleURL.path, "/tmp/Sample-deduplicated.lungfishref")
        XCTAssertEqual(
            InspectorViewController.duplicateWorkflowCompletionDetail(kind: .createDeduplicatedBundle, result: result),
            "Created Sample-deduplicated.lungfishref from 1 alignment track."
        )

        let nothing = CLIAlignmentActionRunner.Completion(outputs: [], message: nil)
        XCTAssertThrowsError(try InspectorViewController.duplicateWorkflowResult(
            kind: .createDeduplicatedBundle, bundleURL: bundleURL, trackCount: 1, completion: nothing
        ), "opening the source in place of the new bundle would be a false result")
    }

    // The button reads "Mark Duplicates in Bundle Tracks"; the sheet it opens
    // used to be titled "Mark Duplicates in Alignment Tracks?".
    func testConfirmationSheetTitleMatchesTheButton() {
        let sheet = InspectorViewController.duplicateWorkflowConfirmation(for: .markDuplicates)
        XCTAssertEqual(sheet.title, "Mark Duplicates in Bundle Tracks?")
        XCTAssertEqual(InspectorViewController.DuplicateWorkflowKind.markDuplicates.operationTitle, "Mark Duplicates in Bundle Tracks")

        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(source?.contains("Button(\"Mark Duplicates in Bundle Tracks\")"), true)

        XCTAssertEqual(
            InspectorViewController.duplicateWorkflowConfirmation(for: .createDeduplicatedBundle).title,
            "Create Deduplicated Bundle?"
        )
    }
}
