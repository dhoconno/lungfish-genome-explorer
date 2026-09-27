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
        final class CancelFlag: @unchecked Sendable { var cancelled = false }
        let flag = CancelFlag()

        let start = InspectorViewController.startDuplicateWorkflowOperation(
            kind: .markDuplicates,
            bundleURL: bundleURL,
            routeContext: nil,
            center: center,
            onCancel: { flag.cancelled = true }
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
        XCTAssertTrue(flag.cancelled)
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
