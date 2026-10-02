// ViewerAnnotationDrawerOperationTests.swift - begin() sites in ViewerViewController+AnnotationDrawer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Deleting annotation rows and deleting an annotation track each register
// their row through a static begin helper (R4). Both lock the bundle and run
// a `lungfish-cli sequence` command. For each site a held bundle lock must
// refuse the row and launch nothing, and the recorded row must carry its type,
// its lock and a command the real CLI parser accepts with the run's values.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerAnnotationDrawerOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Find ORFs",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli sequence annotate-orfs"
        ).startedID)
        return center
    }

    // MARK: - Delete annotation rows

    func testAnnotationRowDeletionArgumentsAreTheArgvTheRunExecutes() {
        XCTAssertEqual(
            ViewerViewController.annotationRowDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowIDs: [3, 17]
            ),
            [
                "sequence", "delete-annotations", "/tmp/lane 1a2/Sample.lungfishref",
                "--track-id", "orfs_chr1", "--row-id", "3", "--row-id", "17", "--quiet",
            ]
        )
    }

    func testAnnotationRowDeletionRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = ViewerViewController.beginAnnotationRowDeletionOperation(
            bundleURL: bundleURL,
            cliArguments: ViewerViewController.annotationRowDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowIDs: [3]
            ),
            deletedCount: 1,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the row deletion")
        }
        XCTAssertFalse(launched, "a refused row must start no CLI run")
        XCTAssertEqual(refusal.blockingOperationTitle, "Find ORFs")
    }

    func testAnnotationRowDeletionRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginAnnotationRowDeletionOperation(
            bundleURL: bundleURL,
            cliArguments: ViewerViewController.annotationRowDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowIDs: [3, 17, 42]
            ),
            deletedCount: 3,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Delete Annotations")
        XCTAssertEqual(item.initialDetail, "Deleting 3 annotations...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.DeleteAnnotations.self)
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.trackID, "orfs_chr1")
        XCTAssertEqual(command.rowIDs, [3, 17, 42])
        XCTAssertTrue(command.globalOptions.quiet)
    }

    func testSingleAnnotationRowDeletionUsesTheSingularTitleAndDetail() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginAnnotationRowDeletionOperation(
            bundleURL: bundleURL,
            cliArguments: ViewerViewController.annotationRowDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1",
                rowIDs: [9]
            ),
            deletedCount: 1,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Delete Annotation")
        XCTAssertEqual(item.initialDetail, "Deleting 1 annotation...")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.DeleteAnnotations.self)
        XCTAssertEqual(command.rowIDs, [9])
    }

    // MARK: - Delete an annotation track

    func testAnnotationTrackDeletionArgumentsAreTheArgvTheRunExecutes() {
        XCTAssertEqual(
            ViewerViewController.annotationTrackDeletionArguments(bundleURL: bundleURL, trackID: "orfs_chr1"),
            [
                "sequence", "delete-annotation-track", "/tmp/lane 1a2/Sample.lungfishref",
                "--track-id", "orfs_chr1", "--quiet",
            ]
        )
    }

    func testAnnotationTrackDeletionRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = ViewerViewController.beginAnnotationTrackDeletionOperation(
            bundleURL: bundleURL,
            cliArguments: ViewerViewController.annotationTrackDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1"
            ),
            trackName: "chr1 ORFs",
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the track deletion")
        }
        XCTAssertFalse(launched, "a refused row must start no CLI run")
        XCTAssertEqual(refusal.blockingOperationTitle, "Find ORFs")
    }

    func testAnnotationTrackDeletionRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginAnnotationTrackDeletionOperation(
            bundleURL: bundleURL,
            cliArguments: ViewerViewController.annotationTrackDeletionArguments(
                bundleURL: bundleURL,
                trackID: "orfs_chr1"
            ),
            trackName: "chr1 ORFs",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Delete Annotation Track")
        XCTAssertEqual(item.initialDetail, "Deleting chr1 ORFs...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.DeleteAnnotationTrack.self)
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.trackID, "orfs_chr1")
        XCTAssertTrue(command.globalOptions.quiet)
    }
}
