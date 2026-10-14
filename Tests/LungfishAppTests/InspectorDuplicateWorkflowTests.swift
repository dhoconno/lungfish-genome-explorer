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

    private func recordedCommand(of kind: InspectorViewController.DuplicateWorkflowKind, bundle: URL) throws -> String {
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

    func testMarkDuplicatesRowRecordsACommandTheCLIParses() throws {
        let command = try recordedCommand(of: .markDuplicates, bundle: spacedBundleURL)
        XCTAssertEqual(command, "lungfish-cli bundle mark-duplicates '/tmp/duplicate lane/Sample.lungfishref'")

        let parsed = try RecordedCLICommand.parse(command, as: BundleMarkDuplicatesSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, spacedBundleURL.path)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .text)
        // The same string, parsed as a script, is the one command the row ran.
        XCTAssertEqual(try RecordedCLICommand.parseScript(command).count, 1)
    }

    func testCreateDeduplicatedBundleRowRecordsACommandTheCLIParses() throws {
        let command = try recordedCommand(of: .createDeduplicatedBundle, bundle: spacedBundleURL)
        XCTAssertEqual(command, "lungfish-cli bundle deduplicate-alignments '/tmp/duplicate lane/Sample.lungfishref'")

        let parsed = try RecordedCLICommand.parse(command, as: BundleDeduplicateAlignmentsSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, spacedBundleURL.path)
        XCTAssertNil(parsed.output, "the run names no output, so the command makes the sibling bundle the run makes")
        XCTAssertEqual(parsed.globalOptions.outputFormat, .text)
    }

    func testEachDuplicateKindRecordsADifferentLeaf() throws {
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: recordedCommand(of: .markDuplicates, bundle: bundleURL)),
            ["bundle", "mark-duplicates", bundleURL.path]
        )
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: recordedCommand(of: .createDeduplicatedBundle, bundle: bundleURL)),
            ["bundle", "deduplicate-alignments", bundleURL.path]
        )
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
